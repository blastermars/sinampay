import Foundation

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Sinampay never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    private let onlyTaggedScreenshots: Bool
    /// In Sinampay's own inbox every file belongs on the line, including any
    /// that arrived while the app was not running. Elsewhere, only files
    /// created after launch are new.
    private let adoptExisting: Bool
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// The folder's identity when watching began. If the folder is deleted
    /// or replaced, the open descriptor goes stale and the watcher has to
    /// start over.
    private var identity: (NSObjectProtocol & NSCopying)?
    /// Called with each new image, and whether it just arrived (true) or was
    /// already there when watching began (false).
    private let onNew: (URL, Bool) -> Void
    private let onChange: () -> Void

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

    /// Watches the folder macOS saves screenshots to, or a given folder.
    init(folder: URL? = nil, adoptExisting: Bool = false,
         onNew: @escaping (URL, Bool) -> Void, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.adoptExisting = adoptExisting
        self.folder = folder ?? Self.screenshotFolder()
        onlyTaggedScreenshots = self.folder.standardizedFileURL.path == Self.desktop.standardizedFileURL.path
    }

    static func screenshotFolder() -> URL {
        let fm = FileManager.default
        // Read fresh through cfprefsd: inbox mode and Cmd+Shift+5 change this
        // value at runtime.
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        // macOS 27 keeps it in "location-screenshot"; earlier versions in "location".
        let raw = (CFPreferencesCopyAppValue("location-screenshot" as CFString, domain) as? String)
            ?? (CFPreferencesCopyAppValue("location" as CFString, domain) as? String)
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return desktop
    }

    /// Anything created after the watcher was made counts as new, even if it
    /// landed before watching began (macOS may be asking for Desktop access
    /// at that moment). A watcher restarted on another folder starts fresh.
    private let createdAt = Date()

    func start() {
        let files = listing()
        identity = Self.identity(of: folder)
        known = adoptExisting ? [] : Set(files.filter { creationDate($0) < createdAt }.map(\.path))
        for url in files where !known.contains(url.path) && isCandidate(url) {
            onNew(url, !adoptExisting && creationDate(url) >= createdAt)
        }
        known = Set(files.map(\.path))
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("Cannot watch \(self.folder.path, privacy: .public)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    /// False once the folder was deleted, renamed or replaced since watching
    /// began, or watching never started.
    var isHealthy: Bool {
        guard source != nil, let identity, let now = Self.identity(of: folder) else { return false }
        return identity.isEqual(now)
    }

    private static func identity(of folder: URL) -> (NSObjectProtocol & NSCopying)? {
        var url = folder
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        // macOS writes a hidden temp file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func scan() {
        let files = listing()
        for url in files where !known.contains(url.path) && isCandidate(url) {
            onNew(url, true)
        }
        known = Set(files.map(\.path))
        onChange()
    }

    private func listing() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func isCandidate(_ url: URL) -> Bool {
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return onlyTaggedScreenshots ? isScreenCapture(url) : true
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }
}
