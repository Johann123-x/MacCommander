import AppKit

// MARK: - Text-mode screen model (cells with DOS colours)

// `struct` is a value type: assigning or passing it copies it (no shared reference, never null).
// Fields with defaults give a memberwise initialiser with optional arguments: `Cell()` or `Cell(ch: "x", fg: 7, bg: 0)`.
/// One character cell of the text screen: the character plus foreground and background colour,
/// both indices into `dosPalette` (0-15).
struct Cell {
    // `Character` is one user-perceived character (a grapheme cluster such as "é" or an emoji), not a 16-bit `char`.
    var ch: Character = " "
    var fg: UInt8 = 7
    var bg: UInt8 = 0
}

// An `enum` without cases cannot be instantiated; it serves purely as a namespace for constants
// (like a Java final class with a private constructor and `static final` fields).
/// Names of the 16 DOS text-mode colours as indices into `dosPalette` ("d" = dark, "l" = light).
enum Col {
    static let black: UInt8 = 0, blue: UInt8 = 1, green: UInt8 = 2, cyan: UInt8 = 3
    static let red: UInt8 = 4, magenta: UInt8 = 5, brown: UInt8 = 6, gray: UInt8 = 7
    static let dgray: UInt8 = 8, lblue: UInt8 = 9, lgreen: UInt8 = 10, lcyan: UInt8 = 11
    static let lred: UInt8 = 12, lmagenta: UInt8 = 13, yellow: UInt8 = 14, white: UInt8 = 15
}

// A global `let` is initialised lazily and thread-safely on first access (like a static holder class).
// `.map { (v: Int) -> NSColor in ... }` converts each hex value with a closure; `in` separates the
// closure's parameter list and return type from its body.
/// The 16 standard CGA/VGA text-mode colours, indexed by the `Col` constants.
let dosPalette: [NSColor] = [
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
].map { (v: Int) -> NSColor in
    // Extracts the red, green and blue bytes of 0xRRGGBB and scales each to 0...1.
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// The character-cell frame buffer. `Commander.render()` clears and redraws it completely on every
/// event, and `TerminalView` paints it. Coordinates are (x = column, y = row), origin top left.
final class Screen {
    // `private(set)`: readable from everywhere, writable only inside this class (a getter without setter).
    private(set) var cols: Int
    private(set) var rows: Int
    // Row-major storage: cell (x, y) lives at index `y * cols + x`.
    private(set) var cells: [Cell]
    // An optional tuple with named elements; nil hides the text cursor. Layers set it while rendering.
    var cursor: (x: Int, y: Int)?

    // `init` is the constructor; `self.cols = cols` disambiguates field and parameter like `this.cols`.
    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        cells = Array(repeating: Cell(), count: cols * rows)
    }

    /// Changes the grid size and blanks all cells; `TerminalView` calls it when its size in cells changes.
    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        cells = Array(repeating: Cell(), count: cols * rows)
    }

    // A subscript makes `screen[x, y]` work like array access. Read-only and, unlike `put`, not bounds-checked.
    subscript(x: Int, y: Int) -> Cell { cells[y * cols + x] }

    // Parameters with default values may be omitted: `clear()` (Java would need overloads).
    /// Fills the whole grid with blanks and hides the cursor; the first step of every redraw.
    func clear(fg: UInt8 = Col.gray, bg: UInt8 = Col.black) {
        // `cells.indices` is the range of valid indices, `0..<cells.count`.
        for i in cells.indices { cells[i] = Cell(ch: " ", fg: fg, bg: bg) }
        cursor = nil
    }

    // `_` before a parameter name drops the argument label, so calls read `put(x, y, ch, fg, bg)`.
    /// Writes one character. Positions outside the grid are ignored, so callers can draw partly off-screen.
    func put(_ x: Int, _ y: Int, _ ch: Character, _ fg: UInt8, _ bg: UInt8) {
        // `guard ... else { return }`: early exit unless all comma-separated conditions hold.
        guard x >= 0, y >= 0, x < cols, y < rows else { return }
        cells[y * cols + x] = Cell(ch: ch, fg: fg, bg: bg)
    }

    // `@discardableResult` suppresses the compiler warning when a caller ignores the return value.
    /// Writes a string from column `x` (no wrapping, clipped at the edge) and returns the column after it.
    @discardableResult
    func text(_ x: Int, _ y: Int, _ s: String, _ fg: UInt8, _ bg: UInt8) -> Int {
        var cx = x
        // Iterating over a String yields its `Character`s. `;` separates two statements on one line.
        for c in s { put(cx, y, c, fg, bg); cx += 1 }
        return cx
    }

    /// Fills a `w` x `h` rectangle with `ch` (default blank) in the given colours.
    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fg: UInt8, _ bg: UInt8, _ ch: Character = " ") {
        guard w > 0, h > 0 else { return }
        // `a..<b` is a half-open range (b excluded); `a...b` (used in `shadow`) includes b.
        for yy in y..<(y + h) { for xx in x..<(x + w) { put(xx, yy, ch, fg, bg) } }
    }

    /// Draws a frame with box-drawing characters: double lines by default, single with `double: false`.
    func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fg: UInt8, _ bg: UInt8, double: Bool = true) {
        guard w >= 2, h >= 2 else { return }
        // The ternary `?:` works as in Java. One `let` can declare several constants.
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
        // Right strip, two columns wide, from one row below the top down to the bottom shadow row.
        for yy in (y + 1)...(y + h) { darken(x + w, yy); darken(x + w + 1, yy) }
        // Bottom strip, one row high, starting two columns in from the left edge.
        for xx in (x + 2)..<(x + w + 2) { darken(xx, y + h) }
    }

    /// Shadow effect for one cell: the character stays, the colours become dark grey on black.
    private func darken(_ x: Int, _ y: Int) {
        guard x >= 0, y >= 0, x < cols, y < rows else { return }
        // Array elements that are structs can be modified in place through the subscript.
        cells[y * cols + x].fg = Col.dgray
        cells[y * cols + x].bg = Col.black
    }
}

