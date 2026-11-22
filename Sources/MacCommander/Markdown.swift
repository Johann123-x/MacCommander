import Foundation

// MARK: - Text-mode Markdown renderer (formatted view for F3/F4)

/// One rendered screen line plus the source line it came from (for keeping the scroll position).
struct MDLine {
    // `[Cell]` is an array of Cell (≈ `List<Cell>`, but a value type: assigning it copies, lazily on first write).
    var cells: [Cell]
    var src: Int
}

// Swift allows free functions at top level, no enclosing class needed.
/// True if the file extension marks a Markdown file; the viewer and editor then offer the formatted view.
func isMarkdownPath(_ path: String) -> Bool {
    // A single-expression body is returned implicitly. `as NSString` borrows Foundation's `pathExtension` helper.
    ["md", "markdown", "mdown", "mkd", "mkdn"].contains((path as NSString).pathExtension.lowercased())
}

// An enum without cases serves as a namespace for constants (≈ a final class with only static finals).
// `private` at file level means visible in this file only (same as `fileprivate`).
/// Colour scheme of the Markdown view, as DOS palette indices.
private enum MD {
    static let bg = Col.blue
    static let text = Col.lcyan
    static let bold = Col.white
    static let italic = Col.lgreen
    static let boldItalic = Col.yellow
    static let strike = Col.dgray
    static let link = Col.lgreen
    static let heading = Col.yellow
    static let rule = Col.cyan
    static let codeFg = Col.lgreen
    static let codeBg = Col.black
    static let quote = Col.gray
    static let mark = Col.yellow
}

// `_ bg: UInt8 = MD.bg` is a parameter with a default value (Java would need an overload).
/// Turns plain text into cells of one colour; a tab becomes a single space.
private func cells(_ s: String, _ fg: UInt8, _ bg: UInt8 = MD.bg) -> [Cell] {
    // `s.map { ... }` iterates over the string's Characters. The trailing `{ ... }` is a closure (lambda) and `$0` its
    // first parameter, so this is ≈ `s.chars().map(c -> new Cell(...))`.
    s.map { Cell(ch: $0 == "\t" ? " " : $0, fg: fg, bg: bg) }
}

// MARK: Inline formatting

