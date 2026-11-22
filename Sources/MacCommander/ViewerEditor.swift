import AppKit

// `private` at file level means visible only in this file. `_ c` = no argument label at the call site.
/// Makes a character safe to paint into one grid cell: tabs and line breaks become a space, other control characters a middle dot.
private func sanitize(_ c: Character) -> Character {
    if c == "\t" || c == "\r" || c.isNewline { return " " }
    // `if let a = c.asciiValue, ...`: `asciiValue` is optional (nil for non-ASCII), so unwrap it before comparing.
    if let a = c.asciiValue, a < 32 || a == 127 { return "·" }
    return c
}

// MARK: - Internal viewer (F3)

// `final class Viewer: Layer` = a non-subclassable class implementing an interface (protocol).
/// F3 viewer: full-screen, read-only display of a file as text, hex dump or formatted Markdown.
/// Implements `Layer`, so `Commander` routes keys to it while it is on top of the layer stack.
final class Viewer: Layer {
    // `unowned`: a non-owning reference that is assumed never to be nil. Swift uses reference counting (ARC), not a
    // garbage collector, so a strong back-reference to the Commander, which holds this layer, would form a leak cycle.
    unowned let cmd: Commander
    let path: String
    /// The file contents (at most 64 MiB), memory-mapped so large files are not read into RAM up front.
    let data: Data
    /// Text lines, built lazily; empty while only the hex view has been shown. `[String]` ≈ `List<String>`.
    var lines: [String] = []
    /// Hex dump mode instead of text.
    var hex = false
    /// First visible line (text line, Markdown line or 16-byte hex row, depending on the mode).
    var top = 0
    /// Horizontal scroll offset in characters.
    var left = 0
    /// Number of content rows on screen, set on every render and used for paging.
    var pageH = 20
    let isMD: Bool
    /// Show Markdown rendered rather than raw; only meaningful when `isMD`.
    var formatted: Bool
    /// Rendered Markdown and the width it was rendered for (-1 = not yet), rebuilt when the window width changes.
    private var mdLines: [MDLine] = []
    private var mdWidth = -1
    // Read-only computed property satisfying the protocol requirement `var fullScreen: Bool { get }`.
    var fullScreen: Bool { true }

