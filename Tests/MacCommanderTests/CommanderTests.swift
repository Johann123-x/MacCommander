import AppKit
import Testing
@testable import MacCommander

/// Tests of `Commander` behaviour with both panels pointing at temporary directories.
@MainActor
final class CommanderTests {
    let leftDir: String
    let rightDir: String
    let cmd = Commander(view: TerminalView(fontSize: 16))

    init() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCommanderTests-" + UUID().uuidString)
        leftDir = base + "/left"
        rightDir = base + "/right"
        for d in [leftDir, rightDir] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            for n in ["a", "b", "c", "d"] { try Data().write(to: URL(fileURLWithPath: d + "/" + n)) }
        }
        #expect(cmd.left.cd(leftDir) == nil)
        #expect(cmd.right.cd(rightDir) == nil)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: (leftDir as NSString).deletingLastPathComponent)
    }

    @Test func wheelScrollsTheVisiblePanelUnderTheMouse() {
        cmd.scroll(x: 0, y: 5, delta: 2)
        #expect(cmd.left.cursor == 2)
        #expect(cmd.right.cursor == 0)
    }

    /// Writes `text` to `name` in `dir` with the given modification date.
    private func put(_ dir: String, _ name: String, _ text: String, date: Date = Date()) throws {
        let p = dir + "/" + name
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: p)
    }

    /// Compares the two panels after re-reading them.
    private func compare(byContent: Bool) -> (left: Set<String>, right: Set<String>) {
        cmd.left.reload()
        cmd.right.reload()
        return Commander.differences(cmd.left.entries, cmd.right.entries, byContent: byContent)
    }

    @Test func compareByDateSelectsTheNewerSideAndOneSidedFiles() throws {
        let old = Date(timeIntervalSince1970: 1_000_000_000), new = old.addingTimeInterval(60)
        for n in ["a", "b", "c", "d"] {
            try put(leftDir, n, "x", date: old)
            try put(rightDir, n, "x", date: old)
        }
        try put(leftDir, "a", "x", date: new)
        try put(rightDir, "b", "different", date: new)
        try put(leftDir, "only-left", "x")
        // Same date, different content: the date comparison does not see it.
        try put(rightDir, "c", "yy", date: old)
        let d = compare(byContent: false)
        #expect(d.left == ["a", "only-left"])
        #expect(d.right == ["b"])
    }

    @Test func compareByContentSelectsDifferingFilesOnBothSides() throws {
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        for n in ["a", "b", "c", "d"] {
            try put(leftDir, n, "same", date: old)
            try put(rightDir, n, "same", date: old.addingTimeInterval(3600))
        }
        try put(rightDir, "b", "diff")
        try put(rightDir, "c", "longer content")
        try put(rightDir, "only-right", "x")
        try FileManager.default.createDirectory(atPath: leftDir + "/dir", withIntermediateDirectories: false)
        let d = compare(byContent: true)
        // Different dates alone do not count; directories are ignored.
        #expect(d.left == ["b", "c"])
        #expect(d.right == ["b", "c", "only-right"])
    }

    @Test func compareCanBeCancelled() throws {
        try put(leftDir, "a", "1")
        try put(rightDir, "a", "2")
        cmd.left.reload()
        cmd.right.reload()
        let d = Commander.differences(cmd.left.entries, cmd.right.entries, byContent: true) { true }
        #expect(d.left.isEmpty && d.right.isEmpty)
    }

    @Test func filesEqualComparesBytes() throws {
        try put(leftDir, "a", "abc")
        try put(rightDir, "a", "abc")
        try put(rightDir, "b", "abd")
        try put(rightDir, "c", "abcd")
        let u = { (dir: String, name: String) in URL(fileURLWithPath: dir + "/" + name) }
        #expect(filesEqual(u(leftDir, "a"), u(rightDir, "a")))
        #expect(!filesEqual(u(leftDir, "a"), u(rightDir, "b")))
        #expect(!filesEqual(u(leftDir, "a"), u(rightDir, "c")))
        #expect(!filesEqual(u(leftDir, "a"), u(rightDir, "missing")))
    }

    @Test func filesEqualHandlesFilesLargerThanOneChunk() throws {
        var bytes = Data(repeating: 7, count: (1 << 20) * 2 + 5)
        try bytes.write(to: URL(fileURLWithPath: leftDir + "/big"))
        try bytes.write(to: URL(fileURLWithPath: rightDir + "/big"))
        #expect(filesEqual(URL(fileURLWithPath: leftDir + "/big"), URL(fileURLWithPath: rightDir + "/big")))
        // Differ only in the very last byte, in the third chunk.
        bytes[bytes.count - 1] = 8
        try bytes.write(to: URL(fileURLWithPath: rightDir + "/big"))
        #expect(!filesEqual(URL(fileURLWithPath: leftDir + "/big"), URL(fileURLWithPath: rightDir + "/big")))
    }

    @Test func wheelOverAHiddenPanelDoesNothing() {
        cmd.left.visible = false
        cmd.scroll(x: 0, y: 5, delta: 2)
        #expect(cmd.left.cursor == 0)
    }
}