/// Converts inline Markdown (**bold**, *italic*, `code`, [links](…), ~~strike~~) into coloured cells.
func mdInline(_ s: String, base: UInt8 = MD.text) -> [Cell] {
    // Swift strings cannot be indexed by Int: a Character may span several code units, so positions are opaque
    // `String.Index` values that must be walked step by step. `Array(s)` copies the characters into a `[Character]`
    // so the parser below can use `c[i]` and index arithmetic in O(1).
    let c = Array(s)
    var out: [Cell] = []
    // Current inline state while scanning left to right; the markers simply toggle it.
    var bold = false, italic = false, strike = false
    var i = 0

    // Nested functions may read and modify the enclosing locals (`out`, `bold`, ...), unlike Java lambdas, which only
    // see effectively final variables.
    // Colour of normal text in the current state: strike wins, then bold plus italic, bold, italic.
    func color() -> UInt8 {
        if strike { return MD.strike }
        if bold && italic { return MD.boldItalic }
        if bold { return MD.bold }
        if italic { return MD.italic }
        return base
    }
    // `fg: UInt8? = nil` is an optional parameter defaulting to nil; `fg ?? color()` then uses the current state colour.
    func emit(_ ch: Character, _ fg: UInt8? = nil, _ bg: UInt8 = MD.bg) {
        out.append(Cell(ch: ch, fg: fg ?? color(), bg: bg))
    }
    /// Index of the next occurrence of `needle` at or after `from`, or nil if there is none.
    func find(_ needle: [Character], from: Int) -> Int? {
        // Bail out if the needle cannot fit into the remaining characters (this also keeps the range below valid).
        guard !needle.isEmpty, from <= c.count - needle.count else { return nil }
        // `for ... where cond` skips iterations that fail the condition. `c[a..<b]` is a slice (a view on a subrange);
        // `Array(...)` turns it into an array so `==` can compare it element by element.
        for k in from...(c.count - needle.count) where Array(c[k..<(k + needle.count)]) == needle { return k }
        return nil
    }
    // Positions outside the text count as non-word characters.
    func isWordChar(_ k: Int) -> Bool { k >= 0 && k < c.count && (c[k].isLetter || c[k].isNumber) }

    // Each rule below either consumes some characters and `continue`s, or falls through to the next rule.
    // Whatever no rule matches is emitted literally at the end of the loop body.
    while i < c.count {
        let ch = c[i]
        // Backslash escapes
        // A backslash before a punctuation character emits that character literally.
        if ch == "\\", i + 1 < c.count, "\\`*_{}[]()#+-.!|~<>".contains(c[i + 1]) {
            emit(c[i + 1]); i += 2; continue
        }
        // Inline code
        // A run of n backticks opens code that ends at the next run of n backticks; one leading and one trailing space
        // are stripped (as in CommonMark). Code is shown black on cyan. Unmatched backticks fall through and print literally.
        if ch == "`" {
            var n = 0
            while i + n < c.count && c[i + n] == "`" { n += 1 }
            if let end = find(Array(repeating: "`", count: n), from: i + n) {
                var code = String(c[(i + n)..<end])
                if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 1 { code = String(code.dropFirst().dropLast()) }
                for x in code { emit(x, Col.black, Col.cyan) }
                i = end + n; continue
            }
        }
        // Images and links
        // `[label](url)` shows only the label, in link colour; `![alt](url)` shows a placeholder with the alt text. The URL
        // itself is never shown. Nested brackets or parentheses inside the label or URL are not supported.
        if ch == "!" || ch == "[" {
            let isImg = ch == "!"
            let open = isImg ? i + 1 : i
            // Every `let x = find(...)` clause must yield a non-nil value, otherwise the whole `if` is skipped; later clauses
            // may use earlier bindings.
            if open < c.count, c[open] == "[", let close = find(["]"], from: open + 1),
               close + 1 < c.count, c[close + 1] == "(", let paren = find([")"], from: close + 2) {
                let label = String(c[(open + 1)..<close])
                if isImg {
                    out += cells("[Image: " + (label.isEmpty ? "–" : label) + "]", Col.cyan)
                } else {
                    // Labels may contain inline formatting themselves (recursive call); plain text is recoloured to the link colour.
                    // `var x = $0` makes a mutable copy of the Cell struct inside the closure, which is then returned.
                    out += mdInline(label, base: MD.link).map { var x = $0; if x.fg == MD.text { x.fg = MD.link }; return x }
                }
                i = paren + 1; continue
            }
        }
        // Autolinks <https://…>
        if ch == "<", let end = find([">"], from: i + 1) {
            let inner = String(c[(i + 1)..<end])
            if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                out += cells(inner, MD.link); i = end + 1; continue
            }
        }
        // Strikethrough
        if ch == "~", i + 1 < c.count, c[i + 1] == "~" {
            // `toggle()` flips a Bool in place.
            strike.toggle(); i += 2; continue
        }
        // Bold / italic with * or _
        if ch == "*" || ch == "_" {
            var n = 0
            while i + n < c.count && c[i + n] == ch { n += 1 }
            // A marker run with spaces on both sides is not emphasis (e.g. "a * b").
            let prevSpace = i == 0 || c[i - 1] == " "
            let nextSpace = i + n >= c.count || c[i + n] == " "
            // "_" inside words (snake_case) and lone "*" surrounded by spaces stay literal
            let intraword = ch == "_" && isWordChar(i - 1) && isWordChar(i + n)
            if !intraword && !(prevSpace && nextSpace) {
                // The run length decides: *** toggles bold and italic, ** bold, * italic. Opening and closing markers are not
                // told apart, emphasis is just switched on and off. The state does not carry over to the next `mdInline` call.
                if n >= 3 { bold.toggle(); italic.toggle() }
                else if n == 2 { bold.toggle() }
                else { italic.toggle() }
                i += n; continue
            }
            // Not emphasis: print the run literally. `_` is a placeholder for an unused loop variable.
            for _ in 0..<n { emit(ch) }
            i += n; continue
        }
        emit(ch)
        i += 1
    }
    return out
}