    // `self.cmd = cmd` as in a Java constructor. All `let` properties must be set before `init` ends.
    init(_ cmd: Commander, path: String) {
        self.cmd = cmd
        self.path = path
        isMD = isMarkdownPath(path)
        formatted = isMD
        // Integer literals can be written with arithmetic; this is 64 MiB.
        let limit = 64 * 1024 * 1024
        // `.alwaysMapped` maps the file into memory (≈ `FileChannel.map`); pages load only when touched.
        // `try?` yields nil on error, `?? Data()` falls back to empty contents, so an unreadable file shows as empty.
        let d = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)) ?? Data()
        // `prefix(limit)` is a view of the first bytes, still backed by the mapping.
        data = d.count > limit ? d.prefix(limit) : d
        // Heuristic: a NUL byte in the first 8 KiB means binary, so start in hex mode.
        hex = data.prefix(8192).contains(0)
        if !hex { buildText() }
    }

    /// Decodes the bytes as UTF-8, falling back to Windows-1252, and splits them into lines with tabs expanded to four spaces.
    private func buildText() {
        // `String(data:encoding:)` is a failable initialiser: it returns nil (rather than throwing) if decoding fails.
        // The `??` chain tries each in turn; the final `String(decoding:as:)` never fails and replaces bad bytes with U+FFFD.
        let s = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        // Trailing closure: `map { ... }` with `$0` as the implicit parameter (≈ `.stream().map(l -> ...)`).
        lines = s.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: "    ")
        }
    }

    // Computed properties: recalculated on each access, no storage.
    private var showMD: Bool { isMD && formatted && !hex }
    /// Number of scrollable rows in the current mode; hex rows hold 16 bytes each, rounded up.
    private var total: Int { hex ? (data.count + 15) / 16 : (showMD ? mdLines.count : lines.count) }

    /// Renders the Markdown for the given width, unless it is already rendered for exactly that width.
    private func buildMD(_ width: Int) {
        // `guard cond else { return }`: early exit when the condition is false; the else branch must leave the scope.
        guard width != mdWidth else { return }
        mdLines = renderMarkdown(lines.joined(separator: "\n"), width: width)
        mdWidth = width
    }

    /// F3 in Markdown files: switches between raw text and formatted view, keeping roughly the same position.
    /// Each `MDLine` remembers its source line (`src`), which maps the scroll position in both directions.
    private func toggleFormatted() {
        if lines.isEmpty { buildText() }
        if showMD {
            // `mdLines.indices.contains(top)` is a bounds check, since out-of-range array access traps (crashes) in Swift.
            top = mdLines.indices.contains(top) ? mdLines[top].src : 0
            formatted = false
        } else {
            formatted = true
            hex = false
            buildMD(mdWidth > 0 ? mdWidth : 80)
            // First rendered line whose source line is at or after the raw position; nil (not found) falls back to 0.
            top = mdLines.firstIndex { $0.src >= top } ?? 0
        }
        left = 0
    }

    /// One hex dump row: 8-digit offset, 16 bytes in two groups of eight, then the printable ASCII characters.
    /// Example: `00000010: 48 65 6C 6C 6F 20 ...  ...  Hello ...`; the last row is padded with spaces.
    private func hexLine(_ i: Int) -> String {
        let start = i * 16
        let end = min(data.count, start + 16)
        // `String(format:)` is printf-style formatting, like Java's `String.format`.
        var s = String(format: "%08X: ", start)
        var asc = ""
        for j in 0..<16 {
            if start + j < end {
                // `Data` indices need not start at 0 (a slice keeps its parent's indices), so offset from `startIndex`.
                let b = data[data.startIndex + start + j]
                s += String(format: "%02X ", b)
                // Printable ASCII is shown as is, everything else as ".".
                asc.append(b >= 32 && b < 127 ? Character(UnicodeScalar(b)) : ".")
            } else {
                s += "   "
            }
            // Extra space between the two groups of eight bytes.
            if j == 7 { s += " " }
        }
        return s + " " + asc
    }

    /// Draws the whole viewer: title bar with position info, the visible rows and the key bar.
    func render(_ s: Screen) {
        s.fill(0, 0, s.cols, s.rows, Col.lcyan, Col.blue)
        pageH = max(1, s.rows - 2)
        if showMD { buildMD(s.cols - 1) }
        // Clamp the scroll position so the last page is full and `top` never goes negative.
        top = max(0, min(top, max(0, total - pageH)))
        let pct = total <= pageH ? 100 : Int(Double(top + pageH) * 100 / Double(total))
        // `\(expr)` is string interpolation (≈ concatenation of `String.valueOf(expr)`).
        let info = " Line \(top + 1)/\(total)  Col \(left)  \(groupNum(Int64(data.count))) bytes  \(pct)% "
        s.fill(0, 0, s.cols, 1, Col.black, Col.cyan)
        s.text(0, 0, fit(" View: " + shortPath(displayPath(path), max(1, s.cols - info.count - 9)), max(0, s.cols - info.count)), Col.black, Col.cyan)
        if info.count < s.cols { s.text(s.cols - info.count, 0, info, Col.black, Col.cyan) }
        for r in 0..<pageH {
            let i = top + r
            guard i < total else { break }
            if showMD {
                // Markdown lines are pre-rendered cells with their own colours, painted one by one.
                for (k, c) in mdLines[i].cells.enumerated() { s.put(k, r + 1, c.ch, c.fg, c.bg) }
                continue
            }
            let line = hex ? hexLine(i) : lines[i]
            // Cut the visible window [left, left + cols) out of the line. Iterating a String yields `Character`s;
            // Swift strings cannot be indexed by an int (characters have variable byte length), so count columns manually.
            var out = ""
            var col = 0
            for c in line {
                if col >= left + s.cols { break }
                if col >= left { out.append(sanitize(c)) }
                col += 1
            }
            s.text(0, r + 1, out, Col.lcyan, Col.blue)
        }
        // Labels for F1..F10; F3 switches Markdown format if applicable, F4 toggles hex.
        drawKeybar(s, ["Help", "", isMD ? (showMD ? "Raw" : "Format") : "Quit", hex ? "Text" : "Hex", "", "", "", "", "", "Quit"])
    }

    /// Keyboard handling for the viewer.
    func handle(_ e: KeyEvent) {
        // `switch` over an enum with associated values: `.char(" ")` matches a Char key carrying a space, `.f(4)` the F4 key.
        // Cases do not fall through; several patterns in one case are separated by commas. Cases are tried in order.
        switch e.key {
        case .up: top -= 1
        case .down: top += 1
        case .pageUp: top -= pageH
        case .pageDown, .char(" "): top += pageH
        case .home: top = 0; left = 0
        // `total` overshoots on purpose; the clamp at the end turns it into the last page.
        case .end: top = total
        case .left: left = max(0, left - 8)
        case .right: left += 8
        case .f(4):
            // `toggle()` flips a Bool in place.
            hex.toggle()
            if !hex && lines.isEmpty { buildText() }
            top = 0
        // `where` adds a condition to a case: F3 toggles formatting only for Markdown files, otherwise it falls to the quit case below.
        case .f(3) where isMD: toggleFormatted()
        case .left where showMD, .right where showMD: break
        case .f(1): cmd.showHelp()
        case .esc, .f(3), .f(10), .char("q"): cmd.pop(self)
        default: break
        }
        top = max(0, min(top, max(0, total - pageH)))
    }
}

