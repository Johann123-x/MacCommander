import Testing
@testable import MacCommander

struct MarkdownInlineTests {
    /// The characters of rendered cells as a string.
    private func text(_ cells: [Cell]) -> String { String(cells.map(\.ch)) }

    /// The foreground colour of the first cell showing `ch`.
    private func fg(_ cells: [Cell], _ ch: Character) -> UInt8? { cells.first { $0.ch == ch }?.fg }

    @Test func plainTextUsesTheBaseColour() {
        let c = mdInline("plain")
        #expect(text(c) == "plain")
        #expect(c.allSatisfy { $0.fg == Col.lcyan && $0.bg == Col.blue })
    }

    @Test func emphasisMarkersAreRemovedAndColoured() {
        let c = mdInline("a **b** *c* ***d*** ~~e~~")
        #expect(text(c) == "a b c d e")
        #expect(fg(c, "a") == Col.lcyan)
        #expect(fg(c, "b") == Col.white)
        #expect(fg(c, "c") == Col.lgreen)
        #expect(fg(c, "d") == Col.yellow)
        #expect(fg(c, "e") == Col.dgray)
    }

    @Test func underscoresInsideWordsAndLoneStarsStayLiteral() {
        #expect(text(mdInline("snake_case_name")) == "snake_case_name")
        #expect(text(mdInline("2 * 3")) == "2 * 3")
        #expect(text(mdInline("_it_")) == "it")
    }

    @Test func inlineCodeIsVerbatimAndHighlighted() {
        let c = mdInline("x `a*b*c` y")
        #expect(text(c) == "x a*b*c y")
        #expect(c[2].fg == Col.black)
        #expect(c[2].bg == Col.cyan)
        // Double backticks allow a backtick inside; one space on each side is stripped.
        #expect(text(mdInline("`` a`b ``")) == "a`b")
    }

    @Test func backslashEscapesMarkdownCharacters() {
        #expect(text(mdInline("\\*not\\* \\_em\\_")) == "*not* _em_")
    }

    @Test func linksShowTheirLabelAndAutolinksTheirTarget() {
        let c = mdInline("see [the docs](http://example.com) now")
        #expect(text(c) == "see the docs now")
        #expect(fg(c, "t") == Col.lgreen)
        #expect(text(mdInline("<https://example.com>")) == "https://example.com")
        // Only URLs are autolinks; other angle brackets stay as they are.
        #expect(text(mdInline("a <b> c")) == "a <b> c")
    }

    @Test(arguments: ["a.md", "A.MD", "notes.markdown", "x.mkd"])
    func markdownExtensions(path: String) {
        #expect(isMarkdownPath(path))
    }

    @Test(arguments: ["a.txt", "md", "a.md.bak"])
    func nonMarkdownExtensions(path: String) {
        #expect(!isMarkdownPath(path))
    }
}

struct MarkdownBlockTests {
    /// Renders `md` and returns the display lines as strings.
    private func render(_ md: String, width: Int = 20) -> [String] {
        renderMarkdown(md, width: width).map { String($0.cells.map(\.ch)) }
    }

    @Test func atxAndSetextHeadings() {
        // Level 1 is upper-cased and double-underlined, level 2 single-underlined.
        #expect(render("# Title") == ["TITLE", "═════"])
        #expect(render("Title\n=====") == ["TITLE", "═════"])
        #expect(render("## Sub ##") == ["Sub", "───"])
        #expect(render("Sub\n---") == ["Sub", "───"])
        #expect(render("### Third") == ["Third"])
        // Without the space it is not a heading.
        #expect(render("#tag") == ["#tag"])
    }

    @Test func paragraphsJoinLinesAndWrap() {
        #expect(render("one two three\nfour five six") == ["one two three four", "five six"])
        #expect(render("first\n\nsecond") == ["first", "", "second"])
    }

    @Test func hardLineBreaks() {
        #expect(render("one  \ntwo") == ["one", "two"])
        #expect(render("one\\\ntwo") == ["one", "two"])
    }

    @Test func listsGetMarkersAndIndentation() {
        #expect(render("- a\n- b") == ["  • a", "  • b"])
        #expect(render("- a\n  - b") == ["  • a", "     ◦ b"])
        #expect(render("1. x\n2) y") == ["  1. x", "  2. y"])
        #expect(render("- [ ] open\n- [X] done") == ["  [ ] open", "  [x] done"])
        // A continuation line is appended to the item.
        #expect(render("- a\n  b") == ["  • a b"])
    }

    @Test func blockquoteAndRule() {
        #expect(render("> quoted") == ["│ quoted"])
        #expect(render(">> deep") == ["│ │ deep"])
        #expect(render("***") == [String(repeating: "─", count: 20)])
    }

    @Test func fencedCodeBlock() {
        let lines = render("```swift\nlet x = 1\n```")
        #expect(lines.count == 3)
        #expect(lines[0] == " ─ swift ────────── ")
        #expect(lines[1] == "  let x = 1" + String(repeating: " ", count: 9))
        #expect(lines[2] == " " + String(repeating: "─", count: 18) + " ")
    }

    @Test func tableWithAlignment() {
        let lines = render("| a | b |\n|---|--:|\n| 1 | 22 |")
        #expect(lines == [
            "┌───┬────┐",
            "│ a │  b │",
            "├───┼────┤",
            "│ 1 │ 22 │",
            "└───┴────┘",
        ])
    }

    @Test func lineMappingPointsBackToTheSource() {
        // The editor uses `src` to put the cursor on the right source line in formatted view.
        // The blank line after a paragraph belongs to the paragraph's last source line.
        let lines = renderMarkdown("first\n\nsecond", width: 20)
        #expect(lines.map(\.src) == [0, 0, 2])
    }

    @Test func emptyInputRendersNothing() {
        #expect(render("").isEmpty)
        #expect(render("\n\n").isEmpty)
    }
}
