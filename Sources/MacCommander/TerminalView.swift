// `import` brings in a whole module (AppKit = the Cocoa UI framework), not single classes as in Java.
import AppKit

// MARK: - Keys

// Swift enum cases can carry data ("associated values"), similar to a sealed interface with one record per case in Java 17+.
// `: Equatable` makes `==` available; the compiler synthesises the equals() implementation.
/// A logical key, independent of the keyboard layout. Built by `KeyEvent.from` and consumed by `Commander.handle`.
enum Key: Equatable {
    // A printable character. `Character` is one user-perceived character (may be several code points), not a UTF-16 `char`.
    case char(Character)
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, esc, tab, backspace, delete, insert
    // Function key with its number as associated value: `.f(5)` is F5, matched with `case .f(let n)` in a `switch`.
    case f(Int)
}

// `struct` is a value type: assignment copies it, there are no shared references (unlike a Java object).
// `var` fields are mutable, `let` fields would be final.
/// A key press together with the modifier keys held, as passed from the view to the controller.
struct KeyEvent {
    var key: Key
    // Fields with default values may be omitted in the compiler-generated memberwise initialiser: `KeyEvent(key: .esc)`.
    var shift = false
    var ctrl = false
    var alt = false
    var cmd = false

    // `[UInt16: Key]` is a dictionary type (≈ `Map<Short, Key>`, but `UInt16` is unsigned) and `[k: v, ...]` is its literal.
    // `private static let` ≈ private static final. `.up` is short for `Key.up`; the enum type is inferred from context.
    /// Maps macOS virtual key codes (physical key positions, Carbon `kVK_*` constants) to special keys.
    private static let special: [UInt16: Key] = [
        126: .up, 125: .down, 123: .left, 124: .right, 116: .pageUp, 121: .pageDown,
        // 36 is Return, 76 the keypad Enter; 114 is the Help key, which sits where Insert is on PC keyboards.
        115: .home, 119: .end, 36: .enter, 76: .enter, 53: .esc, 48: .tab,
        51: .backspace, 117: .delete, 114: .insert,
        122: .f(1), 120: .f(2), 99: .f(3), 118: .f(4), 96: .f(5), 97: .f(6),
        98: .f(7), 100: .f(8), 101: .f(9), 109: .f(10), 103: .f(11), 111: .f(12),
    ]
    // Physical digit keys -> Cmd+digit acts as F-key (Mac keyboards often lack real F-keys)
    // The digit row codes are not sequential (5 is 23, 6 is 22, 0 is 29), hence the explicit table; Cmd+0 becomes F10.
    private static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10]

    // `KeyEvent?` is an optional: a value or `nil`. Callers must unwrap it before use, unlike a nullable Java reference.
    // `_ e` means the parameter has no label at the call site: `from(event)` instead of `from(e: event)`.
    /// Translates an AppKit key event into a `KeyEvent`, or returns `nil` for keys the app ignores (e.g. control characters).
    static func from(_ e: NSEvent) -> KeyEvent? {
        // `let` declares a constant (≈ final local variable), `var` a mutable one; the types are inferred.
        let f = e.modifierFlags
        // The key is a placeholder; it is overwritten below before returning.
        var ev = KeyEvent(key: .esc)
        // `modifierFlags` is an OptionSet (≈ EnumSet); `contains` tests membership.
        ev.shift = f.contains(.shift)
        ev.ctrl = f.contains(.control)
        ev.alt = f.contains(.option)
        ev.cmd = f.contains(.command)
        // A dictionary lookup returns an optional. `if let k = ...` runs the block only for a non-nil value, bound to `k`
        // (≈ `Key k = map.get(code); if (k != null) { ... }`).
        if let k = special[e.keyCode] { ev.key = k; return ev }
        // A comma in an `if` condition means "and"; later clauses may use bindings of earlier ones.
        if ev.cmd, let d = digits[e.keyCode] { ev.key = .f(d); ev.cmd = false; return ev }
        // With Ctrl or Cmd held, `characters` holds a control code, so take the unmodified key, lower-cased (Ctrl+C arrives as "c").
        if ev.ctrl || ev.cmd {
            // `guard cond else { ... }` is an early exit: the else block must leave the scope, and bindings stay valid after the guard.
            // `??` supplies a default when the left side is nil. `.first` is optional too, as the string may be empty.
            guard let c = (e.charactersIgnoringModifiers ?? "").lowercased().first else { return nil }
            ev.key = .char(c)
            return ev
        }
        // Plain typing: use the character actually produced by the keyboard layout (including Shift).
        guard let c = (e.characters ?? "").first else { return nil }
        // `asciiValue` is nil for non-ASCII characters. ASCII control codes (below 32, and DEL) are ignored.
        if let a = c.asciiValue, a < 32 || a == 127 { return nil }
        ev.key = .char(c)
        ev.alt = false // Option-composed characters (@, |, \, {, … on German layouts) are plain text
        return ev
    }
}

