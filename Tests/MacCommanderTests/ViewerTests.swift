import AppKit
import Testing
@testable import MacCommander

// `@MainActor` runs these tests on the main thread, as AppKit views must be created there.
// The Commander is built around an off-screen view; it is never shown in a window.
@MainActor
final class ViewerTests {
    let file: String
    let cmd: Commander

    init() throws {
        file = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCommanderTests-" + UUID().uuidString + ".md")
        let long = String(repeating: "word ", count: 60)
        try ("# Title\n\n" + long + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        cmd = Commander(view: TerminalView(fontSize: 16))
    }

    deinit {
        try? FileManager.default.removeItem(atPath: file)
    }

    @Test func formattedMarkdownDoesNotScrollSideways() {
        let v = Viewer(cmd, path: file)
        #expect(v.formatted)
        v.handle(KeyEvent(key: .right))
        // Regression: the guard case used to come after the plain `.right` case and never matched.
        #expect(v.left == 0)
    }

    @Test func rawTextScrollsSideways() {
        let v = Viewer(cmd, path: file)
        // F3 switches a Markdown file between formatted and raw view.
        v.handle(KeyEvent(key: .f(3)))
        #expect(!v.formatted)
        v.handle(KeyEvent(key: .right))
        #expect(v.left == 8)
        v.handle(KeyEvent(key: .left))
        #expect(v.left == 0)
    }
}
