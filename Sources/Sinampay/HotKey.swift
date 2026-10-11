import AppKit
import Carbon

/// A single global shortcut through the Carbon hot key API. Unlike a global
/// key monitor, it needs no Accessibility permission.
final class HotKey {
    struct Preset {
        let id: String
        let keyCode: Int
        let modifiers: Int
        /// For the menu item's key equivalent.
        let key: String
        let mask: NSEvent.ModifierFlags
    }

    static let presets: [Preset] = [
        Preset(id: "ctrl-opt-s", keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey, key: "s", mask: [.control, .option]),
        Preset(id: "ctrl-opt-t", keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey, key: "t", mask: [.control, .option]),
        Preset(id: "ctrl-opt-v", keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey, key: "v", mask: [.control, .option]),
        Preset(id: "ctrl-opt-space", keyCode: kVK_Space, modifiers: controlKey | optionKey, key: " ", mask: [.control, .option]),
    ]

    /// The chosen shortcut, or nil when turned off.
    static var chosen: Preset? {
        get {
            let id = UserDefaults.standard.string(forKey: "hotKey") ?? presets[0].id
            return presets.first { $0.id == id }
        }
        set { UserDefaults.standard.set(newValue?.id ?? "off", forKey: "hotKey") }
    }

    private var ref: EventHotKeyRef?
    /// Each shortcut has its own id, so the show/hide shortcut and ⌘Z for
    /// undo can be held at the same time.
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// Whether macOS accepted the shortcut. It refuses one another app
    /// already holds; the menu says so instead of failing silently.
    private(set) var isRegistered = false

    convenience init(_ preset: Preset, action: @escaping () -> Void) {
        self.init(keyCode: preset.keyCode, modifiers: preset.modifiers, action: action)
    }

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action
        if !HotKey.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { HotKey.actions[pressed.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.handlerInstalled = status == noErr
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5341_4D50), id: id) // "SAMP"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr && HotKey.handlerInstalled
        if !isRegistered {
            log.error("Could not register shortcut \(keyCode, privacy: .public)/\(modifiers, privacy: .public): \(status)")
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }
}
