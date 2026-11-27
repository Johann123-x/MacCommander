import AppKit

protocol Layer: AnyObject {
    /// Full-screen layers (viewer, editor) hide everything underneath.
    var fullScreen: Bool { get }
    func render(_ s: Screen)
    func handle(_ e: KeyEvent)
    /// Mouse click in screen cells (only the topmost layer receives it).
    func mouse(x: Int, y: Int, right: Bool, clicks: Int)
    /// Mouse moved (no button) – used for hover highlighting in menus.
    func hover(x: Int, y: Int)
}

extension Layer {
    func mouse(x: Int, y: Int, right: Bool, clicks: Int) {}
    func hover(x: Int, y: Int) {}
}

// MARK: - Single line input

struct LineEdit {
    var chars: [Character] = []
    var pos = 0

    var text: String {
        get { String(chars) }
        set { chars = Array(newValue); pos = chars.count }
    }
    var isEmpty: Bool { chars.isEmpty }

    mutating func insert(_ s: String) {
        for c in s where c != "\n" && c != "\r" && c != "\r\n" {
            chars.insert(c, at: pos)
            pos += 1
        }
    }

    @discardableResult
    mutating func handle(_ e: KeyEvent) -> Bool {
        switch e.key {
        case .left: pos = max(0, pos - 1)
        case .right: pos = min(chars.count, pos + 1)
        case .home: pos = 0
        case .end: pos = chars.count
        case .backspace: if pos > 0 { chars.remove(at: pos - 1); pos -= 1 }
        case .delete: if pos < chars.count { chars.remove(at: pos) }
        case .char(let c):
            if e.cmd && c == "v" { insert(NSPasteboard.general.string(forType: .string) ?? ""); return true }
            if e.ctrl && c == "y" { text = ""; return true }
            if e.ctrl || e.cmd { return false }
            insert(String(c))
        default: return false
        }
        return true
    }

    /// Draws the field and returns the cursor column.
    func render(_ s: Screen, x: Int, y: Int, w: Int, fg: UInt8, bg: UInt8) -> Int {
        guard w > 1 else { return x }
        let start = max(0, pos - w + 1)
        let vis = String(chars[start..<min(chars.count, start + w)])
        s.text(x, y, fit(vis, w), fg, bg)
        return x + pos - start
    }
}

// MARK: - Dialog box

final class Dialog: Layer {
    unowned let cmd: Commander
    let title: String
    let lines: [String]
    var input: LineEdit?
    let buttons: [String]
    let danger: Bool
    var focus: Int
    let completion: (Int, String) -> Void
    private var buttonRects: [(x: Int, y: Int, w: Int)] = []
    private var inputRow: (x: Int, y: Int, w: Int)?
    var fullScreen: Bool { false }

    func mouse(x: Int, y: Int, right: Bool, clicks: Int) {
        if let i = buttonRects.firstIndex(where: { y == $0.y && x >= $0.x && x < $0.x + $0.w }) {
            focus = i
            finish(i)
        } else if let r = inputRow, y == r.y, x >= r.x, x < r.x + r.w {
            focus = -1
        }
    }

    init(_ cmd: Commander, title: String, lines: [String], input: String? = nil, buttons: [String],
         danger: Bool = false, completion: @escaping (Int, String) -> Void = { _, _ in }) {
        self.cmd = cmd
        self.title = title
        self.lines = lines
        self.buttons = buttons
        self.danger = danger
        self.completion = completion
        if let i = input { var le = LineEdit(); le.text = i; self.input = le }
        focus = input == nil ? 0 : -1
    }

    func render(_ s: Screen) {
        let bg = danger ? Col.red : Col.gray
        let fg = danger ? Col.white : Col.black
        let btnW = buttons.reduce(0) { $0 + $1.count + 4 } + max(0, buttons.count - 1)
        var inner = max(title.count + 4, btnW, lines.map { $0.count }.max() ?? 0)
        if input != nil { inner = max(inner, 52) }
        inner = min(inner, s.cols - 12)
        let w = inner + 8
        let h = lines.count + (input == nil ? 0 : 1) + 6
        let x = (s.cols - w) / 2, y = max(0, (s.rows - h) / 2 - 1)
        s.fill(x, y, w, h, fg, bg)
        s.shadow(x, y, w, h)
        s.box(x + 2, y + 1, w - 4, h - 2, Col.white, bg)
        let t = " \(title) "
        s.text(x + (w - t.count) / 2, y + 1, t, Col.white, bg)
        var yy = y + 2
        for l in lines {
            s.text(x + 4, yy, fit(l, inner, input == nil ? .center : .left), fg, bg)
            yy += 1
        }
        inputRow = nil
        if let inp = input {
            inputRow = (x + 4, yy, inner)
            let cx = inp.render(s, x: x + 4, y: yy, w: inner, fg: Col.black, bg: Col.cyan)
            if focus == -1 { s.cursor = (cx, yy) }
            yy += 1
        }
        yy += 1
        var bx = x + (w - btnW) / 2
        buttonRects = []
        for (i, b) in buttons.enumerated() {
            let label = "[ \(b) ]"
            buttonRects.append((bx, yy, label.count))
            let on = i == focus
            s.text(bx, yy, label, on ? Col.black : fg, on ? Col.cyan : bg)
            bx += label.count + 1
        }
    }

