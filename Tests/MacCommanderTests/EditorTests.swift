import AppKit
import Testing
@testable import MacCommander

@MainActor
final class EditorTests {
    let dir: String
    let cmd: Commander

    init() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCommanderTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        cmd = Commander(view: TerminalView(fontSize: 16))
    }

    deinit {
        // Restore write access in case a test made the folder read-only, so it can be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func path(_ name: String) -> String { (dir as NSString).appendingPathComponent(name) }

    /// Opens `file` in the editor, replaces its text and saves.
    private func edit(_ file: String, to text: String) throws {
        let ed = try #require(Editor(cmd, path: file))
        ed.lines = text.components(separatedBy: "\n").map { Array($0) }
        #expect(ed.save())
    }

    private func read(_ file: String) throws -> String { try String(contentsOfFile: file, encoding: .utf8) }

    @Test func savesContentAndKeepsCrlfLineEnds() throws {
        let f = path("a.txt")
        try "one\r\ntwo".write(toFile: f, atomically: true, encoding: .utf8)
        try edit(f, to: "one\nthree")
        #expect(try read(f) == "one\r\nthree")
    }

    @Test func createsNewFiles() throws {
        let f = path("new.txt")
        try edit(f, to: "hello")
        #expect(try read(f) == "hello")
    }

    @Test func keepsPermissions() throws {
        let f = path("script.sh")
        try "echo".write(toFile: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: f)
        try edit(f, to: "echo hi")
        let perms = try FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as? Int
        #expect(perms == 0o750)
    }

    @Test func savingThroughASymlinkUpdatesTheTarget() throws {
        let target = path("target.txt"), link = path("link.txt")
        try "old".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        try edit(link, to: "new")
        #expect(try read(target) == "new")
        let type = try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
    }

    @Test func leavesNoTemporaryFilesBehind() throws {
        let f = path("a.txt")
        try "x".write(toFile: f, atomically: true, encoding: .utf8)
        try edit(f, to: "y")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["a.txt"])
    }

    @Test func fallsBackToInPlaceWriteInAReadOnlyFolder() throws {
        let f = path("a.txt")
        try "x".write(toFile: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        try edit(f, to: "y")
        #expect(try read(f) == "y")
    }
}
