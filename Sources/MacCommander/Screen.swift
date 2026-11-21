import AppKit

// MARK: - Text-mode screen model (cells with DOS colours)

struct Cell {
    var ch: Character = " "
    var fg: UInt8 = 7
    var bg: UInt8 = 0
}

enum Col {
    static let black: UInt8 = 0, blue: UInt8 = 1, green: UInt8 = 2, cyan: UInt8 = 3
    static let red: UInt8 = 4, magenta: UInt8 = 5, brown: UInt8 = 6, gray: UInt8 = 7
    static let dgray: UInt8 = 8, lblue: UInt8 = 9, lgreen: UInt8 = 10, lcyan: UInt8 = 11
    static let lred: UInt8 = 12, lmagenta: UInt8 = 13, yellow: UInt8 = 14, white: UInt8 = 15
}

let dosPalette: [NSColor] = [
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
].map { (v: Int) -> NSColor in
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

final class Screen {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var cells: [Cell]
    var cursor: (x: Int, y: Int)?

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        cells = Array(repeating: Cell(), count: cols * rows)
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        cells = Array(repeating: Cell(), count: cols * rows)
    }

    subscript(x: Int, y: Int) -> Cell { cells[y * cols + x] }

    func clear(fg: UInt8 = Col.gray, bg: UInt8 = Col.black) {
        for i in cells.indices { cells[i] = Cell(ch: " ", fg: fg, bg: bg) }
        cursor = nil
    }

    func put(_ x: Int, _ y: Int, _ ch: Character, _ fg: UInt8, _ bg: UInt8) {
        guard x >= 0, y >= 0, x < cols, y < rows else { return }
        cells[y * cols + x] = Cell(ch: ch, fg: fg, bg: bg)
    }

    @discardableResult
    func text(_ x: Int, _ y: Int, _ s: String, _ fg: UInt8, _ bg: UInt8) -> Int {
        var cx = x
        for c in s { put(cx, y, c, fg, bg); cx += 1 }
        return cx
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fg: UInt8, _ bg: UInt8, _ ch: Character = " ") {
        guard w > 0, h > 0 else { return }
        for yy in y..<(y + h) { for xx in x..<(x + w) { put(xx, yy, ch, fg, bg) } }
    }

    func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fg: UInt8, _ bg: UInt8, double: Bool = true) {
        guard w >= 2, h >= 2 else { return }
        let hz: Character = double ? "═" : "─", vt: Character = double ? "║" : "│"
        put(x, y, double ? "╔" : "┌", fg, bg)
        put(x + w - 1, y, double ? "╗" : "┐", fg, bg)
        put(x, y + h - 1, double ? "╚" : "└", fg, bg)
        put(x + w - 1, y + h - 1, double ? "╝" : "┘", fg, bg)
        for i in 1..<(w - 1) { put(x + i, y, hz, fg, bg); put(x + i, y + h - 1, hz, fg, bg) }
        for j in 1..<(h - 1) { put(x, y + j, vt, fg, bg); put(x + w - 1, y + j, vt, fg, bg) }
    }

    /// Classic DOS drop shadow (2 columns right, 1 row below).
    func shadow(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        for yy in (y + 1)...(y + h) { darken(x + w, yy); darken(x + w + 1, yy) }
        for xx in (x + 2)..<(x + w + 2) { darken(xx, y + h) }
    }

    private func darken(_ x: Int, _ y: Int) {
        guard x >= 0, y >= 0, x < cols, y < rows else { return }
        cells[y * cols + x].fg = Col.dgray
        cells[y * cols + x].bg = Col.black
    }
}

// MARK: - String helpers

enum Align { case left, right, center }

func spaces(_ n: Int) -> String { n > 0 ? String(repeating: " ", count: n) : "" }

func fit(_ s: String, _ w: Int, _ align: Align = .left) -> String {
    guard w > 0 else { return "" }
    let n = s.count
    if n > w { return String(s.prefix(w - 1)) + "}" }
    switch align {
    case .left: return s + spaces(w - n)
    case .right: return spaces(w - n) + s
    case .center:
        let l = (w - n) / 2
        return spaces(l) + s + spaces(w - n - l)
    }
}

/// Truncates from the front (for paths).
func fitTail(_ s: String, _ w: Int) -> String {
    guard w > 0 else { return "" }
    if s.count <= w { return s }
    return "…" + String(s.suffix(w - 1))
}

func wrap(_ text: String, _ width: Int) -> [String] {
    var out: [String] = []
    for para in text.components(separatedBy: "\n") {
        var line = ""
        for word in para.split(separator: " ", omittingEmptySubsequences: false) {
            let w = String(word)
            if line.isEmpty { line = w } else if line.count + 1 + w.count <= width { line += " " + w } else { out.append(line); line = w }
            while line.count > width { out.append(String(line.prefix(width))); line = String(line.dropFirst(width)) }
        }
        out.append(line)
    }
    return out
}

func displayPath(_ p: String) -> String {
    let p = p.precomposedStringWithCanonicalMapping
    let home = NSHomeDirectory().precomposedStringWithCanonicalMapping
    if p == home { return "~" }
    if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
    return p
}

/// Shortens a path to `w` characters by dropping middle folders, keeping the start
/// and as many trailing folders as fit: "~/Documents/…/scratchpad/sz".
func shortPath(_ p: String, _ w: Int) -> String {
    guard w > 0 else { return "" }
    if p.count <= w { return p }
    let absolute = p.hasPrefix("/")
    var comps = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard comps.count >= 2 else { return fitTail(p, w) }
    // Head: "~" or "/first"
    let head = absolute ? "/" + comps.removeFirst() : comps.removeFirst()
    var tail = comps.removeLast()
    let headPart = head + "/…/"
    if headPart.count + tail.count > w {
        // Not even the last folder fits with the head: show "…/last" (or its end)
        return tail.count + 2 <= w ? "…/" + tail : fitTail(tail, w)
    }
    while let c = comps.last, headPart.count + c.count + 1 + tail.count <= w {
        tail = c + "/" + tail
        comps.removeLast()
    }
    return comps.isEmpty ? head + "/" + tail : headPart + tail
}

let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yy"; return f }()
let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
let numFmt: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.usesGroupingSeparator = true; return f
}()

func groupNum(_ n: Int64) -> String { numFmt.string(from: NSNumber(value: n)) ?? "\(n)" }
func human(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

func sizeString(_ n: Int64) -> String {
    if n < 1_000_000_000 { return "\(n)" }
    let k = n / 1024
    if k < 100_000_000 { return "\(k)K" }
    let m = n >> 20
    if m < 100_000_000 { return "\(m)M" }
    return "\(n >> 30)G"
}

func drawKeybar(_ s: Screen, _ labels: [String]) {
    let y = s.rows - 1
    let slot = s.cols / 10
    var x = 0
    for i in 0..<10 {
        let num = "\(i + 1)"
        let w = i == 9 ? s.cols - x : slot
        s.text(x, y, num, Col.gray, Col.black)
        let label = i < labels.count ? labels[i] : ""
        s.text(x + num.count, y, fit(label, max(0, w - num.count)), Col.black, Col.cyan)
        x += w
    }
}

func sameFile(_ a: URL, _ b: URL) -> Bool {
    guard let ia = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
          let ib = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    else { return false }
    return ia.isEqual(ib)
}
