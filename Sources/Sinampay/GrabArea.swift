import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Click copies, press and hold opens Markup, the corner cross discards.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        view.url = item.url
        view.text = item.isText ? ClipboardWatcher.text(of: item.url) : nil
        view.dragImage = item.thumb
        view.onClick = { line.copy(id) }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { line.markup(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.onSlideStart = { x in line.beginSlide(id, pointerX: x) }
        view.onSlide = { x in line.slide(id, pointerX: x) }
        view.onSlideEnd = { line.endSlide(id) }

        let owned = line.isOwned(id)
        let keepName = FileManager.default.displayName(atPath: Inbox.originalFolder.path)
        var actions: [(String, () -> Void)] = [
            (L("Copy", fil: "Kopyahin", es: "Copiar"), { line.copy(id) }),
            (L("Open", fil: "Buksan", es: "Abrir"), { line.open(id) }),
        ]
        if !item.isText {
            actions.append((L("Markup", fil: "Markup", es: "Marcación"), { line.markup(id) }))
        }
        actions.append((L("Show in Finder", fil: "Ipakita sa Finder", es: "Mostrar en Finder"), { line.reveal(id) }))
        if owned {
            actions.append((L("Save to \(keepName)", fil: "I-save sa \(keepName)", es: "Guardar en \(keepName)"), { line.keep(id) }))
        }
        let discardTitle = owned ? L("Discard", fil: "Itapon", es: "Descartar")
                                 : L("Take down", fil: "Hanguin", es: "Descolgar")
        let primary = actions

        view.menuProvider = {
            let menu = NSMenu()
            for (title, action) in primary { menu.addItem(ClosureMenuItem(title, handler: action)) }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(discardTitle) { line.discard(id) })
            if !owned {
                menu.addItem(ClosureMenuItem(L("Move to Trash", fil: "Ilipat sa Basurahan", es: "Mover a la Papelera")) { line.trash(id) })
            }
            return menu
        }

        // VoiceOver: each card is a button that copies, with the rest of the
        // menu as custom actions.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(item.isText
            ? L("Copied text: ", fil: "Kinopyang teksto: ", es: "Texto copiado: ") + String((view.text ?? "").prefix(120))
            : L("Screenshot ", fil: "Screenshot ", es: "Captura ") + item.url.deletingPathExtension().lastPathComponent)
        view.setAccessibilityHelp(L("Press to copy", fil: "Pindutin para kopyahin", es: "Pulsa para copiar"))
        view.setAccessibilityCustomActions((primary.dropFirst() + [(discardTitle, { line.discard(id) })]).map { title, action in
            NSAccessibilityCustomAction(name: title) { action(); return true }
        })
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false
    /// A card is being slid along the line.
    static var isSliding = false

    var url: URL?
    /// For a text clip: dragged into an app as text, not as a file.
    var text: String?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    /// Sliding along the line, with the pointer's x in window coordinates.
    var onSlideStart: (CGFloat) -> Void = { _ in }
    var onSlide: (CGFloat) -> Void = { _ in }
    var onSlideEnd: () -> Void = {}
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var sliding = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    /// How far a card is pulled down off the line before it leaves it as a
    /// drag to another app, a folder or the Trash.
    private static let pullOffDistance: CGFloat = 60

    /// Sideways slides the card along the line; pulling it down takes it off
    /// the line and into a regular drag. A slide that wanders down far enough
    /// turns into that drag too, so there is never a mode to switch.
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, !didLongPress else { return }
        let p = event.locationInWindow
        let dx = p.x - start.x, dy = p.y - start.y   // y grows upwards
        if !sliding {
            guard hypot(dx, dy) > 4 else { return }
            endPress()
            if -dy > abs(dx) {
                beginDragOut(with: event)
            } else {
                sliding = true
                GrabView.isSliding = true
                onSlideStart(start.x)
                onSlide(p.x)
            }
            return
        }
        if -dy > Self.pullOffDistance {
            endSlide()
            beginDragOut(with: event)
        } else {
            onSlide(p.x)
        }
    }

    private func endSlide() {
        guard sliding else { return }
        sliding = false
        GrabView.isSliding = false
        onSlideEnd()
    }

    private func beginDragOut(with event: NSEvent) {
        guard let url else { return }
        startedDrag = true
        let writer: NSPasteboardWriting = text.map { $0 as NSString } ?? url as NSURL
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        let wasSliding = sliding
        endSlide()
        if downPoint != nil && !startedDrag && !didLongPress && !wasSliding && event.clickCount == 1 { onClick() }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        context == .outsideApplication ? [.copy, .move, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
