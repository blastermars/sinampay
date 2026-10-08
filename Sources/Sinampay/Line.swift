import AppKit
import Combine
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sinampay", category: "line")

/// One screenshot or clip hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false

    /// Copied text, kept as a .txt file in the clipboard folder.
    var isText: Bool { ClipboardWatcher.isText(url) }
    var sipit: NSColor { Palette.sipit(for: id) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// Files elsewhere never move: the line is only a view onto them. Files in
/// Sinampay's own folders belong to the line, and leave with it.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8

    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    /// The fiesta bunting along the line.
    @Published var banderitasOn: Bool = !UserDefaults.standard.bool(forKey: "banderitasOff") {
        didSet { UserDefaults.standard.set(!banderitasOn, forKey: "banderitasOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    init() {
        scheduleGust()
    }

    // MARK: Hanging and dropping

    /// Makes the thumbnail away from the main thread, so a large image never
    /// stutters the line, then hangs it.
    func hangLater(_ url: URL, quietly: Bool = false, flying: Bool = false,
                   completion: @escaping (UUID?) -> Void = { _ in }) {
        if ClipboardWatcher.isText(url) {
            completion(hang(url, thumb: textThumbnail(url), quietly: quietly, flying: flying))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let thumb = makeThumbnail(url)
            DispatchQueue.main.async {
                completion(self.hang(url, thumb: thumb, quietly: quietly, flying: flying))
            }
        }
    }

    @discardableResult
    func hang(_ url: URL, thumb: NSImage? = nil, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = thumb ?? thumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        // A full line lets the oldest photo fall off the far end. If it is
        // one of ours, its file goes with it, or the folder would fill up
        // with screenshots and clips nobody can see.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            discard(oldest.id, quietly: true)
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    /// Takes the photo off the line. The file is left alone.
    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// "Take everything down": the same as the cross on every photo.
    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.isText, let text = ClipboardWatcher.text(of: item.url) {
            pb.setString(text, forType: .string)
        } else {
            let entry = NSPasteboardItem()
            if let png = pngData(item.url) { entry.setData(png, forType: .png) }
            entry.setString(item.url.absoluteString, forType: .fileURL)
            pb.writeObjects([entry])
        }
        ClipboardWatcher.ownChangeCount = pb.changeCount

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID, quietly: Bool = false) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            drop(id, quietly: true)
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in the screenshot inbox. Those are discarded to
    /// the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return AppFolders.contains(item.url, in: Inbox.folder)
    }

    func isClip(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return ClipboardWatcher.isClip(item.url)
    }

    /// Whether the file is one Sinampay keeps, and so can be saved elsewhere.
    func isOwned(_ id: UUID) -> Bool { isInInbox(id) || isClip(id) }

    /// The corner cross, "Take down" and a full line all end up here.
    func discard(_ id: UUID, quietly: Bool = false) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if isClip(id) {
            // A clip is only a copy of something you copied: no Trash for it.
            try? FileManager.default.removeItem(at: item.url)
            drop(id, quietly: quietly)
        } else if isInInbox(id) {
            trash(id, quietly: quietly)
        } else {
            drop(id, quietly: quietly)
        }
    }

    /// Keeps a screenshot or clip by moving it to where screenshots used to
    /// go before Sinampay, usually the Desktop.
    func keep(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let target = uniqueURL(in: Inbox.originalFolder, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor, or a text
    /// clip in the default text editor.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isText {
            NSWorkspace.shared.open(item.url)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = thumbnail(url) else { return }
        items[i].thumb = thumb
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget. No wind while it is
    /// tucked away: nobody would see it, and it would only cost energy.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if self.revealed && !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let paths = items.filter { !$0.falling }.map(\.url.path)
        UserDefaults.standard.set(paths, forKey: storeKey)
    }

    /// Called once the line knows how many photos fit on this screen, so a
    /// wide display does not lose photos to the default capacity.
    func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            hang(URL(fileURLWithPath: path), quietly: true)
        }
    }

    // MARK: Helpers

    private func thumbnail(_ url: URL) -> NSImage? {
        ClipboardWatcher.isText(url) ? textThumbnail(url) : makeThumbnail(url)
    }

    private func textThumbnail(_ url: URL) -> NSImage? {
        ClipboardWatcher.text(of: url).flatMap(makeTextThumbnail)
    }

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        return NSImage(contentsOf: url).flatMap(Sinampay.pngData)
    }
}

func makeThumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
