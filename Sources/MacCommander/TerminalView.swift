import AppKit

// MARK: - Keys

enum Key: Equatable {
    case char(Character)
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, esc, tab, backspace, delete, insert
    case f(Int)
}

struct KeyEvent {
    var key: Key
    var shift = false
    var ctrl = false
    var alt = false
    var cmd = false

    private static let special: [UInt16: Key] = [
        126: .up, 125: .down, 123: .left, 124: .right, 116: .pageUp, 121: .pageDown,
        115: .home, 119: .end, 36: .enter, 76: .enter, 53: .esc, 48: .tab,
        51: .backspace, 117: .delete, 114: .insert,
        122: .f(1), 120: .f(2), 99: .f(3), 118: .f(4), 96: .f(5), 97: .f(6),
        98: .f(7), 100: .f(8), 101: .f(9), 109: .f(10), 103: .f(11), 111: .f(12),
    ]
    // Physical digit keys -> Cmd+digit acts as F-key (Mac keyboards often lack real F-keys)
    private static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10]

    static func from(_ e: NSEvent) -> KeyEvent? {
        let f = e.modifierFlags
        var ev = KeyEvent(key: .esc)
        ev.shift = f.contains(.shift)
        ev.ctrl = f.contains(.control)
        ev.alt = f.contains(.option)
        ev.cmd = f.contains(.command)
        if let k = special[e.keyCode] { ev.key = k; return ev }
        if ev.cmd, let d = digits[e.keyCode] { ev.key = .f(d); ev.cmd = false; return ev }
        if ev.ctrl || ev.cmd {
            guard let c = (e.charactersIgnoringModifiers ?? "").lowercased().first else { return nil }
            ev.key = .char(c)
            return ev
        }
        guard let c = (e.characters ?? "").first else { return nil }
        if let a = c.asciiValue, a < 32 || a == 127 { return nil }
        ev.key = .char(c)
        ev.alt = false // Option-composed characters (@, |, \, {, … on German layouts) are plain text
        return ev
    }
}

// MARK: - Box drawing

struct BoxSpec { let u, d, l, r: UInt8 }

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

final class TerminalView: NSView {
    let screen = Screen(cols: 80, rows: 25)
    weak var commander: Commander?
    private(set) var font: NSFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private(set) var fontSize: CGFloat = 16
    private(set) var cw: CGFloat = 10
    private(set) var ch: CGFloat = 20
    private var kern: CGFloat = 0
    private var yOff: CGFloat = 0
    private var attrCache: [UInt8: [NSAttributedString.Key: Any]] = [:]
    private var scrollAcc: CGFloat = 0
    private var lastHover = (-1, -1)
    var blinkOn = true

