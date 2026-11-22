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

    /// The title row of `v` rendered on a wide screen.
    private func titleRow(_ v: Viewer) -> String {
        let s = Screen(cols: 140, rows: 25)
        v.render(s)
        return String((0..<s.cols).map { s[$0, 0].ch })
    }

    @Test func titleShowsTheSize() throws {
        let size = try #require(FileManager.default.attributesOfItem(atPath: file)[.size] as? Int)
        let title = titleRow(Viewer(cmd, path: file))
        #expect(title.contains("  \(size) bytes  "))
        #expect(!title.contains(" of "))
    }

    @Test func titleSaysWhenTheFileWasCutOff() throws {
        // A sparse file: 65 MiB long but takes no disk space, as it is never written.
        let big = file + ".bin"
        #expect(FileManager.default.createFile(atPath: big, contents: nil))
        defer { try? FileManager.default.removeItem(atPath: big) }
        let h = try #require(FileHandle(forWritingAtPath: big))
        try h.truncate(atOffset: 65 * 1024 * 1024)
        try h.close()
        let v = Viewer(cmd, path: big)
        #expect(v.data.count == 64 * 1024 * 1024)
        #expect(titleRow(v).contains("67.108.864 of 68.157.440 bytes"))
    }

    @Test(arguments: [
        (String.Encoding.utf8, [UInt8]([0xEF, 0xBB, 0xBF])),
        (.utf16LittleEndian, [0xFF, 0xFE]),
        (.utf16BigEndian, [0xFE, 0xFF]),
        (.utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00]),
        (.utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF]),
    ])
    func textWithAByteOrderMarkOpensAsText(encoding: String.Encoding, bom: [UInt8]) throws {
        let f = file + ".txt"
        defer { try? FileManager.default.removeItem(atPath: f) }
        let body = try #require("Grüße\nzweite Zeile".data(using: encoding))
        try (Data(bom) + body).write(to: URL(fileURLWithPath: f))
        let v = Viewer(cmd, path: f)
        #expect(!v.hex)
        #expect(v.lines == ["Grüße", "zweite Zeile"])
    }

    @Test func nulBytesWithoutAByteOrderMarkStillMeanBinary() throws {
        let f = file + ".bin"
        defer { try? FileManager.default.removeItem(atPath: f) }
        try Data([0x41, 0x00, 0x42]).write(to: URL(fileURLWithPath: f))
        #expect(Viewer(cmd, path: f).hex)
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
