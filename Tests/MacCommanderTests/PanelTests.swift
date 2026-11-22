import Darwin
import Foundation
import Testing
@testable import MacCommander

// A class (not a struct) so that `deinit` can clean up; `deinit` runs when the last reference goes away,
// which under ARC is deterministic (unlike Java finalizers). Each test gets its own instance.
/// Creates a fresh temporary directory per test and deletes it again afterwards.
final class PanelTests {
    let dir: String

    init() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("MacCommanderTests-" + UUID().uuidString)
        // `try` passes a thrown error on to the caller, here the test runner, which marks the test failed.
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Creates a file with `size` bytes and the given modification date.
    private func file(_ name: String, size: Int = 0, date: Date? = nil) throws {
        let path = (dir as NSString).appendingPathComponent(name)
        try Data(count: size).write(to: URL(fileURLWithPath: path))
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    }

    private func subdir(_ name: String) throws {
        try FileManager.default.createDirectory(atPath: (dir as NSString).appendingPathComponent(name),
                                                withIntermediateDirectories: false)
    }

    /// The names a panel shows, in display order.
    private func names(_ p: Panel) -> [String] { p.entries.map(\.name) }

    @Test func listsParentFirstThenDirectoriesThenFilesByName() throws {
        try file("b.txt"); try file("A.txt"); try file("file10"); try file("file9")
        try subdir("zdir"); try subdir("adir")
        let p = Panel(path: dir)
        #expect(p.path == (dir as NSString).standardizingPath)
        // Names compare like Finder: case-insensitive and with numbers by value ("file9" before "file10").
        #expect(names(p) == ["..", "adir", "zdir", "A.txt", "b.txt", "file9", "file10"])
        #expect(p.entries[1].isDir)
        #expect(!p.entries[3].isDir)
    }

    @Test func sortsByExtensionSizeAndTime() throws {
        let now = Date()
        try file("c.txt", size: 10, date: now.addingTimeInterval(-300))
        try file("a.md", size: 30, date: now.addingTimeInterval(-100))
        try file("b.txt", size: 20, date: now.addingTimeInterval(-200))
        try subdir("d")
        let p = Panel(path: dir)
        // Setting `sort` re-reads the directory (a `didSet` observer on the property).
        p.sort = .ext
        #expect(names(p) == ["..", "d", "a.md", "b.txt", "c.txt"])
        p.sort = .size
        #expect(names(p) == ["..", "d", "a.md", "b.txt", "c.txt"])
        p.sort = .time
        #expect(names(p) == ["..", "d", "a.md", "b.txt", "c.txt"])
        p.sort = .name
        #expect(names(p) == ["..", "d", "a.md", "b.txt", "c.txt"])
        // Reverse the sizes to prove `.size` is not just name order.
        try file("a.md", size: 1)
        p.sort = .size
        #expect(names(p) == ["..", "d", "b.txt", "c.txt", "a.md"])
    }

    @Test func hiddenFilesAreShownOnlyWhenEnabled() throws {
        try file(".hidden"); try file("visible")
        let p = Panel(path: dir)
        #expect(names(p) == ["..", "visible"])
        p.showHidden = true
        p.reload()
        #expect(names(p) == ["..", ".hidden", "visible"])
        #expect(p.entries[1].isHidden)
    }

    @Test func rootHasNoParentEntry() {
        let p = Panel(path: "/")
        #expect(p.path == "/")
        #expect(!names(p).contains(".."))
    }

    @Test func nonExistingPathFallsBackToHome() {
        let p = Panel(path: dir + "/does-not-exist")
        #expect(p.path == (NSHomeDirectory() as NSString).standardizingPath)
    }

    @Test func cdReportsErrorsAndKeepsTheOldDirectory() throws {
        try file("x")
        let p = Panel(path: dir)
        let before = p.path
        // `cd` returns nil on success and an error message otherwise.
        #expect(p.cd(dir + "/missing") != nil)
        #expect(p.path == before)
        #expect(names(p) == ["..", "x"])
    }

    @Test func goUpFocusesTheDirectoryJustLeft() throws {
        try subdir("a"); try subdir("b")
        let p = Panel(path: dir + "/b")
        #expect(p.goUp() == nil)
        #expect(p.path == (dir as NSString).standardizingPath)
        #expect(p.current?.name == "b")
    }