    func handle(_ e: KeyEvent) {
        switch e.key {
        case .esc: finish(-1)
        case .enter: finish(focus < 0 ? 0 : focus)
        case .tab:
            let order = (input != nil ? [-1] : []) + Array(buttons.indices)
            if let i = order.firstIndex(of: focus) {
                focus = order[(i + (e.shift ? order.count - 1 : 1)) % order.count]
            }
        case .left where focus >= 0: focus = max(0, focus - 1)
        case .right where focus >= 0: focus = min(buttons.count - 1, focus + 1)
        default:
            if focus == -1 {
                input?.handle(e)
            } else if case .char(let c) = e.key,
                      let i = buttons.firstIndex(where: { $0.lowercased().first == c.lowercased().first }) {
                finish(i)
            }
        }
    }

    private func finish(_ i: Int) {
        cmd.pop(self)
        completion(i, input?.text ?? "")
    }
}

// MARK: - Selection list popup

final class ListPopup: Layer {
    unowned let cmd: Commander
    let title: String
    let items: [String]
    var sel = 0
    var top = 0
    var centerX: Int?
    let onSelect: (Int) -> Void
    private var frame = (x: 0, y: 0, w: 0, vis: 0)
    var fullScreen: Bool { false }

    private func row(atX x: Int, y: Int) -> Int? {
        let r = y - frame.y - 1
        guard x > frame.x, x < frame.x + frame.w - 1, r >= 0, r < frame.vis, top + r < items.count else { return nil }
        return top + r
    }

    func mouse(x: Int, y: Int, right: Bool, clicks: Int) {
        if let i = row(atX: x, y: y) {
            sel = i
            cmd.pop(self)
            onSelect(i)
        } else if x < frame.x || x >= frame.x + frame.w || y < frame.y || y > frame.y + frame.vis + 1 {
            cmd.pop(self) // click outside closes
        }
    }

    func hover(x: Int, y: Int) {
        if let i = row(atX: x, y: y) { sel = i }
    }

    init(_ cmd: Commander, title: String, items: [String], onSelect: @escaping (Int) -> Void) {
        self.cmd = cmd
        self.title = title
        self.items = items
        self.onSelect = onSelect
    }

    func render(_ s: Screen) {
        guard !items.isEmpty else { return }
        let w = min(s.cols - 4, max(title.count + 8, (items.map { $0.count }.max() ?? 0) + 4))
        let vis = min(items.count, s.rows - 6)
        let h = vis + 2
        let x = centerX.map { max(0, min(s.cols - w - 2, $0 - w / 2)) } ?? (s.cols - w) / 2
        let y = max(1, (s.rows - 2 - h) / 2)
        if sel < top { top = sel }
        if sel >= top + vis { top = sel - vis + 1 }
        frame = (x, y, w, vis)
        s.fill(x, y, w, h, Col.black, Col.cyan)
        s.shadow(x, y, w, h)
        s.box(x, y, w, h, Col.black, Col.cyan)
        let t = " \(title) "
        s.text(x + (w - t.count) / 2, y, t, Col.black, Col.cyan)
        for r in 0..<vis {
            let i = top + r
            let on = i == sel
            s.text(x + 1, y + 1 + r, fit(" " + items[i], w - 2), on ? Col.white : Col.black, on ? Col.black : Col.cyan)
        }
        s.cursor = nil
    }

    func handle(_ e: KeyEvent) {
        switch e.key {
        case .up: sel = max(0, sel - 1)
        case .down: sel = min(items.count - 1, sel + 1)
        case .pageUp: sel = max(0, sel - 10)
        case .pageDown: sel = min(items.count - 1, sel + 10)
        case .home: sel = 0
        case .end: sel = items.count - 1
        case .enter: cmd.pop(self); onSelect(sel)
        case .esc, .f(10): cmd.pop(self)
        default: break
        }
    }
}

// MARK: - Scrollable text box (help, info)

final class TextBox: Layer {
    unowned let cmd: Commander
    let title: String
    let lines: [String]
    var top = 0
    var fullScreen: Bool { false }

    init(_ cmd: Commander, title: String, lines: [String]) {
        self.cmd = cmd
        self.title = title
        self.lines = lines
    }