// MARK: - Box drawing

// `let u, d, l, r: UInt8` declares four immutable fields; `UInt8` is an unsigned byte (0...255), which Java lacks.
/// Which arms a box-drawing character has towards up, down, left and right: 0 = none, 1 = single line, 2 = double line.
struct BoxSpec { let u, d, l, r: UInt8 }

// A top-level `let` is a global constant. Without a modifier, visibility is `internal`: visible in the whole module.
/// Box-drawing characters that `TerminalView` strokes as lines instead of drawing the font glyph. The cells are taller
/// than the font's line height, so glyphs would leave gaps; lines reach the cell edges and frames join seamlessly.
let boxTable: [Character: BoxSpec] = [
    "─": BoxSpec(u: 0, d: 0, l: 1, r: 1), "│": BoxSpec(u: 1, d: 1, l: 0, r: 0),
    "┌": BoxSpec(u: 0, d: 1, l: 0, r: 1), "┐": BoxSpec(u: 0, d: 1, l: 1, r: 0),
    "└": BoxSpec(u: 1, d: 0, l: 0, r: 1), "┘": BoxSpec(u: 1, d: 0, l: 1, r: 0),
    "├": BoxSpec(u: 1, d: 1, l: 0, r: 1), "┤": BoxSpec(u: 1, d: 1, l: 1, r: 0),
    "┬": BoxSpec(u: 0, d: 1, l: 1, r: 1), "┴": BoxSpec(u: 1, d: 0, l: 1, r: 1),
    "┼": BoxSpec(u: 1, d: 1, l: 1, r: 1),
    "═": BoxSpec(u: 0, d: 0, l: 2, r: 2), "║": BoxSpec(u: 2, d: 2, l: 0, r: 0),
    "╔": BoxSpec(u: 0, d: 2, l: 0, r: 2), "╗": BoxSpec(u: 0, d: 2, l: 2, r: 0),
    "╚": BoxSpec(u: 2, d: 0, l: 0, r: 2), "╝": BoxSpec(u: 2, d: 0, l: 2, r: 0),
    "╟": BoxSpec(u: 2, d: 2, l: 0, r: 1), "╢": BoxSpec(u: 2, d: 2, l: 1, r: 0),
    "╤": BoxSpec(u: 0, d: 1, l: 2, r: 2), "╧": BoxSpec(u: 1, d: 0, l: 2, r: 2),
]

// MARK: - View

// `final class` cannot be subclassed, as in Java. `: NSView` names the superclass (≈ `extends JComponent`).
/// The window's only view: paints the `Screen` cell grid and forwards keyboard, mouse and scroll input to the `Commander`.
final class TerminalView: NSView {
    // Starts at 80x25 and is resized to the window by `updateGrid()`. `Screen` is a class, so only the reference is constant.
    let screen = Screen(cols: 80, rows: 25)
    // `weak`: Swift uses reference counting instead of a garbage collector, so a strong reference back from view to
    // controller would form a cycle that is never freed. A weak reference becomes nil when the target goes away, hence optional.
    weak var commander: Commander?
    // `private(set)`: readable from outside, assignable only inside this class (public getter, private setter).
    private(set) var font: NSFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private(set) var fontSize: CGFloat = 16
    // Cell width and cell height in points. Note: here `ch` is the cell height, whereas `Cell.ch` is the character.
    private(set) var cw: CGFloat = 10
    private(set) var ch: CGFloat = 20
    // Extra spacing per glyph, so text advances exactly `cw` per character (`cw` is the glyph width rounded up).
    private var kern: CGFloat = 0
    // Vertical offset that centres the text line in the taller cell.
    private var yOff: CGFloat = 0
    // Text attributes per foreground colour index, cached because `draw` needs them for every text run. `[:]` is an empty dictionary.
    private var attrCache: [UInt8: [NSAttributedString.Key: Any]] = [:]
    // Collects fractional trackpad scroll distances until at least one whole line has accumulated.
    private var scrollAcc: CGFloat = 0
    // Toggled by the controller's 0.5 s timer to make the cursor blink.
    var blinkOn = true