    @Test func selectByMaskSkipsDirectoriesAndIsCaseInsensitive() throws {
        try file("a.TXT"); try file("b.txt"); try file("c.jpg"); try subdir("d.txt")
        let p = Panel(path: dir)
        p.select(pattern: "*.txt", on: true)
        #expect(p.selected == ["a.TXT", "b.txt"])
        // Several masks separated by ',' or ';'; "*.*" means all files, as in DOS.
        p.select(pattern: "*.txt; *.jpg", on: false)
        #expect(p.selected.isEmpty)
        p.select(pattern: "*.*", on: true)
        #expect(p.selected == ["a.TXT", "b.txt", "c.jpg"])
    }

    @Test func invertTogglesFilesOnly() throws {
        try file("a"); try file("b"); try subdir("d")
        let p = Panel(path: dir)
        p.selected = ["a"]
        p.invert()
        #expect(p.selected == ["b"])
    }

    @Test func targetsPreferSelectionThenCursorButNeverParent() throws {
        try file("a"); try file("b")
        let p = Panel(path: dir)
        // Cursor on "..": nothing to operate on.
        p.cursor = 0
        #expect(p.targets().isEmpty)
        p.cursor = 2
        #expect(p.targets().map(\.name) == ["b"])
        p.selected = ["a", ".."]
        #expect(p.targets().map(\.name) == ["a"])
    }

    @Test func toggleSelectIgnoresParent() throws {
        try file("a")
        let p = Panel(path: dir)
        p.cursor = 0
        p.toggleSelect()
        #expect(p.selected.isEmpty)
        p.cursor = 1
        p.toggleSelect()
        #expect(p.selected == ["a"])
        p.toggleSelect()
        #expect(p.selected.isEmpty)
    }

    @Test func moveClampsTheCursor() throws {
        try file("a"); try file("b")
        let p = Panel(path: dir)
        p.move(10)
        #expect(p.cursor == 2)
        p.move(-10)
        #expect(p.cursor == 0)
    }

    @Test func reloadKeepsCursorNameAndDropsVanishedSelections() throws {
        try file("a"); try file("b"); try file("c")
        let p = Panel(path: dir)
        p.cursor = 3
        p.selected = ["a", "c"]
        try FileManager.default.removeItem(atPath: dir + "/a")
        p.reload()
        #expect(p.current?.name == "c")
        #expect(p.selected == ["c"])
    }

    @Test func reloadMovesUpWhenTheDirectoryWasDeleted() throws {
        try subdir("gone")
        let p = Panel(path: dir + "/gone")
        try FileManager.default.removeItem(atPath: dir + "/gone")
        p.reload()
        #expect(p.path == (dir as NSString).standardizingPath)
    }

    @Test func sizeTextForParentDirectoriesAndFiles() throws {
        try file("f", size: 1234); try subdir("d")
        let p = Panel(path: dir)
        let up = p.entries[0], d = p.entries[1], f = p.entries[2]
        #expect(p.sizeText(up) == "►UP--DIR◄")
        #expect(p.sizeText(d) == "►SUB-DIR◄")
        #expect(p.sizeText(f) == "1234")
        // `dirSizes` holds an optional per directory: nil = scan still running, a number = finished.
        p.dirSizes["d"] = .some(nil)
        #expect(p.sizeText(d) == "…")
        p.dirSizes["d"] = .some(42)
        #expect(p.sizeText(d) == "42")
    }

    @Test(arguments: [
        (UInt16(S_IFDIR) | 0o755, false, "drwxr-xr-x"),
        (UInt16(S_IFREG) | 0o644, false, "-rw-r--r--"),
        (UInt16(S_IFLNK) | 0o777, true, "lrwxrwxrwx"),
        (UInt16(S_IFREG) | 0o4755, false, "-rwsr-xr-x"),
        (UInt16(S_IFREG) | 0o2644, false, "-rw-r-Sr--"),
        (UInt16(S_IFDIR) | 0o1777, false, "drwxrwxrwt"),
        (UInt16(S_IFDIR) | 0o1776, false, "drwxrwxrwT"),
    ])
    func permString(mode: UInt16, isLink: Bool, expected: String) {
        let e = FileEntry(name: "x", url: URL(fileURLWithPath: "/x"), isDir: false, isLink: isLink, mode: mode)
        #expect(e.permString == expected)
    }
}