// MARK: Wrapping

/// Greedy word wrap of coloured cells; continuation lines get `rest` as prefix.
private func wrapCells(_ line: [Cell], width: Int, first: [Cell] = [], rest: [Cell] = []) -> [[Cell]] {
    // Returns one cell array per output line (`[[Cell]]` = list of lists). `first` prefixes the first line (e.g. a
    // list bullet), `rest` every further line (e.g. matching indentation).
    var out: [[Cell]] = []
    var cur = first
    var limit = max(1, width)
    var words: [[Cell]] = []
    var w: [Cell] = []
    // Split into words at spaces; runs of spaces collapse into one.
    for x in line {
        if x.ch == " " { if !w.isEmpty { words.append(w); w = [] } } else { w.append(x) }
    }
    if !w.isEmpty { words.append(w) }
    // Input without words still yields one line holding just the prefix.
    if words.isEmpty { return [cur] }
    var hasWord = false
    // `for var` makes the loop variable mutable, as overlong words are cut down below.
    for var word in words {
        let sep = hasWord ? 1 : 0
        if cur.count + sep + word.count <= limit {
            // The joining space takes the colours of the next word, but not the cyan background of inline code, so a code
            // span does not visually extend into the gap.
            if hasWord { cur.append(Cell(ch: " ", fg: word[0].fg, bg: word[0].bg == Col.cyan ? MD.bg : word[0].bg)) }
            cur += word; hasWord = true
            continue
        }
        // The word does not fit: finish the current line and continue on a new one.
        if hasWord { out.append(cur); cur = rest; hasWord = false }
        // Words longer than a whole line get broken hard
        while cur.count + word.count > limit, limit - cur.count > 0 {
            let take = limit - cur.count
            cur += word.prefix(take)
            word.removeFirst(take)
            out.append(cur); cur = rest
        }
        // Safety net: if the prefix alone fills the width, raise the limit so at least one more character fits.
        // Note that the raised limit then applies to all following lines as well.
        if limit - cur.count <= 0 { limit = cur.count + 1 }
        cur += word; hasWord = true
    }
    out.append(cur)
    return out
}

// MARK: Block rendering

/// True for a table delimiter row such as `|---|:--:|`, which makes the line above it the table header.
private func isTableSep(_ s: String) -> Bool {
    // `.whitespaces` is short for `CharacterSet.whitespaces` (spaces and tabs, no newlines).
    let t = s.trimmingCharacters(in: .whitespaces)
    guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
    // `allSatisfy` ≈ `stream().allMatch(...)`.
    return t.allSatisfy { "|-: ".contains($0) }
}