    // Initialiser (constructor). All own stored properties must have values before `super.init` (here through their
    // defaults), and methods of `self` may only be called after it - the reverse of Java's "super() first" rule.
    init(fontSize: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        setFont(fontSize)
    }

    // Required by NSView for loading from Interface Builder files. Not used here, so it deliberately crashes.
    // `init?` is a failable initialiser, one that may return nil.
    required init?(coder: NSCoder) { fatalError("not supported") }

    // `override var` overrides a property of NSView. `{ true }` is a read-only computed property (≈ overriding `boolean isFlipped()`).
    // Flipped coordinates put the origin at the top left with y growing downwards, as in Swing; AppKit's default is bottom left.
    override var isFlipped: Bool { true }
    // Allows the view to receive key events as first responder (≈ `setFocusable(true)`).
    override var acceptsFirstResponder: Bool { true }
    // Promises that `draw` paints every pixel, so AppKit need not draw whatever lies behind the view.
    override var isOpaque: Bool { true }

    /// Switches to a new font size and derives the cell metrics from it. Prefers Menlo, falling back to the system monospaced font.
    func setFont(_ size: CGFloat) {
        fontSize = size
        font = NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        // `as NSString` bridges the Swift String to Foundation's NSString to measure it. `[.font: font]` is an attribute dictionary.
        let adv = ("M" as NSString).size(withAttributes: [.font: font]).width
        // Rounding the advance width up to whole points puts cell edges on pixel boundaries; `kern` makes up the difference.
        cw = ceil(adv)
        kern = cw - adv
        let lh = NSLayoutManager().defaultLineHeight(for: font)
        // Two extra points of spacing between rows.
        ch = ceil(lh) + 2
        yOff = floor((ch - lh) / 2)
        // The cached attributes still contain the old font.
        attrCache = [:]
        updateGrid()
        // Schedules a repaint (≈ `repaint()` in Swing).
        needsDisplay = true
    }

