import Foundation
import Testing
// `@testable` also exposes `internal` (module-visible) declarations to the tests, similar to placing
// a JUnit test in the same Java package to reach package-private members.
@testable import MacCommander

// Swift Testing: a `@Test` function is a test case (like JUnit's `@Test`), `#expect` is an assertion
// that records a failure and continues, `#require` stops the test (like an assumption that must hold).
// A struct groups related tests, like a JUnit test class; a new instance is created for every test.
struct ScreenTests {
    /// Returns row `y` of the grid as a string, to compare whole lines at once.
    private func row(_ s: Screen, _ y: Int) -> String {
        String((0..<s.cols).map { s[$0, y].ch })
    }

    @Test func textClipsAtTheRightEdge() {
        let s = Screen(cols: 5, rows: 1)
        let end = s.text(3, 0, "abc", Col.white, Col.blue)
        #expect(row(s, 0) == "   ab")
        // The returned column is past the last character, even when it was clipped.
        #expect(end == 6)
        #expect(s[3, 0].fg == Col.white)
        #expect(s[3, 0].bg == Col.blue)
    }

    @Test func putIgnoresCoordinatesOutsideTheGrid() {
        let s = Screen(cols: 2, rows: 2)
        s.put(-1, 0, "x", Col.white, Col.black)
        s.put(0, 2, "x", Col.white, Col.black)
        s.put(2, 1, "x", Col.white, Col.black)
        #expect(row(s, 0) == "  ")
        #expect(row(s, 1) == "  ")
    }

    @Test func doubleAndSingleBox() {
        let s = Screen(cols: 4, rows: 3)
        s.box(0, 0, 4, 3, Col.white, Col.blue)
        #expect(row(s, 0) == "╔══╗")
        #expect(row(s, 1) == "║  ║")
        #expect(row(s, 2) == "╚══╝")
        s.box(0, 0, 4, 3, Col.white, Col.blue, double: false)
        #expect(row(s, 0) == "┌──┐")
        #expect(row(s, 2) == "└──┘")
    }

    @Test func clearResetsCellsAndCursor() {
        let s = Screen(cols: 3, rows: 1)
        s.text(0, 0, "abc", Col.white, Col.blue)
        s.cursor = (1, 0)
        s.clear()
        #expect(row(s, 0) == "   ")
        #expect(s[0, 0].bg == Col.black)
        #expect(s.cursor == nil)
    }

    @Test func keybarSplitsTheBottomRowIntoTenSlots() {
        let s = Screen(cols: 40, rows: 2)
        drawKeybar(s, ["Help", "Menu"])
        let r = row(s, 1)
        // 40 columns give 4 per slot: the number plus a 3-cell label, so "Help" is cut to "He}".
        #expect(r.hasPrefix("1He}2Me}3   "))
        // The last slot takes the remaining columns: "10" plus 2 empty label cells.
        #expect(r.hasSuffix("10  "))
        #expect(s[0, 1].bg == Col.black)
        #expect(s[1, 1].bg == Col.cyan)
    }
}

struct TextHelperTests {
    @Test func fitPadsAndAligns() {
        #expect(fit("ab", 5) == "ab   ")
        #expect(fit("ab", 5, .right) == "   ab")
        #expect(fit("ab", 5, .center) == " ab  ")
        #expect(fit("abc", 3) == "abc")
        #expect(fit("abc", 0) == "")
    }

    @Test func fitMarksTruncationWithABrace() {
        // Norton Commander style: a cut-off name ends in "}".
        #expect(fit("abcdef", 4) == "abc}")
    }

    @Test func fitTailKeepsTheEnd() {
        #expect(fitTail("abc", 5) == "abc")
        #expect(fitTail("abcdef", 4) == "…def")
        #expect(fitTail("abc", 0) == "")
    }

    // `arguments:` runs the test once per element, like a JUnit `@ParameterizedTest`.
    @Test(arguments: [
        ("hello world", 5, ["hello", "world"]),
        ("a b c", 3, ["a b", "c"]),
        ("abcdefgh", 3, ["abc", "def", "gh"]),
        ("one\ntwo", 10, ["one", "two"]),
        ("", 5, [""]),
    ])
    func wrapBreaksAtSpacesAndSplitsLongWords(text: String, width: Int, expected: [String]) {
        #expect(wrap(text, width) == expected)
    }

    @Test func displayPathAbbreviatesHome() {
        let home = NSHomeDirectory()
        #expect(displayPath(home) == "~")
        #expect(displayPath(home + "/Desktop") == "~/Desktop")
        #expect(displayPath("/usr/bin") == "/usr/bin")
        // Only whole path components match: "/Users/philipX" is not inside "/Users/philip".
        #expect(displayPath(home + "X") == home + "X")
    }

    @Test func relativePathStripsTheSearchRoot() {
        #expect(relativePath("/a/b/c", under: "/a") == "b/c")
        #expect(relativePath("/ab/c", under: "/a") == "/ab/c")
        #expect(relativePath("/x/y", under: "/a") == "/x/y")
        // Regression: searching from "/" used to show the full path because the prefix became "//".
        #expect(relativePath("/usr/bin/zsh", under: "/") == "usr/bin/zsh")
    }

    @Test func shortPathDropsMiddleFolders() {
        #expect(shortPath("/a/b", 10) == "/a/b")
        #expect(shortPath("~/Documents/project/scratchpad/sz", 25) == "~/…/project/scratchpad/sz")
        #expect(shortPath("~/Documents/project/scratchpad/sz", 20) == "~/…/scratchpad/sz")
        #expect(shortPath("/Volumes/Data/x/y/z", 14) == "/Volumes/…/y/z")
    }

    @Test func shortPathFallsBackToTheLastComponent() {
        #expect(shortPath("/a/b/verylongname", 15) == "…/verylongname")
        #expect(shortPath("/a/b/verylongname", 6) == "…gname")
        #expect(shortPath("/onlyonelongcomponent", 8) == "…mponent")
        #expect(shortPath("/a/b", 0) == "")
    }

    @Test func sizeStringSwitchesUnitsForLargeValues() {
        #expect(sizeString(0) == "0")
        #expect(sizeString(999_999_999) == "999999999")
        #expect(sizeString(1_000_000_000) == "\(1_000_000_000 / 1024)K")
        #expect(sizeString(200_000_000_000) == "\(200_000_000_000 >> 20)M")
    }

    @Test func groupNumUsesDotsAsThousandsSeparator() {
        #expect(groupNum(0) == "0")
        #expect(groupNum(1_234_567) == "1.234.567")
    }

    @Test func spacesIsEmptyForNonPositiveCounts() {
        #expect(spaces(3) == "   ")
        #expect(spaces(0) == "")
        #expect(spaces(-2) == "")
    }
}