    private var visRows = 10

    func render(_ s: Screen) {
        let w = min(s.cols - 4, (lines.map { $0.count }.max() ?? 20) + 6)
        visRows = min(lines.count, s.rows - 5)
        let h = visRows + 2
        let x = (s.cols - w) / 2, y = max(0, (s.rows - 1 - h) / 2)
        top = max(0, min(top, lines.count - visRows))
        s.fill(x, y, w, h, Col.black, Col.cyan)
        s.shadow(x, y, w, h)
        s.box(x, y, w, h, Col.black, Col.cyan)
        let t = " \(title) "
        s.text(x + (w - t.count) / 2, y, t, Col.black, Col.cyan)
        for r in 0..<visRows {
            let l = lines[top + r]
            s.text(x + 2, y + 1 + r, fit(l, w - 4), l.hasSuffix(":") ? Col.yellow : Col.black, Col.cyan)
        }
        if lines.count > visRows {
            s.text(x + w - 12, y + h - 1, " ↑↓ more ", Col.black, Col.cyan)
        }
        s.cursor = nil
    }

    func handle(_ e: KeyEvent) {
        switch e.key {
        case .up: top -= 1
        case .down: top += 1
        case .pageUp: top -= visRows
        case .pageDown: top += visRows
        case .home: top = 0
        case .end: top = lines.count
        default: cmd.pop(self)
        }
        top = max(0, min(top, max(0, lines.count - visRows)))
    }
}

// MARK: - Progress box for background jobs

final class ProgressBox: Layer {
    unowned let cmd: Commander
    let title: String
    var message = ""
    var detail = ""
    var fraction: Double = -1
    var cancelled = false
    var fullScreen: Bool { false }

    init(_ cmd: Commander, title: String) {
        self.cmd = cmd
        self.title = title
    }

    func render(_ s: Screen) {
        let w = min(s.cols - 6, 60), h = 8
        let x = (s.cols - w) / 2, y = (s.rows - h) / 2 - 1
        s.fill(x, y, w, h, Col.black, Col.gray)
        s.shadow(x, y, w, h)
        s.box(x + 2, y + 1, w - 4, h - 2, Col.white, Col.gray)
        let t = " \(title) "
        s.text(x + (w - t.count) / 2, y + 1, t, Col.white, Col.gray)
        s.text(x + 4, y + 2, fit(message, w - 8), Col.black, Col.gray)
        s.text(x + 4, y + 3, fit(fitTail(detail, w - 8), w - 8), Col.black, Col.gray)
        if fraction >= 0 {
            let bw = w - 8
            let filled = Int(Double(bw) * min(1, fraction))
            s.text(x + 4, y + 5, String(repeating: "█", count: filled) + String(repeating: "░", count: bw - filled), Col.cyan, Col.gray)
        } else {
            s.text(x + 4, y + 5, fit(cancelled ? "Cancelling…" : "Esc to cancel", w - 8, .center), Col.dgray, Col.gray)
        }
        s.cursor = nil
    }

    func handle(_ e: KeyEvent) {
        if case .esc = e.key { cancelled = true }
    }
}

// MARK: - Quick search (Ctrl-S)

final class QuickSearch: Layer {
    unowned let cmd: Commander
    let panel: Panel
    let px: Int
    let pw: Int
    var text = ""
    var fullScreen: Bool { false }

    init(_ cmd: Commander, panel: Panel, px: Int, pw: Int) {
        self.cmd = cmd
        self.panel = panel
        self.px = px
        self.pw = pw
    }

    func render(_ s: Screen) {
        let w = min(pw - 4, 34), x = px + 2, y = s.rows - 5
        s.fill(x, y, w, 3, Col.black, Col.cyan)
        s.box(x, y, w, 3, Col.black, Col.cyan)
        s.text(x + 2, y + 1, "Search:", Col.black, Col.cyan)
        let fx = x + 10, fw = w - 12
        s.text(fx, y + 1, fit(String(text.suffix(fw - 1)), fw), Col.black, Col.gray)
        s.cursor = (fx + min(text.count, fw - 1), y + 1)
    }

    func handle(_ e: KeyEvent) {
        switch e.key {
        case .char(let c) where !e.ctrl && !e.cmd:
            let t = (text + String(c)).lowercased()
            if let i = panel.entries.firstIndex(where: { !$0.isUp && $0.name.lowercased().hasPrefix(t) }) {
                text.append(c)
                panel.cursor = i
            } else {
                NSSound.beep()
            }
        case .backspace:
            if !text.isEmpty { text.removeLast() }
        case .esc:
            cmd.pop(self)
        default:
            cmd.pop(self)
            cmd.handleBase(e)
        }
    }
}

// MARK: - Pull-down menu (F9)