    init(fontSize: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        setFont(fontSize)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func setFont(_ size: CGFloat) {
        fontSize = size
        font = NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let adv = ("M" as NSString).size(withAttributes: [.font: font]).width
        cw = ceil(adv)
        kern = cw - adv
        let lh = NSLayoutManager().defaultLineHeight(for: font)
        ch = ceil(lh) + 2
        yOff = floor((ch - lh) / 2)
        attrCache = [:]
        updateGrid()
        needsDisplay = true
    }

    private func attrs(_ fg: UInt8) -> [NSAttributedString.Key: Any] {
        if let a = attrCache[fg] { return a }
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dosPalette[Int(fg)], .kern: kern]
        attrCache[fg] = a
        return a
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    func updateGrid() {
        let c = max(60, Int(bounds.width / cw))
        let r = max(14, Int(bounds.height / ch))
        if c != screen.cols || r != screen.rows {
            screen.resize(cols: c, rows: r)
            commander?.render()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let cols = screen.cols, rows = screen.rows

        // Backgrounds, merged into runs, snapped to whole points (no seams)
        for y in 0..<rows {
            var x = 0
            while x < cols {
                let bg = screen[x, y].bg
                var x2 = x + 1
                while x2 < cols && screen[x2, y].bg == bg { x2 += 1 }
                if bg != 0 {
                    dosPalette[Int(bg)].setFill()
                    NSRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: CGFloat(x2 - x) * cw, height: ch).fill()
                }
                x = x2
            }
        }

        // Glyphs
        for y in 0..<rows {
            var x = 0
            let py = CGFloat(y) * ch + yOff
            while x < cols {
                let c = screen[x, y]
                if c.ch == " " { x += 1; continue }
                if let spec = boxTable[c.ch] { drawBox(spec, x, y, c.fg); x += 1; continue }
                if c.ch.isASCII {
                    var s = String(c.ch)
                    var x2 = x + 1
                    while x2 < cols {
                        let n = screen[x2, y]
                        guard n.ch.isASCII, n.fg == c.fg || n.ch == " " else { break }
                        s.append(n.ch)
                        x2 += 1
                    }
                    (s as NSString).draw(at: NSPoint(x: CGFloat(x) * cw, y: py), withAttributes: attrs(c.fg))
                    x = x2
                } else {
                    (String(c.ch) as NSString).draw(at: NSPoint(x: CGFloat(x) * cw, y: py), withAttributes: attrs(c.fg))
                    x += 1
                }
            }
        }

        // Underline text cursor, DOS style
        if blinkOn, let cur = screen.cursor, cur.x >= 0, cur.y >= 0, cur.x < cols, cur.y < rows {
            dosPalette[Int(screen[cur.x, cur.y].fg)].setFill()
            let h = max(2, round(ch * 0.14))
            NSRect(x: CGFloat(cur.x) * cw, y: CGFloat(cur.y + 1) * ch - h - 1, width: cw, height: h).fill()
        }
    }

    private func drawBox(_ s: BoxSpec, _ x: Int, _ y: Int, _ fg: UInt8) {
        let x0 = CGFloat(x) * cw, y0 = CGFloat(y) * ch
        let x1 = x0 + cw, y1 = y0 + ch
        let lw = max(1, round(fontSize / 14))
        let odd = Int(lw) % 2 == 1
        func snap(_ v: CGFloat) -> CGFloat { floor(v) + (odd ? 0.5 : 0) }
        let cx = snap(x0 + cw / 2), cy = snap(y0 + ch / 2)
        let g = max(lw + 1, round(cw * 0.18))
        let path = NSBezierPath()
        path.lineWidth = lw
        path.lineCapStyle = .square
        func line(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) {
            path.move(to: NSPoint(x: ax, y: ay))
            path.line(to: NSPoint(x: bx, y: by))
        }
        let dv = s.u == 2 || s.d == 2, dh = s.l == 2 || s.r == 2
        if !dv && !dh {
            if s.u > 0 { line(cx, y0, cx, cy) }
            if s.d > 0 { line(cx, cy, cx, y1) }
            if s.l > 0 { line(x0, cy, cx, cy) }
            if s.r > 0 { line(cx, cy, x1, cy) }
        } else if dv && dh {
            let sv: CGFloat = s.d == 2 ? 1 : -1, sh: CGFloat = s.r == 2 ? 1 : -1
            let ey = sv > 0 ? y1 : y0, ex = sh > 0 ? x1 : x0
            line(cx - sh * g, cy - sv * g, cx - sh * g, ey)
            line(cx - sh * g, cy - sv * g, ex, cy - sv * g)
            line(cx + sh * g, cy + sv * g, cx + sh * g, ey)
            line(cx + sh * g, cy + sv * g, ex, cy + sv * g)
        } else if dv {
            line(cx - g, y0, cx - g, y1)
            line(cx + g, y0, cx + g, y1)
            if s.r == 1 { line(cx + g, cy, x1, cy) }
            if s.l == 1 { line(x0, cy, cx - g, cy) }
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

    override func keyDown(with e: NSEvent) {
        if let k = KeyEvent.from(e) { commander?.handle(k) }
    }

    override func flagsChanged(with e: NSEvent) {
        commander?.modifiersChanged(e.modifierFlags)
    }

    private func cellAt(_ e: NSEvent) -> (Int, Int) {
        let p = convert(e.locationInWindow, from: nil)
        return (Int(p.x / cw), Int(p.y / ch))
    }

    override func mouseDown(with e: NSEvent) {
        let (x, y) = cellAt(e)
        commander?.mouse(x: x, y: y, right: false, clicks: e.clickCount)
    }

    override func mouseMoved(with e: NSEvent) {
        let (x, y) = cellAt(e)
        guard x != lastHover.0 || y != lastHover.1 else { return }
        lastHover = (x, y)
        commander?.hover(x: x, y: y)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func rightMouseDown(with e: NSEvent) {
        let (x, y) = cellAt(e)
        commander?.mouse(x: x, y: y, right: true, clicks: 1)
    }

    override func scrollWheel(with e: NSEvent) {
        let (x, y) = cellAt(e)
        scrollAcc += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / ch : e.scrollingDeltaY
        while abs(scrollAcc) >= 1 {
            let step = scrollAcc > 0 ? -1 : 1
            scrollAcc += scrollAcc > 0 ? -1 : 1
            commander?.scroll(x: x, y: y, delta: step)
        }
    }
}
