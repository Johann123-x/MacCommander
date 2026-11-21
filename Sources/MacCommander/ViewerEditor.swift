import AppKit

private func sanitize(_ c: Character) -> Character {
    if c == "\t" || c == "\r" || c.isNewline { return " " }
    if let a = c.asciiValue, a < 32 || a == 127 { return "·" }
    return c
}

// MARK: - Internal viewer (F3)

final class Viewer: Layer {
    unowned let cmd: Commander
    let path: String
    let data: Data
    var lines: [String] = []
    var hex = false
    var top = 0
    var left = 0
    var pageH = 20
    let isMD: Bool
    var formatted: Bool
    private var mdLines: [MDLine] = []
    private var mdWidth = -1
    var fullScreen: Bool { true }

    init(_ cmd: Commander, path: String) {
        self.cmd = cmd
        self.path = path
        isMD = isMarkdownPath(path)
        formatted = isMD
        let limit = 64 * 1024 * 1024
        let d = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)) ?? Data()
        data = d.count > limit ? d.prefix(limit) : d
        hex = data.prefix(8192).contains(0)
        if !hex { buildText() }
    }

    private func buildText() {
        let s = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        lines = s.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: "    ")
        }
    }

    private var showMD: Bool { isMD && formatted && !hex }
    private var total: Int { hex ? (data.count + 15) / 16 : (showMD ? mdLines.count : lines.count) }

    private func buildMD(_ width: Int) {
        guard width != mdWidth else { return }
        mdLines = renderMarkdown(lines.joined(separator: "\n"), width: width)
        mdWidth = width
    }

    private func toggleFormatted() {
        if lines.isEmpty { buildText() }
        if showMD {
            top = mdLines.indices.contains(top) ? mdLines[top].src : 0
            formatted = false
        } else {
            formatted = true
            hex = false
            buildMD(mdWidth > 0 ? mdWidth : 80)
            top = mdLines.firstIndex { $0.src >= top } ?? 0
        }
        left = 0
    }

    private func hexLine(_ i: Int) -> String {
        let start = i * 16
        let end = min(data.count, start + 16)
        var s = String(format: "%08X: ", start)
        var asc = ""
        for j in 0..<16 {
            if start + j < end {
                let b = data[data.startIndex + start + j]
                s += String(format: "%02X ", b)
                asc.append(b >= 32 && b < 127 ? Character(UnicodeScalar(b)) : ".")
            } else {
                s += "   "
            }
            if j == 7 { s += " " }
        }
        return s + " " + asc
    }

    func render(_ s: Screen) {
        s.fill(0, 0, s.cols, s.rows, Col.lcyan, Col.blue)
        pageH = max(1, s.rows - 2)
        if showMD { buildMD(s.cols - 1) }
        top = max(0, min(top, max(0, total - pageH)))
        let pct = total <= pageH ? 100 : Int(Double(top + pageH) * 100 / Double(total))
        let info = " Line \(top + 1)/\(total)  Col \(left)  \(groupNum(Int64(data.count))) bytes  \(pct)% "
        s.fill(0, 0, s.cols, 1, Col.black, Col.cyan)
        s.text(0, 0, fit(" View: " + shortPath(displayPath(path), max(1, s.cols - info.count - 9)), max(0, s.cols - info.count)), Col.black, Col.cyan)
        if info.count < s.cols { s.text(s.cols - info.count, 0, info, Col.black, Col.cyan) }
        for r in 0..<pageH {
            let i = top + r
            guard i < total else { break }
            if showMD {
                for (k, c) in mdLines[i].cells.enumerated() { s.put(k, r + 1, c.ch, c.fg, c.bg) }
                continue
            }
            let line = hex ? hexLine(i) : lines[i]
            var out = ""
            var col = 0
            for c in line {
                if col >= left + s.cols { break }
                if col >= left { out.append(sanitize(c)) }
                col += 1
            }
            s.text(0, r + 1, out, Col.lcyan, Col.blue)
        }
        drawKeybar(s, ["Help", "", isMD ? (showMD ? "Raw" : "Format") : "Quit", hex ? "Text" : "Hex", "", "", "", "", "", "Quit"])
    }

    func handle(_ e: KeyEvent) {
        switch e.key {
        case .up: top -= 1
        case .down: top += 1
        case .pageUp: top -= pageH
        case .pageDown, .char(" "): top += pageH
        case .home: top = 0; left = 0
        case .end: top = total
        case .left: left = max(0, left - 8)
        case .right: left += 8
        case .f(4):
            hex.toggle()
            if !hex && lines.isEmpty { buildText() }
            top = 0
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

final class Editor: Layer {
    unowned let cmd: Commander
    let path: String
    var lines: [[Character]] = [[]]
    var cx = 0, cy = 0, top = 0, left = 0
    var modified = false
    var crlf = false
    var pageH = 20, pageW = 80
    let isMD: Bool
    /// Formatted (read-only) Markdown preview, toggled with F3.
    var preview = false
    private var ptop = 0
    private var mdLines: [MDLine] = []
    private var mdWidth = -1
    var fullScreen: Bool { true }

    init?(_ cmd: Commander, path: String) {
        self.cmd = cmd
        self.path = path
        isMD = isMarkdownPath(path)
        if FileManager.default.fileExists(atPath: path) {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), d.count < 20_000_000,
                  var s = String(data: d, encoding: .utf8) else { return nil }
            crlf = s.contains("\r\n")
            if crlf { s = s.replacingOccurrences(of: "\r\n", with: "\n") }
            lines = s.components(separatedBy: "\n").map { Array($0) }
        }
    }

    private func buildMD(_ width: Int) {
        mdLines = renderMarkdown(lines.map { String($0) }.joined(separator: "\n"), width: width)
        mdWidth = width
    }

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
        s.cursor = nil
        drawKeybar(s, ["Help", "Save", "Edit", "", "", "", "", "", "", "Quit"])
    }

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
        case .f(2): _ = save()
        case .esc, .f(10): quit()
        case .char("s") where e.cmd: _ = save()
        default: break
        }
        ptop = max(0, min(ptop, max(0, mdLines.count - pageH)))
    }

    func render(_ s: Screen) {
        s.fill(0, 0, s.cols, s.rows, Col.lcyan, Col.blue)
        pageH = max(1, s.rows - 2)
        pageW = s.cols
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
            for c in l[left..<min(l.count, left + s.cols)] { out.append(sanitize(c)) }
            s.text(0, r + 1, out, Col.lcyan, Col.blue)
        }
        s.cursor = (cx - left, cy - top + 1)
        drawKeybar(s, ["Help", "Save", isMD ? "Format" : "", "", "", "", "", "DelLin", "", "Quit"])
    }

    private func scrollIntoView() {
        if cy < top { top = cy }
        if cy >= top + pageH { top = cy - pageH + 1 }
        top = max(0, min(top, max(0, lines.count - 1)))
        if cx < left { left = cx }
        if cx >= left + pageW { left = cx - pageW + 1 }
    }

    private func clampX() { cx = min(cx, lines[cy].count) }

    func handle(_ e: KeyEvent) {
        if preview { handlePreview(e); return }
        switch e.key {
        case .f(3) where isMD: togglePreview()
        case .up:
            if e.cmd || e.ctrl { cy = 0; cx = 0 } else if cy > 0 { cy -= 1 }
            clampX()
        case .down:
            if e.cmd || e.ctrl { cy = lines.count - 1; cx = lines[cy].count } else if cy < lines.count - 1 { cy += 1 }
            clampX()
        case .left:
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
            cy = min(lines.count - 1, cy + pageH); top += pageH; clampX()
        case .enter:
            let indent = Array(lines[cy][..<cx].prefix { $0 == " " || $0 == "\t" })
            let rest = Array(lines[cy][cx...])
            lines[cy].removeSubrange(cx...)
            lines.insert(indent + rest, at: cy + 1)
            cy += 1
            cx = indent.count
            modified = true
        case .backspace:
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
        case .char(let c):
            if e.ctrl && c == "y" { deleteLine() }
            else if e.cmd && c == "s" { _ = save() }
            else if e.cmd && c == "v" { insert(NSPasteboard.general.string(forType: .string) ?? "") }
            else if !e.ctrl && !e.cmd { insert(String(c)) }
        default: break
        }
    }

    private func insert(_ s: String) {
        for ch in s {
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

    private func deleteLine() {
        if lines.count > 1 { lines.remove(at: cy); cy = min(cy, lines.count - 1) } else { lines = [[]] }
        clampX()
        modified = true
    }

    func save() -> Bool {
        var s = lines.map { String($0) }.joined(separator: "\n")
        if crlf { s = s.replacingOccurrences(of: "\n", with: "\r\n") }
        do {
            try s.write(toFile: path, atomically: false, encoding: .utf8)
            modified = false
            return true
        } catch {
            cmd.showError("Cannot save \(path): \(error.localizedDescription)")
            return false
        }
    }

    private func quit() {
        if !modified { close(); return }
        cmd.push(Dialog(cmd, title: "Edit", lines: ["The file has been modified.", "Do you want to save it?"],
                        buttons: ["Save", "Don't save", "Cancel"]) { [unowned self] b, _ in
            if b == 0 { if self.save() { self.close() } } else if b == 1 { self.close() }
        })
    }

    private func close() {
        cmd.pop(self)
        cmd.left.reload()
        cmd.right.reload()
    }
}