struct MenuItem {
    var title: String
    var hint: String = ""
    var action: (() -> Void)? = nil
    var checked: (() -> Bool)? = nil
    static let sep = MenuItem(title: "")
    var isSep: Bool { title.isEmpty }
}

final class PulldownMenu: Layer {
    unowned let cmd: Commander
    let menus: [(String, [MenuItem])]
    var cur: Int
    var sel = 0
    private var bar: [(x: Int, w: Int)] = []
    private var box = (x: 0, y: 0, w: 0, h: 0)
    var fullScreen: Bool { false }

    private func item(atX x: Int, y: Int) -> Int? {
        let i = y - box.y - 1
        guard x > box.x, x < box.x + box.w - 1, i >= 0, i < items.count, !items[i].isSep else { return nil }
        return i
    }

    func mouse(x: Int, y: Int, right: Bool, clicks: Int) {
        if y == 0 {
            if let i = bar.firstIndex(where: { x >= $0.x && x < $0.x + $0.w }) {
                if i == cur { cmd.pop(self) } else { cur = i; sel = firstSelectable() }
            } else {
                cmd.pop(self)
            }
        } else if let i = item(atX: x, y: y) {
            activate(i)
        } else if !(x >= box.x && x < box.x + box.w && y >= box.y && y < box.y + box.h) {
            cmd.pop(self) // click outside the menu closes it
        }
    }

    func hover(x: Int, y: Int) {
        if y == 0, let i = bar.firstIndex(where: { x >= $0.x && x < $0.x + $0.w }), i != cur {
            cur = i; sel = firstSelectable()
        } else if let i = item(atX: x, y: y) {
            sel = i
        }
    }

    init(_ cmd: Commander, menus: [(String, [MenuItem])], cur: Int) {
        self.cmd = cmd
        self.menus = menus
        self.cur = cur
        sel = firstSelectable()
    }

    private var items: [MenuItem] { menus[cur].1 }
    private func firstSelectable() -> Int { menus[cur].1.firstIndex { !$0.isSep } ?? 0 }

    func render(_ s: Screen) {
        s.fill(0, 0, s.cols, 1, Col.black, Col.cyan)
        var x = 2
        var xs: [Int] = []
        bar = []
        for (i, m) in menus.enumerated() {
            let lbl = " \(m.0) "
            xs.append(x)
            bar.append((x, lbl.count))
            s.text(x, 0, lbl, i == cur ? Col.white : Col.black, i == cur ? Col.black : Col.cyan)
            x += lbl.count + 3
        }
        let w = (items.map { $0.title.count + ($0.hint.isEmpty ? 0 : $0.hint.count + 3) }.max() ?? 10) + 6
        let h = items.count + 2
        let bx = max(0, min(s.cols - w - 2, xs[cur] - 1)), by = 1
        box = (bx, by, w, h)
        s.fill(bx, by, w, h, Col.black, Col.cyan)
        s.shadow(bx, by, w, h)
        s.box(bx, by, w, h, Col.black, Col.cyan)
        for (i, it) in items.enumerated() {
            let yy = by + 1 + i
            if it.isSep {
                s.put(bx, yy, "╟", Col.black, Col.cyan)
                for xx in (bx + 1)..<(bx + w - 1) { s.put(xx, yy, "─", Col.black, Col.cyan) }
                s.put(bx + w - 1, yy, "╢", Col.black, Col.cyan)
                continue
            }
            let on = i == sel
            let f = on ? Col.white : Col.black, b = on ? Col.black : Col.cyan
            s.fill(bx + 1, yy, w - 2, 1, f, b)
            if it.checked?() == true { s.put(bx + 1, yy, "√", f, b) }
            s.text(bx + 2, yy, it.title, f, b)
            if !it.hint.isEmpty { s.text(bx + w - 2 - it.hint.count, yy, it.hint, f, b) }
        }
        s.cursor = nil
    }

    func handle(_ e: KeyEvent) {
        switch e.key {
        case .left: cur = (cur + menus.count - 1) % menus.count; sel = firstSelectable()
        case .right: cur = (cur + 1) % menus.count; sel = firstSelectable()
        case .up: move(-1)
        case .down: move(1)
        case .home: sel = firstSelectable()
        case .enter: activate(sel)
        case .esc, .f(9), .f(10): cmd.pop(self)
        case .char(let c):
            if let i = items.firstIndex(where: { !$0.isSep && $0.title.lowercased().first == c.lowercased().first }) {
                activate(i)
            }
        default: break
        }
    }

    private func move(_ d: Int) {
        let n = items.count
        var i = sel
        repeat { i = (i + d + n) % n } while items[i].isSep
        sel = i
    }

    private func activate(_ i: Int) {
        let it = items[i]
        guard !it.isSep else { return }
        cmd.pop(self)
        it.action?()
    }
}