// MARK: - String helpers

// A plain enum; where the type is known its values are written `.left`, `.center` etc.
/// Horizontal alignment for `fit`.
enum Align { case left, right, center }

// Functions at file level are global within the module (no enclosing class needed, unlike Java).
/// A string of `n` blanks (empty for n <= 0).
func spaces(_ n: Int) -> String { n > 0 ? String(repeating: " ", count: n) : "" }

/// Pads or truncates `s` to exactly `w` characters; truncated text gets a "}" in the last column.
func fit(_ s: String, _ w: Int, _ align: Align = .left) -> String {
    guard w > 0 else { return "" }
    // `count` counts Characters and is O(n): Swift strings are not integer-indexable because characters
    // have variable length.
    let n = s.count
    // `prefix(k)` returns the first k characters as a `Substring` (a view onto the original);
    // `String(...)` copies it into a new String.
    if n > w { return String(s.prefix(w - 1)) + "}" }
    // A `switch` over an enum must cover every case; with all cases listed, no `default` is needed.
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
    // "…" is a single Character, so the result is exactly `w` characters long.
    return "…" + String(s.suffix(w - 1))
}

/// Word-wraps `text` to lines of at most `width` characters. "\n" starts a new paragraph,
/// words longer than `width` are split hard.
func wrap(_ text: String, _ width: Int) -> [String] {
    // An empty array with an explicit type annotation (like `List<String> out = new ArrayList<>()`).
    var out: [String] = []
    for para in text.components(separatedBy: "\n") {
        var line = ""
        // Empty pieces are kept, so runs of blanks are preserved.
        for word in para.split(separator: " ", omittingEmptySubsequences: false) {
            let w = String(word)
            // Start the line with the word, append it if it still fits, otherwise emit the line and start a new one.
            if line.isEmpty { line = w } else if line.count + 1 + w.count <= width { line += " " + w } else { out.append(line); line = w }
            // Hard-split whatever is still too long (a single word wider than the line).
            while line.count > width { out.append(String(line.prefix(width))); line = String(line.dropFirst(width)) }
        }
        out.append(line)
    }
    return out
}