/// Splits a table row into trimmed cell texts at unescaped `|`; the outer pipes are optional.
private func tableCells(_ s: String) -> [String] {
    var t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
    // Three variables in one statement; `[String]` is an array of String.
    var res: [String] = [], cur = "", esc = false
    for ch in t {
        // After a backslash the next character (e.g. `|`) stays in the cell; the backslash is kept and later consumed by
        // the escape rule in `mdInline`.
        if esc { cur.append(ch); esc = false; continue }
        if ch == "\\" { esc = true; cur.append(ch); continue }
        if ch == "|" { res.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
    }
    res.append(cur.trimmingCharacters(in: .whitespaces))
    return res
}

// The return type `(Int, String)?` is an optional tuple: either nil or a pair of values.
/// Parses an ATX heading (`# Title` to `###### Title`) into level and title, or nil. Closing `#`s are removed.
private func headingLevel(_ s: String) -> (Int, String)? {
    var n = 0
    for ch in s { if ch == "#" { n += 1 } else { break } }
    guard n >= 1, n <= 6 else { return nil }
    // `dropFirst(n)` returns a `Substring`, a view sharing the original string's storage, without copying.
    let rest = s.dropFirst(n)
    // The `#`s must be followed by a space or the end of line, so `#hashtag` is not a heading.
    guard rest.isEmpty || rest.first == " " else { return nil }
    var title = rest.trimmingCharacters(in: .whitespaces)
    while title.hasSuffix("#") { title.removeLast() }
    return (n, title.trimmingCharacters(in: .whitespaces))
}

// The tuple has named elements, so callers can write `item.indent`, `item.marker`, `item.text`.
/// Recognises a list item: `-`, `*` or `+` (rendered with the marker "•") or `1.` / `1)`, each followed by a space.
/// Returns indentation, marker and item text, or nil.
private func listItem(_ s: String) -> (indent: Int, marker: String, text: String)? {
    // `prefix { cond }` takes leading characters while the closure returns true (≈ `takeWhile`).
    let indent = s.prefix { $0 == " " }.count
    let t = s.dropFirst(indent)
    // Comparing an optional with a plain value is allowed: `t.dropFirst().first == " "` is false when there is none.
    if let f = t.first, "-*+".contains(f), t.dropFirst().first == " " {
        return (indent, "•", String(t.dropFirst(2)))
    }
    let digits = t.prefix { $0.isNumber }
    // CommonMark limits ordered list numbers to nine digits.
    if !digits.isEmpty, digits.count < 10 {
        let after = t.dropFirst(digits.count)
        if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
            return (indent, String(digits) + ".", String(after.dropFirst(2)))
        }
    }
    return nil
}

/// True for a thematic break: at least three of the same `-`, `*` or `_`, with optional spaces in between.
private func isRule(_ s: String) -> Bool {
    let t = s.replacingOccurrences(of: " ", with: "")
    guard t.count >= 3, let f = t.first, "-*_".contains(f) else { return false }
    return t.allSatisfy { $0 == f }
}

