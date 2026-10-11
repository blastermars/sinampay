import AppKit
import Testing
@testable import Sinampay

/// Undo, on a line of real files in a temporary folder. A file there belongs
/// to nobody, like a screenshot on the Desktop: letting it go leaves it in place.
@MainActor
@Suite final class UndoTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SinampayTests-\(UUID().uuidString)", isDirectory: true)
    let line = Line()

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        line.soundOn = false
        line.width = 1200
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func image(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension("png")
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func hang(_ names: [String]) throws -> [UUID] {
        try names.map { try #require(line.hang(try image($0))) }
    }

    private var live: [UUID] { line.items.filter { !$0.falling }.map(\.id) }

    @Test func undoHangsACardBackWhereItWas() throws {
        let ids = try hang(["a", "b", "c"])
        line.beginSlide(ids[1], pointerX: 600)
        line.slide(ids[1], pointerX: 700)
        line.endSlide(ids[1])
        let spot = try #require(line.positions[ids[1]])

        line.discard(ids[1])
        #expect(live == [ids[0], ids[2]])

        line.undo()
        #expect(live == ids)
        #expect(line.positions[ids[1]] == spot)
        #expect(!line.canUndo)
    }

    @Test func undoBeforeTheFallEndsKeepsTheCard() async throws {
        let ids = try hang(["a"])
        line.discard(ids[0])
        line.undo()
        // The fall clears its card after 0.6 seconds; the card put back stays.
        try await Task.sleep(for: .milliseconds(800))
        #expect(live == ids)
        #expect(line.items.count == 1)
    }

    @Test func takeEverythingDownComesBackInOneStep() async throws {
        let ids = try hang(["a", "b", "c"])
        line.clear()
        try await Task.sleep(for: .milliseconds(400))
        #expect(live.isEmpty)

        line.undo()
        #expect(live == ids)
        #expect(!line.canUndo)
    }

    @Test func onlyTheLastTenLetGosComeBack() throws {
        line.maxItems = 20
        let ids = try hang((0..<12).map { "card \($0)" })
        for id in ids { line.discard(id) }

        var undone = 0
        while line.canUndo {
            line.undo()
            undone += 1
        }
        #expect(undone == Line.undoLimit)
        #expect(Set(live) == Set(ids.suffix(Line.undoLimit)))
    }

    @Test func aFullLineLettingGoIsNotUndoable() throws {
        line.maxItems = 2
        _ = try hang(["a", "b", "c"])
        #expect(line.liveCount == 2)
        #expect(!line.canUndo)
    }

    @Test func aTrashedCardComesBackFromTheTrash() throws {
        let ids = try hang(["trashed"])
        let url = try #require(line.items.first?.url)
        line.trash(ids[0])
        #expect(!FileManager.default.fileExists(atPath: url.path))

        line.undo()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(live == ids)
    }

    /// Clips used to be deleted outright when let go. Now they wait in the
    /// undo folder. This one test writes to the app's real Clipboard folder.
    @Test func aClipComesBackFromTheUndoFolder() throws {
        try FileManager.default.createDirectory(at: ClipboardWatcher.folder, withIntermediateDirectories: true)
        let clip = ClipboardWatcher.folder.appendingPathComponent("Clip test \(UUID().uuidString).txt")
        try Data("sipit".utf8).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let id = try #require(line.hang(clip))

        line.discard(id)
        #expect(!FileManager.default.fileExists(atPath: clip.path))

        line.undo()
        #expect(FileManager.default.fileExists(atPath: clip.path))
        #expect(live == [id])
    }
}
