import Foundation

/// Inbox mode: Sinampay takes over where screenshots go.
///
/// It changes two macOS screenshot settings, the same ones in the Options
/// menu of Cmd+Shift+5: the floating thumbnail is turned off, so the file is
/// written at once instead of five seconds later, and the save location
/// becomes Sinampay's own folder, so the Desktop only gets what you keep.
///
/// The previous values are saved first and put back when the mode is turned
/// off or the app quits, so macOS is never left pointing at a folder nobody
/// is watching.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    /// macOS 26 and earlier read "location". macOS 27 reads
    /// "location-screenshot" and ignores the old key, so both are written.
    private static let locationKey = "location" as CFString
    private static let screenshotLocationKey = "location-screenshot" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString

    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

    static let folder: URL = AppFolders.base.appendingPathComponent("Screenshots", isDirectory: true)

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    /// Whether macOS is currently sending screenshots to our folder, through
    /// either key.
    static var isApplied: Bool {
        [locationKey, screenshotLocationKey].contains { key in
            guard let current = CFPreferencesCopyAppValue(key, domain) as? String else { return false }
            return URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL
                == folder.standardizedFileURL
        }
    }

    /// Where screenshots went before Sinampay took over: that is where
    /// "Save" puts the ones you keep.
    static var originalFolder: URL {
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        let raw = (saved["locationScreenshot"] as? String) ?? (saved["location"] as? String)
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return ScreenshotWatcher.desktop
    }

    static func apply() {
        ensureFolder()
        // Never save our own values as the "previous" ones, for example after
        // a crash left them applied.
        if !isApplied {
            let saved: [String: Any] = [
                "location": CFPreferencesCopyAppValue(locationKey, domain) as? String ?? NSNull(),
                "locationScreenshot": CFPreferencesCopyAppValue(screenshotLocationKey, domain) as? String ?? NSNull(),
                "thumbnail": CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool ?? NSNull(),
            ]
            UserDefaults.standard.set(saved.compactMapValues { $0 is NSNull ? nil : $0 }, forKey: savedKey)
        }
        set(locationKey, folder.path)
        set(screenshotLocationKey, folder.path)
        set(thumbnailKey, false)
    }

    static func restore() {
        guard isApplied else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        set(locationKey, saved["location"])
        set(screenshotLocationKey, saved["locationScreenshot"])
        set(thumbnailKey, saved["thumbnail"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// The user chose another save location while the mode was on. Their
    /// choice stands: the mode turns off and the old values are forgotten,
    /// so quitting does not undo what they just picked.
    static func relinquish() {
        isEnabled = false
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        set(thumbnailKey, saved["thumbnail"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// At launch: if the mode is off but macOS still points at our folder
    /// (an earlier crash, or a copy of the app that was deleted mid-session),
    /// give the user their settings back.
    static func repairIfOrphaned() {
        if !isEnabled && isApplied {
            log.notice("Screenshot settings were left pointing at the inbox; restoring them")
            restore()
        }
    }

    /// The folder can be deleted from Finder while the app runs; screenshots
    /// sent there would then fail silently, so it is recreated on demand.
    static func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }

    // MARK: Crashes

    /// A crash would otherwise leave macOS saving screenshots into a folder
    /// nobody watches. This is a best effort: writing preferences from a
    /// crash handler is not strictly safe, but it is the last chance to do
    /// it, and the signal is re-raised right after so the crash report is
    /// still written. `repairIfOrphaned` covers whatever this misses.
    static func restoreOnCrash() {
        NSSetUncaughtExceptionHandler { _ in
            if Inbox.isEnabled { Inbox.restore() }
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGTRAP, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { sig in
                if Inbox.isEnabled { Inbox.restore() }
                signal(sig, SIG_DFL)
                raise(sig)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESETHAND
            sigaction(sig, &action, nil)
        }
    }
}

/// Everything Sinampay writes lives under Application Support.
enum AppFolders {
    static let base: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sinampay", isDirectory: true)
    }()

    static func contains(_ url: URL, in folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }
}
