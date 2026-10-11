import AppKit
import Combine
import os
import SwiftUI

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

    /// Where cards were slid to by hand, as a fraction of the line's width.
    /// Cards without one hang in even slots.
    @Published private(set) var positions: [UUID: CGFloat] = [:]
    /// The card being slid right now.
    @Published private(set) var slidingID: UUID?
    /// The order cards overlap in, back to front. A new card hangs in front,
    /// and so does the card you last clicked, until you click another.
    @Published private(set) var stacking: [UUID] = []
    /// The Undo chip shows on the line for a few seconds after a let go.
    @Published private(set) var undoOffered = false
    /// The line's width in points, kept by the app as the screen changes.
    var width: CGFloat = 1
    private var slideOffset: CGFloat = 0

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8

    /// What was let go this session, newest last, so Undo can hang it back
    /// up. "Take everything down" is one entry, and comes back in one go.
    private var undoStack: [[LetGo]] = []
    private var undoOfferToken = UUID()
    static let undoLimit = 10
    /// The Undo chip's hit rect, next to the cards' in `hitRects`.
    static let undoChipID = UUID()

    var canUndo: Bool { !undoStack.isEmpty }

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
    private let positionsKey = "peggedPositions"
    private let stackingKey = "peggedStacking"

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
        stacking.append(item.id)
        // A full line lets the oldest photo fall off the far end. If it is
        // one of ours, its file goes with it, or the folder would fill up
        // with screenshots and clips nobody can see. Nobody let it go, so
        // there is nothing to undo.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            discard(oldest.id, quietly: true, undoable: false)
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
        positions[id] = nil
        stacking.removeAll { $0 == id }
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            // Unless Undo hung it back up before it finished falling.
            self?.items.removeAll { $0.id == id && $0.falling }
        }
    }

    /// "Take everything down": the same as the cross on every photo, and one
    /// Undo brings them all back.
    func clear() {
        let live = items.filter { !$0.falling }
        let group = UUID()
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0, group: group)
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
    func trash(_ id: UUID, quietly: Bool = false, undoable: Bool = true, group: UUID = UUID()) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            if undoable { remember(id, movedTo: trashed as URL?, group: group) }
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
    func discard(_ id: UUID, quietly: Bool = false, undoable: Bool = true, group: UUID = UUID()) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if isClip(id) {
            // A clip is only a copy of something you copied: no Trash for it.
            // It waits in the undo folder in case you want it back.
            if undoable, let kept = stash(item.url) {
                remember(id, movedTo: kept, group: group)
            } else {
                try? FileManager.default.removeItem(at: item.url)
            }
            drop(id, quietly: quietly)
        } else if isInInbox(id) {
            trash(id, quietly: quietly, undoable: undoable, group: group)
        } else {
            if undoable { remember(id, movedTo: nil, group: group) }
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

    // MARK: Moving along the line

    /// Where a card hangs along the line: where it was slid to, or its slot.
    func x(at index: Int, width: CGFloat) -> CGFloat {
        let slot = Layout.x(index: index, count: items.count, width: width)
        guard items.indices.contains(index), let f = positions[items[index].id] else { return slot }
        return clamp(f * width, width: width)
    }

    func x(of id: UUID, width: CGFloat) -> CGFloat? {
        items.firstIndex { $0.id == id }.map { x(at: $0, width: width) }
    }

    func beginSlide(_ id: UUID, pointerX: CGFloat) {
        guard let x = x(of: id, width: width) else { return }
        slideOffset = x - pointerX
        slidingID = id
    }

    /// The card follows the pointer, keeping the spot where it was grabbed.
    func slide(_ id: UUID, pointerX: CGFloat) {
        guard slidingID == id, width > 0 else { return }
        positions[id] = clamp(pointerX + slideOffset, width: width) / width
    }

    func endSlide(_ id: UUID) {
        guard slidingID == id else { return }
        slidingID = nil
        save()
    }

    /// A clicked card comes to the front, over any card it overlaps.
    func bringToFront(_ id: UUID) {
        guard stacking.last != id, stacking.contains(id) else { return }
        stacking.removeAll { $0 == id }
        stacking.append(id)
        save()
    }

    func zIndex(of id: UUID) -> Double {
        Double(stacking.firstIndex(of: id) ?? 0)
    }

    var isTidy: Bool { positions.isEmpty }

    /// Every card back into even slots.
    func tidy() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { positions = [:] }
        save()
    }

    private func clamp(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let margin = Layout.cardWidth / 2 + 8
        return min(max(x, margin), max(margin, width - margin))
    }

    // MARK: Undo

    /// One card let go, with what it takes to hang it back up as it was.
    private struct LetGo {
        let item: Pegged
        let index: Int
        let position: CGFloat?
        /// Where its file went: the Trash, or the undo folder for a clip.
        /// Nil when the file stayed where it was.
        let movedTo: URL?
        let group: UUID
    }

    /// Clips let go this session wait here instead of being deleted, so Undo
    /// can bring them back. Emptied at launch and at quit.
    nonisolated static let undoFolder = AppFolders.base.appendingPathComponent("Undo", isDirectory: true)

    /// Hangs the last thing let go back up where it was, with the same tilt
    /// and sipit. Its file comes back from the Trash or the undo folder.
    func undo() {
        guard let entries = undoStack.popLast() else { return }
        undoOffered = false
        let fm = FileManager.default
        var restored = Set<UUID>()
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            let item = entry.item
            if let from = entry.movedTo {
                do {
                    try fm.moveItem(at: from, to: item.url)
                } catch {
                    log.error("Could not put back \(item.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            guard fm.fileExists(atPath: item.url.path),
                  !items.contains(where: { $0.url == item.url && !$0.falling }) else { continue }
            // Brought back before it finished falling: the falling copy goes.
            items.removeAll { $0.id == item.id }
            items.insert(item, at: min(entry.index, items.count))
            stacking.removeAll { $0 == item.id }
            stacking.append(item.id)
            if let f = entry.position { positions[item.id] = f }
            restored.insert(item.id)
        }
        guard !restored.isEmpty else {
            NSSound.beep()
            return
        }
        // A line that filled up meanwhile makes room, but not by dropping
        // what was just put back.
        while liveCount > maxItems,
              let oldest = items.first(where: { !$0.falling && !restored.contains($0.id) }) {
            discard(oldest.id, quietly: true, undoable: false)
        }
        save()
        play("Tink", volume: 0.35)
    }

    /// Called just before a card falls, while it still knows its place.
    private func remember(_ id: UUID, movedTo: URL?, group: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        item.falling = false
        item.flying = false
        let entry = LetGo(item: item, index: index, position: positions[id], movedTo: movedTo, group: group)
        if undoStack.last?.first?.group == group {
            undoStack[undoStack.count - 1].append(entry)
        } else {
            undoStack.append([entry])
        }
        while undoStack.count > Self.undoLimit { forget(undoStack.removeFirst()) }
        offerUndo()
    }

    private func offerUndo() {
        let token = UUID()
        undoOfferToken = token
        undoOffered = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.undoOfferToken == token else { return }
            self.undoOffered = false
        }
    }

    private func stash(_ url: URL) -> URL? {
        let target = Self.undoFolder.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.createDirectory(at: Self.undoFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            log.error("Could not keep clip for undo: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Past the last ten, a clip can no longer come back and is deleted for
    /// good. Trashed files stay in the Trash, as they always did.
    private func forget(_ entries: [LetGo]) {
        for url in entries.compactMap(\.movedTo) where AppFolders.contains(url, in: Self.undoFolder) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Clips from an earlier session are gone for good.
    nonisolated static func forgetAll() {
        try? FileManager.default.removeItem(at: undoFolder)
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
        let live = items.filter { !$0.falling }
        UserDefaults.standard.set(live.map(\.url.path), forKey: storeKey)
        var saved: [String: Double] = [:]
        for item in live { if let f = positions[item.id] { saved[item.url.path] = Double(f) } }
        UserDefaults.standard.set(saved, forKey: positionsKey)
        let paths = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.url.path) })
        UserDefaults.standard.set(stacking.compactMap { paths[$0] }, forKey: stackingKey)
    }

    /// Called once the line knows how many photos fit on this screen, so a
    /// wide display does not lose photos to the default capacity.
    func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        let saved = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        let stacked = UserDefaults.standard.stringArray(forKey: stackingKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            if let id = hang(URL(fileURLWithPath: path), quietly: true), let f = saved[path] {
                positions[id] = CGFloat(f)
            }
        }
        // Overlapping cards stack the way they did; any not in the saved order
        // keep the order they hung in, at the back.
        let rank = { (id: UUID) -> Int in
            self.items.first { $0.id == id }.flatMap { stacked.firstIndex(of: $0.url.path) } ?? -1
        }
        stacking = stacking.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        save()
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