    // `Any` is any value at all, similar to Java's `Object` but including value types.
    /// Text attributes (font, palette colour, kerning) for a foreground colour index, built once per index.
    private func attrs(_ fg: UInt8) -> [NSAttributedString.Key: Any] {
        if let a = attrCache[fg] { return a }
        // Numeric types never convert implicitly in Swift, so the UInt8 index has to be widened with `Int(fg)`.
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dosPalette[Int(fg)], .kern: kern]
        attrCache[fg] = a
        return a
    }

    // Called by AppKit whenever the view is resized (e.g. with the window); recompute how many cells fit.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    /// Fits the cell grid to the view size (at least 60x14 cells) and has the controller redraw if the size changed.
    func updateGrid() {
        // `bounds` is the view's own rectangle. Its width is a `CGFloat`, the floating point type of the graphics APIs; `Int(...)` truncates.
        let c = max(60, Int(bounds.width / cw))
        let r = max(14, Int(bounds.height / ch))
        if c != screen.cols || r != screen.rows {
            screen.resize(cols: c, rows: r)
            // Optional chaining: `?.` calls `render()` only if `commander` is not nil, otherwise it does nothing.
            commander?.render()
        }
    }

    // MARK: Drawing

    // ≈ Swing's `paintComponent`: AppKit calls it when the view needs repainting. `dirtyRect` is ignored and everything is
    // redrawn, in three passes: background runs, glyphs, cursor.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        // Black is colour index 0, the default background.
        bounds.fill()
        let cols = screen.cols, rows = screen.rows

        // Backgrounds, merged into runs, snapped to whole points (no seams)
        // `0..<rows` is a half-open range (0 to rows-1), ≈ `for (int y = 0; y < rows; y++)`. `0...rows` would include `rows`.
        for y in 0..<rows {
            var x = 0
            while x < cols {
                // `screen[x, y]` calls the custom `subscript` defined on Screen, an indexing operator (≈ `screen.get(x, y)`).
                let bg = screen[x, y].bg
                var x2 = x + 1
                // Extend the run while the neighbouring cells have the same background colour.
                while x2 < cols && screen[x2, y].bg == bg { x2 += 1 }
                if bg != 0 {
                    dosPalette[Int(bg)].setFill()
                    // Point coordinates are CGFloat; integers must be converted explicitly.
                    NSRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: CGFloat(x2 - x) * cw, height: ch).fill()
                }
                x = x2
            }
        }

        // Glyphs
        // Glyphs: consecutive ASCII characters of one colour (spaces included) are drawn as one string, which is much faster
        // than drawing character by character; the kerning keeps every character on its cell.
        for y in 0..<rows {
            var x = 0
            let py = CGFloat(y) * ch + yOff
            while x < cols {
                let c = screen[x, y]
                // Spaces need no drawing, the background is already painted. `;` separates several statements on one line.
                if c.ch == " " { x += 1; continue }
                if let spec = boxTable[c.ch] { drawBox(spec, x, y, c.fg); x += 1; continue }
                if c.ch.isASCII {
                    var s = String(c.ch)
                    var x2 = x + 1
                    while x2 < cols {
                        let n = screen[x2, y]
                        // End the run at a non-ASCII character or a colour change; spaces may join any run as they are invisible.
                        // All comma-separated conditions must hold, otherwise the guard's `break` leaves the inner while loop.
                        guard n.ch.isASCII, n.fg == c.fg || n.ch == " " else { break }
                        s.append(n.ch)
                        x2 += 1
                    }
                    (s as NSString).draw(at: NSPoint(x: CGFloat(x) * cw, y: py), withAttributes: attrs(c.fg))
                    x = x2
                // Non-ASCII characters (bullets, arrows, ...) are drawn one by one at their cell, as their advance may differ from `cw`.
                } else {
                    (String(c.ch) as NSString).draw(at: NSPoint(x: CGFloat(x) * cw, y: py), withAttributes: attrs(c.fg))
                    x += 1
                }
            }
        }

        // Underline text cursor, DOS style
        // `screen.cursor` is an optional (x, y) tuple; the cursor is drawn only when set and inside the grid.
        if blinkOn, let cur = screen.cursor, cur.x >= 0, cur.y >= 0, cur.x < cols, cur.y < rows {
            dosPalette[Int(screen[cur.x, cur.y].fg)].setFill()
            // Underline height: 14 % of the cell height, at least 2 points, placed 1 point above the bottom of the cell.
            let h = max(2, round(ch * 0.14))
            NSRect(x: CGFloat(cur.x) * cw, y: CGFloat(cur.y + 1) * ch - h - 1, width: cw, height: h).fill()
        }
    }

    /// Strokes one box-drawing character as lines through the cell centre. A single line runs along the centre; a double
    /// line is two parallel lines, `g` points either side of the centre.
    private func drawBox(_ s: BoxSpec, _ x: Int, _ y: Int, _ fg: UInt8) {
        let x0 = CGFloat(x) * cw, y0 = CGFloat(y) * ch
        let x1 = x0 + cw, y1 = y0 + ch
        // Line width scales with the font size: 1 point for usual sizes, thicker for very large fonts.
        let lw = max(1, round(fontSize / 14))
        // An odd-width line centred on a whole coordinate would straddle two pixels and look blurred; a 0.5 shift puts it on whole pixels.
        let odd = Int(lw) % 2 == 1
        // A nested function: a local helper that can see the enclosing function's variables, much like a capturing lambda.
        // A function body consisting of a single expression returns it implicitly.
        func snap(_ v: CGFloat) -> CGFloat { floor(v) + (odd ? 0.5 : 0) }
        let cx = snap(x0 + cw / 2), cy = snap(y0 + ch / 2)
        // Distance of each stroke of a double line from the centre.
        let g = max(lw + 1, round(cw * 0.18))
        let path = NSBezierPath()
        path.lineWidth = lw
        // Square caps extend each segment by half the line width, so the arms of neighbouring cells overlap without gaps.
        path.lineCapStyle = .square
        func line(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) {
            path.move(to: NSPoint(x: ax, y: ay))
            path.line(to: NSPoint(x: bx, y: by))
        }
        // dv / dh: does the character have double arms vertically / horizontally?
        let dv = s.u == 2 || s.d == 2, dh = s.l == 2 || s.r == 2
        // Single arms only: one line from the centre out to each side that has an arm.
        if !dv && !dh {
            if s.u > 0 { line(cx, y0, cx, cy) }
            if s.d > 0 { line(cx, cy, cx, y1) }
            if s.l > 0 { line(x0, cy, cx, cy) }
            if s.r > 0 { line(cx, cy, x1, cy) }
        // Double in both directions: in `boxTable` only the corners ╔ ╗ ╚ ╝. `sv` / `sh` are the directions of the arms
        // (+1 = down / right, -1 = up / left); the corner is drawn as an outer and an inner L shape.
        } else if dv && dh {
            let sv: CGFloat = s.d == 2 ? 1 : -1, sh: CGFloat = s.r == 2 ? 1 : -1
            let ey = sv > 0 ? y1 : y0, ex = sh > 0 ? x1 : x0
            line(cx - sh * g, cy - sv * g, cx - sh * g, ey)
            line(cx - sh * g, cy - sv * g, ex, cy - sv * g)
            line(cx + sh * g, cy + sv * g, cx + sh * g, ey)
            line(cx + sh * g, cy + sv * g, ex, cy + sv * g)
        // Double vertical (║ ╟ ╢): two vertical lines, plus a single arm attached to the outer stroke on that side.
        } else if dv {
            line(cx - g, y0, cx - g, y1)
            line(cx + g, y0, cx + g, y1)
            if s.r == 1 { line(cx + g, cy, x1, cy) }
            if s.l == 1 { line(x0, cy, cx - g, cy) }
        // Double horizontal (═ ╤ ╧): two horizontal lines, plus a single arm attached from above or below.
        } else {
            line(x0, cy - g, x1, cy - g)
            line(x0, cy + g, x1, cy + g)
            if s.d == 1 { line(cx, cy + g, cx, y1) }
            if s.u == 1 { line(cx, y0, cx, cy - g) }
        }
        dosPalette[Int(fg)].setStroke()
        path.stroke()
    }

    // MARK: Input

    // AppKit calls this for every key press while the view is first responder (≈ `keyPressed` of a Swing KeyListener).
    // Keys that `KeyEvent.from` does not map (it returns nil) are dropped.
    override func keyDown(with e: NSEvent) {
        if let k = KeyEvent.from(e) { commander?.handle(k) }
    }

    // Called when only a modifier key (Shift, Ctrl, Option, Cmd) is pressed or released, e.g. to update the key bar labels.
    override func flagsChanged(with e: NSEvent) {
        commander?.modifiersChanged(e.modifierFlags)
    }

    // The return type `(Int, Int)` is a tuple: an anonymous group of values, no holder class needed.
    /// Converts the mouse position of an event to grid coordinates (column, row).
    private func cellAt(_ e: NSEvent) -> (Int, Int) {
        // `from: nil` means window coordinates; thanks to `isFlipped`, the result has y growing downwards.
        let p = convert(e.locationInWindow, from: nil)
        return (Int(p.x / cw), Int(p.y / ch))
    }

    override func mouseDown(with e: NSEvent) {
        // Destructures the returned tuple into two constants.
        let (x, y) = cellAt(e)
        commander?.mouse(x: x, y: y, right: false, clicks: e.clickCount)
    }

    override func rightMouseDown(with e: NSEvent) {
        let (x, y) = cellAt(e)
        commander?.mouse(x: x, y: y, right: true, clicks: 1)
    }

    // Trackpads deliver precise distances in points, which are converted to lines via the cell height; mouse wheels deliver lines.
    override func scrollWheel(with e: NSEvent) {
        let (x, y) = cellAt(e)
        scrollAcc += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / ch : e.scrollingDeltaY
        // One scroll step per whole accumulated line: positive deltaY becomes step -1 (towards the top), the remainder is kept.
        while abs(scrollAcc) >= 1 {
            let step = scrollAcc > 0 ? -1 : 1
            scrollAcc += scrollAcc > 0 ? -1 : 1
            commander?.scroll(x: x, y: y, delta: step)
        }
    }
}
