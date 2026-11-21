import Foundation

// MARK: - Text-mode Markdown renderer (formatted view for F3/F4)

/// One rendered screen line plus the source line it came from (for keeping the scroll position).
struct MDLine {
    var cells: [Cell]
    var src: Int
}

func isMarkdownPath(_ path: String) -> Bool {
    ["md", "markdown", "mdown", "mkd", "mkdn"].contains((path as NSString).pathExtension.lowercased())
}

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

private func cells(_ s: String, _ fg: UInt8, _ bg: UInt8 = MD.bg) -> [Cell] {
    s.map { Cell(ch: $0 == "\t" ? " " : $0, fg: fg, bg: bg) }
}

// MARK: Inline formatting

/// Converts inline Markdown (**bold**, *italic*, `code`, [links](…), ~~strike~~) into coloured cells.
func mdInline(_ s: String, base: UInt8 = MD.text) -> [Cell] {
    let c = Array(s)
    var out: [Cell] = []
    var bold = false, italic = false, strike = false
    var i = 0

    func color() -> UInt8 {
        if strike { return MD.strike }
        if bold && italic { return MD.boldItalic }
        if bold { return MD.bold }
        if italic { return MD.italic }
        return base
    }
    func emit(_ ch: Character, _ fg: UInt8? = nil, _ bg: UInt8 = MD.bg) {
        out.append(Cell(ch: ch, fg: fg ?? color(), bg: bg))
    }
    func find(_ needle: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, from <= c.count - needle.count else { return nil }
        for k in from...(c.count - needle.count) where Array(c[k..<(k + needle.count)]) == needle { return k }
        return nil
    }
    func isWordChar(_ k: Int) -> Bool { k >= 0 && k < c.count && (c[k].isLetter || c[k].isNumber) }

    while i < c.count {
        let ch = c[i]
        // Backslash escapes
        if ch == "\\", i + 1 < c.count, "\\`*_{}[]()#+-.!|~<>".contains(c[i + 1]) {
            emit(c[i + 1]); i += 2; continue
        }
        // Inline code
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
        if ch == "!" || ch == "[" {
            let isImg = ch == "!"
            let open = isImg ? i + 1 : i
            if open < c.count, c[open] == "[", let close = find(["]"], from: open + 1),
               close + 1 < c.count, c[close + 1] == "(", let paren = find([")"], from: close + 2) {
                let label = String(c[(open + 1)..<close])
                if isImg {
                    out += cells("[Bild: " + (label.isEmpty ? "–" : label) + "]", Col.cyan)
                } else {
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
            strike.toggle(); i += 2; continue
        }
        // Bold / italic with * or _
        if ch == "*" || ch == "_" {
            var n = 0
            while i + n < c.count && c[i + n] == ch { n += 1 }
            let prevSpace = i == 0 || c[i - 1] == " "
            let nextSpace = i + n >= c.count || c[i + n] == " "
            // "_" inside words (snake_case) and lone "*" surrounded by spaces stay literal
            let intraword = ch == "_" && isWordChar(i - 1) && isWordChar(i + n)
            if !intraword && !(prevSpace && nextSpace) {
                if n >= 3 { bold.toggle(); italic.toggle() }
                else if n == 2 { bold.toggle() }
                else { italic.toggle() }
                i += n; continue
            }
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
    var out: [[Cell]] = []
    var cur = first
    var limit = max(1, width)
    var words: [[Cell]] = []
    var w: [Cell] = []
    for x in line {
        if x.ch == " " { if !w.isEmpty { words.append(w); w = [] } } else { w.append(x) }
    }
    if !w.isEmpty { words.append(w) }
    if words.isEmpty { return [cur] }
    var hasWord = false
    for var word in words {
        let sep = hasWord ? 1 : 0
        if cur.count + sep + word.count <= limit {
            if hasWord { cur.append(Cell(ch: " ", fg: word[0].fg, bg: word[0].bg == Col.cyan ? MD.bg : word[0].bg)) }
            cur += word; hasWord = true
            continue
        }
        if hasWord { out.append(cur); cur = rest; hasWord = false }
        // Words longer than a whole line get broken hard
        while cur.count + word.count > limit, limit - cur.count > 0 {
            let take = limit - cur.count
            cur += word.prefix(take)
            word.removeFirst(take)
            out.append(cur); cur = rest
        }
        if limit - cur.count <= 0 { limit = cur.count + 1 }
        cur += word; hasWord = true
    }
    out.append(cur)
    return out
}

// MARK: Block rendering

private func isTableSep(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
    return t.allSatisfy { "|-: ".contains($0) }
}

private func tableCells(_ s: String) -> [String] {
    var t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
    var res: [String] = [], cur = "", esc = false
    for ch in t {
        if esc { cur.append(ch); esc = false; continue }
        if ch == "\\" { esc = true; cur.append(ch); continue }
        if ch == "|" { res.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
    }
    res.append(cur.trimmingCharacters(in: .whitespaces))
    return res
}

private func headingLevel(_ s: String) -> (Int, String)? {
    var n = 0
    for ch in s { if ch == "#" { n += 1 } else { break } }
    guard n >= 1, n <= 6 else { return nil }
    let rest = s.dropFirst(n)
    guard rest.isEmpty || rest.first == " " else { return nil }
    var title = rest.trimmingCharacters(in: .whitespaces)
    while title.hasSuffix("#") { title.removeLast() }
    return (n, title.trimmingCharacters(in: .whitespaces))
}

private func listItem(_ s: String) -> (indent: Int, marker: String, text: String)? {
    let indent = s.prefix { $0 == " " }.count
    let t = s.dropFirst(indent)
    if let f = t.first, "-*+".contains(f), t.dropFirst().first == " " {
        return (indent, "•", String(t.dropFirst(2)))
    }
    let digits = t.prefix { $0.isNumber }
    if !digits.isEmpty, digits.count < 10 {
        let after = t.dropFirst(digits.count)
        if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
            return (indent, String(digits) + ".", String(after.dropFirst(2)))
        }
    }
    return nil
}

private func isRule(_ s: String) -> Bool {
    let t = s.replacingOccurrences(of: " ", with: "")
    guard t.count >= 3, let f = t.first, "-*_".contains(f) else { return false }
    return t.allSatisfy { $0 == f }
}

/// Renders a Markdown document into wrapped, coloured lines of the given width.
func renderMarkdown(_ text: String, width: Int) -> [MDLine] {
    let W = max(20, width)
    let src = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var out: [MDLine] = []
    var i = 0

    func add(_ c: [Cell], _ s: Int) { out.append(MDLine(cells: c, src: s)) }
    func blank(_ s: Int) { if let l = out.last, !l.cells.isEmpty { add([], s) } }

    while i < src.count {
        let raw = src[i]
        let line = raw.trimmingCharacters(in: .whitespaces)

        if line.isEmpty { blank(i); i += 1; continue }

        // Fenced code block
        if line.hasPrefix("```") || line.hasPrefix("~~~") {
            let fence = String(line.prefix(3))
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            blank(i)
            var top = cells(" " + String(repeating: "─", count: W - 2) + " ", Col.cyan, MD.codeBg)
            if !lang.isEmpty {
                let l = Array(cells(" \(lang) ", Col.yellow, MD.codeBg))
                for (k, x) in l.enumerated() where 2 + k < top.count { top[2 + k] = x }
            }
            add(top, i)
            i += 1
            while i < src.count && !src[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                var body = src[i].replacingOccurrences(of: "\t", with: "    ")
                repeat {
                    let chunk = String(body.prefix(W - 2))
                    body = String(body.dropFirst(W - 2))
                    let row = cells("  " + chunk, MD.codeFg, MD.codeBg)
                    add(row + cells(spaces(max(0, W - row.count)), MD.codeFg, MD.codeBg), i)
                } while !body.isEmpty
                i += 1
            }
            add(cells(" " + String(repeating: "─", count: W - 2) + " ", Col.cyan, MD.codeBg), min(i, src.count - 1))
            i += 1
            add([], i - 1)
            continue
        }

        // Indented code block (4 spaces / tab) – only when not continuing a list
        if (raw.hasPrefix("    ") || raw.hasPrefix("\t")), out.last.map({ $0.cells.isEmpty }) ?? true {
            let body = raw.hasPrefix("\t") ? String(raw.dropFirst()) : String(raw.dropFirst(4))
            let row = cells("  " + String(body.prefix(W - 2)), MD.codeFg, MD.codeBg)
            add(row + cells(spaces(max(0, W - row.count)), MD.codeFg, MD.codeBg), i)
            i += 1
            if i >= src.count || !(src[i].hasPrefix("    ") || src[i].hasPrefix("\t")) { add([], i - 1) }
            continue
        }

        // Headings (ATX and setext)
        var heading: (Int, String)? = headingLevel(line)
        var consumed = 1
        if heading == nil, i + 1 < src.count {
            let next = src[i + 1].trimmingCharacters(in: .whitespaces)
            if !next.isEmpty, next.allSatisfy({ $0 == "=" }) { heading = (1, line); consumed = 2 }
            else if next.count >= 2, next.allSatisfy({ $0 == "-" }), listItem(raw) == nil { heading = (2, line); consumed = 2 }
        }
        if let (lvl, title) = heading {
            blank(i)
            let fg: UInt8 = lvl <= 3 ? MD.heading : Col.white
            var t = mdInline(lvl == 1 ? title.uppercased() : title, base: fg)
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
            let start = i
            let header = tableCells(line)
            let aligns: [Align] = tableCells(src[i + 1]).map { a in
                let l = a.hasPrefix(":"), r = a.hasSuffix(":")
                return l && r ? .center : (r ? .right : .left)
            }
            var rows: [[String]] = []
            i += 2
            while i < src.count, src[i].contains("|"), !src[i].trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(tableCells(src[i])); i += 1
            }
            let n = max(header.count, rows.map(\.count).max() ?? 0)
            let all = [header] + rows
            let rendered = all.map { r in (0..<n).map { k in k < r.count ? mdInline(r[k]) : [] } }
            var widths = (0..<n).map { k in rendered.map { $0[k].count }.max() ?? 0 }.map { max(1, $0) }
            let avail = W - (3 * n + 1)
            while widths.reduce(0, +) > avail, let m = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[m] > 3 {
                widths[m] -= 1
            }
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
                    if ri == 0 { c = c.map { var x = $0; if x.fg == MD.text { x.fg = MD.heading }; return x } }
                    if c.count > widths[k] { c = Array(c.prefix(widths[k] - 1)) + cells("}", Col.cyan) }
                    let pad = widths[k] - c.count
                    let a = k < aligns.count ? aligns[k] : .left
                    let lp = a == .right ? pad : (a == .center ? pad / 2 : 0)
                    row += cells(" " + spaces(lp), MD.text) + c + cells(spaces(pad - lp) + " ", MD.text) + cells("│", Col.cyan)
                }
                add(row, ri == 0 ? start : start + 1 + ri)
                if ri == 0 { add(border("├", "┼", "┤"), start + 1) }
            }
            add(border("└", "┴", "┘"), i - 1)
            add([], i - 1)
            continue
        }

        // Block quotes
        if line.hasPrefix(">") {
            var depth = 0
            var t = Substring(line)
            while t.hasPrefix(">") { depth += 1; t = t.dropFirst(); t = t.drop { $0 == " " } }
            let prefix = cells(String(repeating: "│ ", count: depth), Col.cyan)
            if t.isEmpty { add(prefix, i) }
            else { for row in wrapCells(mdInline(String(t), base: MD.quote), width: W, first: prefix, rest: prefix) { add(row, i) } }
            i += 1; continue
        }

        // List items (with task-list checkboxes)
        if let item = listItem(raw) {
            let lvl = item.indent / 2
            var text = item.text
            var marker = item.marker == "•" ? (["•", "◦", "▪"][lvl % 3]) : item.marker
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
            let ind = spaces(2 + lvl * 3)
            let first = cells(ind, MD.text) + cells(marker, MD.mark) + cells(" ", MD.text)
            let rest = cells(spaces(first.count), MD.text)
            for row in wrapCells(mdInline(text), width: W, first: first, rest: rest) { add(row, i) }
            i = j
            if i < src.count, src[i].trimmingCharacters(in: .whitespaces).isEmpty,
               i + 1 < src.count, let nx = listItem(src[i + 1]),
               (nx.marker == "•") == (item.marker == "•") { i += 1 } // keep loose lists compact
            continue
        }

        // Paragraph: join soft-wrapped lines, honour hard breaks (two spaces or backslash)
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
        add([], max(start, i - 1))
    }
    while let l = out.last, l.cells.isEmpty { out.removeLast() }
    return out
}