// MARK: - Internal editor (F4)

/// F4 editor: a simple full-screen text editor with optional Markdown preview. Saves as UTF-8, keeping CRLF line ends.
final class Editor: Layer {
    unowned let cmd: Commander
    let path: String
    /// The text as lines of characters. `[[Character]]` (array of character arrays) makes cursor columns plain int indices,
    /// which a Swift `String` does not allow. Always at least one (possibly empty) line.
    var lines: [[Character]] = [[]]
    /// Cursor column and line, and the scroll offsets (first visible line and column).
    var cx = 0, cy = 0, top = 0, left = 0
    var modified = false
    /// The file used CRLF line ends; lines are kept with LF internally and converted back on save.
    var crlf = false
    var pageH = 20, pageW = 80
    let isMD: Bool
    /// Formatted (read-only) Markdown preview, toggled with F3.
    var preview = false
    /// First visible line of the preview.
    private var ptop = 0
    private var mdLines: [MDLine] = []
    private var mdWidth = -1
    var fullScreen: Bool { true }

    // Failable initialiser `init?`: returns nil instead of a half-built object (the caller gets an optional `Editor?`).
    // Fails for files of 20 MB or more and for files that are not valid UTF-8. A missing file opens as an empty new file.
    init?(_ cmd: Commander, path: String) {
        self.cmd = cmd
        self.path = path
        isMD = isMarkdownPath(path)
        if FileManager.default.fileExists(atPath: path) {
            // `guard let ..., cond, var ... else { return nil }`: every clause must succeed, otherwise the init fails.
            // `var s` (not `let`) because the string is modified below. `20_000_000`: underscores are digit separators.
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), d.count < 20_000_000,
                  var s = String(data: d, encoding: .utf8) else { return nil }
            crlf = s.contains("\r\n")
            if crlf { s = s.replacingOccurrences(of: "\r\n", with: "\n") }
            // `Array($0)` converts each line String into a `[Character]`.
            lines = s.components(separatedBy: "\n").map { Array($0) }
        }
    }

    /// Renders the current text as Markdown for the preview.
    private func buildMD(_ width: Int) {
        mdLines = renderMarkdown(lines.map { String($0) }.joined(separator: "\n"), width: width)
        mdWidth = width
    }

    /// F3 in Markdown files: switches between editing and the read-only preview.
    /// Leaving the preview moves the cursor into the area that was shown, if it is not already there.
    private func togglePreview() {
        if preview {
            if mdLines.indices.contains(ptop) {
                let src = mdLines[ptop].src
                cy = min(max(cy, src), lines.count - 1)
                if cy >= src + pageH { cy = src }
                top = src
                clampX()
            }
            preview = false
        } else {
            buildMD(mdWidth > 0 ? mdWidth : pageW - 1)
            ptop = mdLines.firstIndex { $0.src >= top } ?? 0
            preview = true
        }
    }

    /// Draws the Markdown preview (no cursor).
    private func renderPreview(_ s: Screen) {
        if mdWidth != s.cols - 1 { buildMD(s.cols - 1) }
        ptop = max(0, min(ptop, max(0, mdLines.count - pageH)))
        let pct = mdLines.count <= pageH ? 100 : Int(Double(ptop + pageH) * 100 / Double(mdLines.count))
        let info = " Preview  \(pct)% " + (modified ? "*" : " ") + " "
        s.fill(0, 0, s.cols, 1, Col.black, Col.cyan)
        s.text(0, 0, fit(" Edit: " + shortPath(displayPath(path), max(1, s.cols - info.count - 9)), max(0, s.cols - info.count)), Col.black, Col.cyan)
        s.text(s.cols - info.count, 0, info, Col.black, Col.cyan)
        for r in 0..<pageH {
            let i = ptop + r
            guard i < mdLines.count else { break }
            for (k, c) in mdLines[i].cells.enumerated() { s.put(k, r + 1, c.ch, c.fg, c.bg) }
        }
        // nil hides the text cursor.
        s.cursor = nil
        drawKeybar(s, ["Help", "Save", "Edit", "", "", "", "", "", "", "Quit"])
    }

    /// Keys in preview mode: scrolling, save, back to edit (F3) and quit.
    private func handlePreview(_ e: KeyEvent) {
        switch e.key {
        case .up: ptop -= 1
        case .down: ptop += 1
        case .pageUp: ptop -= pageH
        case .pageDown, .char(" "): ptop += pageH
        case .home: ptop = 0
        case .end: ptop = mdLines.count
        case .f(3): togglePreview()
        case .f(1): cmd.showHelp()
        // `_ = save()` explicitly ignores the Bool result.
        case .f(2): _ = save()
        case .esc, .f(10): quit()
        // `e.cmd` is the Command modifier, so this is Cmd+S.
        case .char("s") where e.cmd: _ = save()
        default: break
        }
        ptop = max(0, min(ptop, max(0, mdLines.count - pageH)))
    }

    /// Draws the editor: title bar with line/column and modified flag, visible text and cursor.
    func render(_ s: Screen) {
        s.fill(0, 0, s.cols, s.rows, Col.lcyan, Col.blue)
        pageH = max(1, s.rows - 2)
        pageW = s.cols
        // Preview replaces the normal rendering entirely.
        if preview { renderPreview(s); return }
        scrollIntoView()
        let info = " Line \(cy + 1)  Col \(cx + 1) " + (modified ? "*" : " ") + " "
        s.fill(0, 0, s.cols, 1, Col.black, Col.cyan)
        s.text(0, 0, fit(" Edit: " + shortPath(displayPath(path), max(1, s.cols - info.count - 9)), max(0, s.cols - info.count)), Col.black, Col.cyan)
        s.text(s.cols - info.count, 0, info, Col.black, Col.cyan)
        for r in 0..<pageH {
            let i = top + r
            guard i < lines.count else { break }
            let l = lines[i]
            guard left < l.count else { continue }
            var out = ""
            // `l[a..<b]` is a slice (sub-range view) of the character array, bounded to the visible width.
            for c in l[left..<min(l.count, left + s.cols)] { out.append(sanitize(c)) }
            s.text(0, r + 1, out, Col.lcyan, Col.blue)
        }
        // A tuple `(x, y)` of screen coordinates; +1 because row 0 is the title bar.
        s.cursor = (cx - left, cy - top + 1)
        drawKeybar(s, ["Help", "Save", isMD ? "Format" : "", "", "", "", "", "DelLin", "", "Quit"])
    }

    /// Adjusts the scroll offsets so the cursor is on screen, scrolling as little as possible.
    private func scrollIntoView() {
        if cy < top { top = cy }
        if cy >= top + pageH { top = cy - pageH + 1 }
        top = max(0, min(top, max(0, lines.count - 1)))
        if cx < left { left = cx }
        if cx >= left + pageW { left = cx - pageW + 1 }
    }

    /// Keeps the cursor column within the current line (at most just past the last character).
    private func clampX() { cx = min(cx, lines[cy].count) }

    /// Keyboard handling for the editor: movement, editing, save and quit.
    func handle(_ e: KeyEvent) {
        if preview { handlePreview(e); return }
        switch e.key {
        case .f(3) where isMD: togglePreview()
        case .up:
            // Cmd/Ctrl+Up jumps to the start of the text.
            if e.cmd || e.ctrl { cy = 0; cx = 0 } else if cy > 0 { cy -= 1 }
            clampX()
        case .down:
            if e.cmd || e.ctrl { cy = lines.count - 1; cx = lines[cy].count } else if cy < lines.count - 1 { cy += 1 }
            clampX()
        case .left:
            // Left at column 0 wraps to the end of the previous line; Right at the end wraps to the next line.
            if e.cmd { cx = 0 } else if cx > 0 { cx -= 1 } else if cy > 0 { cy -= 1; cx = lines[cy].count }
        case .right:
            if e.cmd { cx = lines[cy].count } else if cx < lines[cy].count { cx += 1 } else if cy < lines.count - 1 { cy += 1; cx = 0 }
        case .home:
            if e.ctrl || e.cmd { cy = 0 }
            cx = 0
        case .end:
            if e.ctrl || e.cmd { cy = lines.count - 1 }
            cx = lines[cy].count
        case .pageUp:
            cy = max(0, cy - pageH); top = max(0, top - pageH); clampX()
        case .pageDown:
            // `top += pageH` may overshoot; `scrollIntoView` clamps it on the next render.
            cy = min(lines.count - 1, cy + pageH); top += pageH; clampX()
        case .enter:
            // Enter splits the line at the cursor and copies the leading whitespace of the current line (auto-indent).
            // `[..<cx]` and `[cx...]` are one-sided ranges: up to (excluding) cx, and from cx to the end.
            let indent = Array(lines[cy][..<cx].prefix { $0 == " " || $0 == "\t" })
            let rest = Array(lines[cy][cx...])
            lines[cy].removeSubrange(cx...)
            lines.insert(indent + rest, at: cy + 1)
            cy += 1
            cx = indent.count
            modified = true
        case .backspace:
            // Backspace at column 0 joins the line with the previous one.
            if cx > 0 {
                lines[cy].remove(at: cx - 1); cx -= 1; modified = true
            } else if cy > 0 {
                cx = lines[cy - 1].count
                lines[cy - 1] += lines[cy]
                lines.remove(at: cy)
                cy -= 1
                modified = true
            }
        case .delete:
            // Delete at the end of a line pulls the next line up.
            if cx < lines[cy].count {
                lines[cy].remove(at: cx); modified = true
            } else if cy < lines.count - 1 {
                lines[cy] += lines[cy + 1]
                lines.remove(at: cy + 1)
                modified = true
            }
        case .tab: insert("    ")
        case .f(1): cmd.showHelp()
        case .f(2): _ = save()
        case .f(8): deleteLine()
        case .esc, .f(10): quit()
        // `case .char(let c)` binds the key's associated Character value to `c`.
        case .char(let c):
            if e.ctrl && c == "y" { deleteLine() }
            else if e.cmd && c == "s" { _ = save() }
            else if e.cmd && c == "v" { insert(NSPasteboard.general.string(forType: .string) ?? "") }
            else if !e.ctrl && !e.cmd { insert(String(c)) }
        default: break
        }
    }

    /// Inserts text at the cursor; newlines in the text (for example from a paste) split the line.
    private func insert(_ s: String) {
        for ch in s {
            // "\r\n" is a single `Character` in Swift (one grapheme cluster), so it needs its own comparison.
            if ch == "\n" || ch == "\r\n" {
                let rest = Array(lines[cy][cx...])
                lines[cy].removeSubrange(cx...)
                lines.insert(rest, at: cy + 1)
                cy += 1
                cx = 0
            } else if ch != "\r" {
                lines[cy].insert(ch, at: cx)
                cx += 1
            }
        }
        modified = true
    }

    /// Removes the cursor line; the last remaining line is only emptied.
    private func deleteLine() {
        if lines.count > 1 { lines.remove(at: cy); cy = min(cy, lines.count - 1) } else { lines = [[]] }
        clampX()
        modified = true
    }

    /// Writes the text back to the file. Returns false and shows an error on failure.
    func save() -> Bool {
        var s = lines.map { String($0) }.joined(separator: "\n")
        if crlf { s = s.replacingOccurrences(of: "\n", with: "\r\n") }
        // `do { try ... } catch { ... }` ≈ try/catch; the caught error is available as the implicit `error` constant.
        do {
            try s.write(toFile: path, atomically: false, encoding: .utf8)
            modified = false
            return true
        } catch {
            cmd.showError("Cannot save \(path): \(error.localizedDescription)")
            return false
        }
    }

    /// Closes the editor, first asking whether to save if there are unsaved changes.
    private func quit() {
        if !modified { close(); return }
        // Trailing closure called with the button index. `[unowned self]` captures `self` without a strong
        // reference to avoid a retain cycle (ARC); inside the closure `self.` is then written explicitly.
        cmd.push(Dialog(cmd, title: "Edit", lines: ["The file has been modified.", "Do you want to save it?"],
                        buttons: ["Save", "Don't save", "Cancel"]) { [unowned self] b, _ in
            if b == 0 { if self.save() { self.close() } } else if b == 1 { self.close() }
        })
    }

    /// Removes the editor layer and re-reads both panels so changed sizes and dates show up.
    private func close() {
        cmd.pop(self)
        cmd.left.reload()
        cmd.right.reload()
    }
}