/// Returns `p` relative to the directory `root` ("/a/b/c" under "/a" is "b/c"), or `p` unchanged when it lies
/// outside `root`. Used to list Find File results.
func relativePath(_ p: String, under root: String) -> String {
    // The root directory "/" already ends in a slash; appending another would give "//", which never matches.
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
}

/// Abbreviates the home folder as "~" for display.
func displayPath(_ p: String) -> String {
    // Normalises to precomposed Unicode (NFC): paths may contain decomposed umlauts, which would not compare
    // equal to the precomposed form. `let p = p...` shadows the parameter, which Swift allows.
    let p = p.precomposedStringWithCanonicalMapping
    let home = NSHomeDirectory().precomposedStringWithCanonicalMapping
    if p == home { return "~" }
    // `dropFirst(k)` drops the first k characters; String + Substring concatenates to a String.
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
    // `removeFirst()` removes and returns the first element (possible because `comps` is a `var`).
    let head = absolute ? "/" + comps.removeFirst() : comps.removeFirst()
    var tail = comps.removeLast()
    let headPart = head + "/…/"
    if headPart.count + tail.count > w {
        // Not even the last folder fits with the head: show "…/last" (or its end)
        return tail.count + 2 <= w ? "…/" + tail : fitTail(tail, w)
    }
    // `while let c = comps.last, cond`: loop while there is a last middle folder and it still fits,
    // adding folders from right to left.
    while let c = comps.last, headPart.count + c.count + 1 + tail.count <= w {
        tail = c + "/" + tail
        comps.removeLast()
    }
    // If all middle folders fitted, no "…" is needed.
    return comps.isEmpty ? head + "/" + tail : headPart + tail
}

// Global constants with a closure initialiser `= { ... }()`: the closure configures the formatter and is
// called once, lazily and thread-safely on first use (like a static initialiser block).
/// Formats of the date and time columns in the panels; `timeFmt` is also used for the clock.
let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yy"; return f }()
let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
/// Decimal format with "." as thousands separator, used by `groupNum`.
let numFmt: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.usesGroupingSeparator = true; return f
}()

// `"\(n)"` is string interpolation: the value is inserted into the literal (like `String.valueOf(n)`).
/// An integer with thousands separators, e.g. "1.234.567"; falls back to plain digits.
func groupNum(_ n: Int64) -> String { numFmt.string(from: NSNumber(value: n)) ?? "\(n)" }
/// A human-readable size such as "12 MB" from the system formatter (locale-dependent).
func human(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// `1_000_000_000`: underscores in number literals are only for readability, as in Java.
/// Text for the panel size column that stays narrow: bytes below 1 GB, otherwise K, M or G (binary units).
func sizeString(_ n: Int64) -> String {
    if n < 1_000_000_000 { return "\(n)" }
    let k = n / 1024
    if k < 100_000_000 { return "\(k)K" }
    // `>> 20` divides by 1024 * 1024.
    let m = n >> 20
    if m < 100_000_000 { return "\(m)M" }
    return "\(n >> 30)G"
}

/// Draws the bottom key bar: ten slots, each with the key number in grey followed by the label on cyan.
func drawKeybar(_ s: Screen, _ labels: [String]) {
    let y = s.rows - 1
    let slot = s.cols / 10
    var x = 0
    for i in 0..<10 {
        let num = "\(i + 1)"
        // Equal slots; the last one takes the remainder so the bar spans the full width.
        let w = i == 9 ? s.cols - x : slot
        s.text(x, y, num, Col.gray, Col.black)
        let label = i < labels.count ? labels[i] : ""
        s.text(x + num.count, y, fit(label, max(0, w - num.count)), Col.black, Col.cyan)
        x += w
    }
}

/// True if both URLs refer to the same file system object, even when the paths differ (e.g. in letter
/// case on a case-insensitive volume).
func sameFile(_ a: URL, _ b: URL) -> Bool {
    // `try?` yields nil if `resourceValues` throws, and `?.` then reads the property only if there is a value.
    // `guard let a = ..., let b = ... else { return false }` unwraps both or leaves the function.
    guard let ia = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
          let ib = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    else { return false }
    // `isEqual` is the Objective-C equality method (like Java `equals`); the identifiers are opaque objects.
    return ia.isEqual(ib)
}
