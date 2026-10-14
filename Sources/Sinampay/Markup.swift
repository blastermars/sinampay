import AppKit
import UniformTypeIdentifiers

/// Opens a screenshot in the system Markup editor, the window macOS shows
/// when you click the thumbnail of a screenshot you just took. It is a
/// system extension, reached through the sharing service it registers.
@MainActor
final class Markup {
    static let shared = Markup()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }

    /// Editors still open. Each has its own delegate, so two screenshots in
    /// Markup at once each save back to their own file.
    private var sessions: [MarkupSession] = []
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    /// `done` runs once the editor closes, after any edit has been written
    /// back, with whether there was one: Done, or cancelled.
    func edit(_ url: URL, then done: @escaping (_ saved: Bool) -> Void = { _ in }) {
        guard let service = NSSharingService(named: Markup.serviceName),
              service.canPerform(withItems: [url]) else {
            // Without the extension, Preview is the closest thing.
            NSWorkspace.shared.open(url)
            done(false)
            return
        }
        let anchor = Markup.anchor(on: LinePanel.screenUnderPointer())
        let session = MarkupSession(target: url, anchor: anchor) { [weak self] session, saved in
            self?.sessions.removeAll { $0 === session }
            anchor.orderOut(nil)
            if saved { self?.onSaved(url) }
            done(saved)
        }
        sessions.append(session)
        service.delegate = session
        anchor.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    /// The editor opens against a source window. Sinampay has none of its
    /// own, and without one the editor lands in the bottom left corner, so
    /// a clear window over the screen gives it something to center on.
    private static func anchor(on screen: NSScreen?) -> NSWindow {
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        return window
    }
}

/// One trip to the editor, from opening it to writing the result back.
@MainActor
private final class MarkupSession: NSObject, NSSharingServiceDelegate {
    let target: URL
    let anchor: NSWindow
    private var finish: ((MarkupSession, Bool) -> Void)?

    init(target: URL, anchor: NSWindow, finish: @escaping (MarkupSession, Bool) -> Void) {
        self.target = target
        self.anchor = anchor
        self.finish = finish
    }

    private func end(saved: Bool) {
        finish?(self, saved)
        finish = nil
    }

    // MARK: NSSharingServiceDelegate

    nonisolated func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                                    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        MainActor.assumeIsolated { anchor }
    }

    /// Done was pressed. The extension hands back the edited image and the
    /// host app is the one that writes it over the original file.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { self.save(items) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        log.notice("Markup ended without saving: \(error.localizedDescription, privacy: .public)")
        MainActor.assumeIsolated { self.end(saved: false) }
    }

    // MARK: Writing back

    private func save(_ items: [Any]) {
        guard let item = items.first else { return end(saved: false) }
        log.notice("Markup returned \(String(describing: type(of: item)), privacy: .public)")

        switch item {
        case let url as URL:
            write(from: url)
        case let image as NSImage:
            write(data: pngData(image))
        case let provider as NSItemProvider:
            load(provider)
        default:
            log.error("Markup returned an unexpected item")
            end(saved: false)
        }
    }

    private func load(_ provider: NSItemProvider) {
        let types = provider.registeredTypeIdentifiers
        log.notice("Markup provider types: \(types.joined(separator: ", "), privacy: .public)")

        if types.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { self.write(from: url) } else { self.end(saved: false) }
                }
            }
            return
        }
        // Prefer the original format, then any image format.
        let original = UTType(filenameExtension: target.pathExtension)?.identifier
        let imageType = types.first { $0 == original }
            ?? types.first { UTType($0)?.conforms(to: .image) == true }
        guard let imageType else { return end(saved: false) }
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
            DispatchQueue.main.async { self.write(data: data) }
        }
    }

    private func write(from source: URL) {
        if source.standardizedFileURL == target.standardizedFileURL {
            end(saved: true)
        } else {
            write(data: try? Data(contentsOf: source))
        }
    }

    private func write(data: Data?) {
        guard let data else { return end(saved: false) }
        do {
            try data.write(to: target, options: .atomic)
            end(saved: true)
        } catch {
            log.error("Could not save markup: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            end(saved: false)
        }
    }
}