/// Renders a Markdown document into wrapped, coloured lines of the given width.
func renderMarkdown(_ text: String, width: Int) -> [MDLine] {
    // Line-based block parser: each loop iteration recognises one block (code, heading, rule, table, quote, list item
    // or paragraph) starting at `src[i]`, renders it and advances `i` past the source lines it consumed. Every output
    // line records its source line index so the viewer can keep the scroll position when switching modes.
    // `W` is the render width, at least 20 columns.
    let W = max(20, width)
    // Normalise Windows line endings, then split into lines.
    let src = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var out: [MDLine] = []
    var i = 0

    // Appends one output line, tagged with source line `s`.
    func add(_ c: [Cell], _ s: Int) { out.append(MDLine(cells: c, src: s)) }
    // Appends an empty separator line, but never two in a row and never at the start.
    func blank(_ s: Int) { if let l = out.last, !l.cells.isEmpty { add([], s) } }

    while i < src.count {
        let raw = src[i]
        // `raw` keeps the indentation (needed for code blocks and nested lists), `line` is trimmed.
        let line = raw.trimmingCharacters(in: .whitespaces)

        if line.isEmpty { blank(i); i += 1; continue }

        // Fenced code block
        if line.hasPrefix("```") || line.hasPrefix("~~~") {
            // The block ends at a line starting with the same three fence characters. A language name after the opening
            // fence is shown in the top border.
            let fence = String(line.prefix(3))
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            blank(i)
            var top = cells(" " + String(repeating: "─", count: W - 2) + " ", Col.cyan, MD.codeBg)
            if !lang.isEmpty {
                // String interpolation: `"\(lang)"` inserts the value (≈ `" " + lang + " "`).
                let l = Array(cells(" \(lang) ", Col.yellow, MD.codeBg))
                // `enumerated()` yields (index, element) tuples, destructured in the `for`; the label overwrites the border from
                // column 2 onwards.
                for (k, x) in l.enumerated() where 2 + k < top.count { top[2 + k] = x }
            }
            add(top, i)
            i += 1
            while i < src.count && !src[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                var body = src[i].replacingOccurrences(of: "\t", with: "    ")
                // `repeat { } while` is Java's `do { } while`. Long code lines are hard-wrapped into chunks of W-2 columns and padded
                // to the full width, so the black background forms a solid box.
                repeat {
                    let chunk = String(body.prefix(W - 2))
                    body = String(body.dropFirst(W - 2))
                    let row = cells("  " + chunk, MD.codeFg, MD.codeBg)
                    add(row + cells(spaces(max(0, W - row.count)), MD.codeFg, MD.codeBg), i)
                } while !body.isEmpty
                i += 1
            }
            // Bottom border; `min` keeps the source index valid when the closing fence is missing at the end of the file.
            add(cells(" " + String(repeating: "─", count: W - 2) + " ", Col.cyan, MD.codeBg), min(i, src.count - 1))
            // Skip the closing fence line.
            i += 1
            add([], i - 1)
            continue
        }

        // Indented code block (4 spaces / tab) – only when not continuing a list
        // `out.last` is optional; `.map { ... }` applies the closure only to a present value and `?? true` covers the empty
        // case. So indented code is only recognised at the start or right after an empty line.
        if (raw.hasPrefix("    ") || raw.hasPrefix("\t")), out.last.map({ $0.cells.isEmpty }) ?? true {
            let body = raw.hasPrefix("\t") ? String(raw.dropFirst()) : String(raw.dropFirst(4))
            let row = cells("  " + String(body.prefix(W - 2)), MD.codeFg, MD.codeBg)
            add(row + cells(spaces(max(0, W - row.count)), MD.codeFg, MD.codeBg), i)
            i += 1
            // Close the block with an empty line once the next line is no longer indented.
            if i >= src.count || !(src[i].hasPrefix("    ") || src[i].hasPrefix("\t")) { add([], i - 1) }
            continue
        }

        // Headings (ATX and setext)
        // Setext headings are text underlined on the next line with `===` (level 1) or `---` (level 2); `consumed` counts
        // the source lines the heading takes. The explicit type is needed because `heading` is reassigned below.
        var heading: (Int, String)? = headingLevel(line)
        var consumed = 1
        if heading == nil, i + 1 < src.count {
            let next = src[i + 1].trimmingCharacters(in: .whitespaces)
            if !next.isEmpty, next.allSatisfy({ $0 == "=" }) { heading = (1, line); consumed = 2 }
            // A `---` underline below a list item is not a setext heading.
            else if next.count >= 2, next.allSatisfy({ $0 == "-" }), listItem(raw) == nil { heading = (2, line); consumed = 2 }
        }
        // `if let (lvl, title) = heading` unwraps the optional and destructures the tuple in one step.
        if let (lvl, title) = heading {
            blank(i)
            // Levels 1 to 3 in yellow, 4 to 6 in white. Level 1 is upper-cased and underlined with ═, level 2 with ─.
            let fg: UInt8 = lvl <= 3 ? MD.heading : Col.white
            var t = mdInline(lvl == 1 ? title.uppercased() : title, base: fg)
            // `t.indices` is the range of valid indices. Plain text gets the heading colour, other inline colours are kept.
            for k in t.indices where t[k].fg == fg || t[k].fg == MD.text { t[k].fg = fg }
            for row in wrapCells(t, width: W) { add(row, i) }
            if lvl <= 2 {
                let len = min(W, max(t.count, 1))
                add(cells(String(repeating: lvl == 1 ? "═" : "─", count: len), MD.heading), i)
            }
            add([], i)
            i += consumed
            continue
        }

        // Horizontal rule
        if isRule(line) {
            blank(i)
            add(cells(String(repeating: "─", count: W), MD.rule), i)
            add([], i)
            i += 1; continue
        }

        // Tables
        if line.contains("|"), i + 1 < src.count, isTableSep(src[i + 1]) {
            // A table starts at a line containing `|` that is followed by a delimiter row. Colons in the delimiter row set the
            // column alignment: `:--` left, `--:` right, `:-:` centre.
            let start = i
            let header = tableCells(line)
            // `{ a in ... }` is a closure with a named parameter (≈ `a -> { ... }`). `.center` resolves against the declared
            // element type `Align`.
            let aligns: [Align] = tableCells(src[i + 1]).map { a in
                let l = a.hasPrefix(":"), r = a.hasSuffix(":")
                return l && r ? .center : (r ? .right : .left)
            }
            var rows: [[String]] = []
            i += 2
            // Body rows: the following non-blank lines that contain `|`.
            while i < src.count, src[i].contains("|"), !src[i].trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(tableCells(src[i])); i += 1
            }
            // `\.count` is a key path used as a function (≈ `List::size`). `max()` returns an optional (nil for an empty
            // array), hence `?? 0`. `n` is the column count of the widest row.
            let n = max(header.count, rows.map(\.count).max() ?? 0)
            let all = [header] + rows
            // Render every cell with inline formatting; missing cells of short rows become empty.
            let rendered = all.map { r in (0..<n).map { k in k < r.count ? mdInline(r[k]) : [] } }
            // Column width = widest rendered cell, at least 1.
            var widths = (0..<n).map { k in rendered.map { $0[k].count }.max() ?? 0 }.map { max(1, $0) }
            // Space left for content: each column needs two padding spaces and one border character, plus the leading border.
            let avail = W - (3 * n + 1)
            // While too wide, narrow the currently widest column by one, but not below 3. `reduce(0, +)` sums the array,
            // passing the `+` operator as the combining function.
            while widths.reduce(0, +) > avail, let m = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[m] > 3 {
                widths[m] -= 1
            }
            /// Builds a horizontal table border from the given left, middle and right box-drawing characters.
            func border(_ l: String, _ mid: String, _ r: String) -> [Cell] {
                var s = l
                for k in 0..<n { s += String(repeating: "─", count: widths[k] + 2) + (k == n - 1 ? r : mid) }
                return cells(s, Col.cyan)
            }
            blank(start)
            add(border("┌", "┬", "┐"), start)
            for (ri, r) in rendered.enumerated() {
                var row = cells("│", Col.cyan)
                for k in 0..<n {
                    var c = r[k]
                    // Header row: plain text in heading colour.
                    if ri == 0 { c = c.map { var x = $0; if x.fg == MD.text { x.fg = MD.heading }; return x } }
                    // A cell too wide for its column is cut and marked with a cyan `}`.
                    if c.count > widths[k] { c = Array(c.prefix(widths[k] - 1)) + cells("}", Col.cyan) }
                    let pad = widths[k] - c.count
                    let a = k < aligns.count ? aligns[k] : .left
                    // Left padding according to the alignment; the rest of the padding goes to the right.
                    let lp = a == .right ? pad : (a == .center ? pad / 2 : 0)
                    row += cells(" " + spaces(lp), MD.text) + c + cells(spaces(pad - lp) + " ", MD.text) + cells("│", Col.cyan)
                }
                // Source line of row `ri`: the header is at `start`, the delimiter row at `start + 1`, body rows from `start + 2`.
                add(row, ri == 0 ? start : start + 1 + ri)
                if ri == 0 { add(border("├", "┼", "┤"), start + 1) }
            }
            add(border("└", "┴", "┘"), i - 1)
            add([], i - 1)
            continue
        }

        // Block quotes
        // Count the nested `>` markers and draw one cyan bar per level in front of every wrapped line.
        if line.hasPrefix(">") {
            var depth = 0
            // `Substring(line)` works on a view of the line, so the `dropFirst` calls below do not copy.
            var t = Substring(line)
            // `drop { cond }` removes leading characters while the closure returns true (≈ `dropWhile`).
            while t.hasPrefix(">") { depth += 1; t = t.dropFirst(); t = t.drop { $0 == " " } }
            let prefix = cells(String(repeating: "│ ", count: depth), Col.cyan)
            if t.isEmpty { add(prefix, i) }
            else { for row in wrapCells(mdInline(String(t), base: MD.quote), width: W, first: prefix, rest: prefix) { add(row, i) } }
            i += 1; continue
        }

        // List items (with task-list checkboxes)
        if let item = listItem(raw) {
            // Nesting level from the indentation, two spaces per level. Bullets alternate •, ◦, ▪ by level; numbered items keep
            // their number.
            let lvl = item.indent / 2
            var text = item.text
            var marker = item.marker == "•" ? (["•", "◦", "▪"][lvl % 3]) : item.marker
            // Task list checkboxes `[ ]` / `[x]` replace the marker.
            if text.hasPrefix("[ ] ") { marker = "[ ]"; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "[x]"; text = String(text.dropFirst(4)) }
            // Lazy continuation lines belong to the item
            var j = i + 1
            while j < src.count {
                let nx = src[j]
                let tn = nx.trimmingCharacters(in: .whitespaces)
                if tn.isEmpty || listItem(nx) != nil || headingLevel(tn) != nil || tn.hasPrefix(">") || tn.hasPrefix("```") || isRule(tn) { break }
                text += " " + tn; j += 1
            }
            // Continuation lines are indented to align with the text after the marker.
            let ind = spaces(2 + lvl * 3)
            let first = cells(ind, MD.text) + cells(marker, MD.mark) + cells(" ", MD.text)
            let rest = cells(spaces(first.count), MD.text)
            for row in wrapCells(mdInline(text), width: W, first: first, rest: rest) { add(row, i) }
            i = j
            // An empty line between two items of the same kind (both bulleted or both numbered) is skipped.
            if i < src.count, src[i].trimmingCharacters(in: .whitespaces).isEmpty,
               i + 1 < src.count, let nx = listItem(src[i + 1]),
               (nx.marker == "•") == (item.marker == "•") { i += 1 } // keep loose lists compact
            continue
        }

        // Paragraph: join soft-wrapped lines, honour hard breaks (two spaces or backslash)
        // Collects lines until an empty line or the start of another block. A line followed by a setext underline also
        // ends the paragraph, so it becomes a heading in the next iteration.
        let start = i
        var para: [Cell] = []
        while i < src.count {
            let r = src[i]
            let t = r.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || (i > start && (headingLevel(t) != nil || listItem(r) != nil || t.hasPrefix(">")
                || t.hasPrefix("```") || t.hasPrefix("~~~") || isRule(t)
                || (t.contains("|") && i + 1 < src.count && isTableSep(src[i + 1])))) { break }
            if i + 1 < src.count, !t.isEmpty {
                let nt = src[i + 1].trimmingCharacters(in: .whitespaces)
                if !nt.isEmpty && (nt.allSatisfy { $0 == "=" } || (nt.count >= 2 && nt.allSatisfy { $0 == "-" })) && i > start { break }
            }
            // A hard break flushes the text collected so far as its own wrapped block.
            let hard = r.hasSuffix("  ") || t.hasSuffix("\\")
            let body = t.hasSuffix("\\") ? String(t.dropLast()) : t
            if !para.isEmpty { para += cells(" ", MD.text) }
            para += mdInline(body)
            i += 1
            if hard {
                for row in wrapCells(para, width: W) { add(row, start) }
                para = []
            }
        }
        if !para.isEmpty { for row in wrapCells(para, width: W) { add(row, start) } }
        // Separator after the paragraph, tagged with its last source line.
        add([], max(start, i - 1))
    }
    // `while let` loops as long as the optional binding succeeds; this strips trailing empty lines.
    while let l = out.last, l.cells.isEmpty { out.removeLast() }
    return out
}
