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

    @Test func wheelOverAHiddenPanelDoesNothing() {
        cmd.left.visible = false
        cmd.scroll(x: 0, y: 5, delta: 2)
        #expect(cmd.left.cursor == 0)
    }
}
