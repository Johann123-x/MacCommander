import AppKit

// A protocol is Swift's interface. `: AnyObject` restricts it to classes, so layers have identity and
// `Commander.pop` can remove one from the stack by reference (`===`, like Java `==` on objects).
/// A modal overlay (dialog, list, menu, viewer, editor) on the `Commander.layers` stack. Layers are drawn
/// bottom to top over the panels on every redraw; only the top layer receives keys.
protocol Layer: AnyObject {
    // `{ get }`: implementers must provide a readable property; a computed one is fine.
    /// Full-screen layers (viewer, editor) hide everything underneath.
    var fullScreen: Bool { get }
    /// Draws the layer into the grid on every redraw; set `s.cursor` to show a text cursor.
    func render(_ s: Screen)
    /// Reacts to a key press while this layer is on top.
    func handle(_ e: KeyEvent)
}

// MARK: - Single line input

// `struct` = value type, copied on assignment; every holder owns its own independent copy.
/// Editing state of a one-line text field (characters plus cursor position), used by `Dialog`
/// and by the command line below the panels.
struct LineEdit {
    // An array of `Character`s rather than a String, because Swift strings cannot be indexed by Int;
    // the array makes inserting and deleting at the cursor simple.
    var chars: [Character] = []
    // Cursor index into `chars` (0...chars.count); the type `Int` is inferred.
    var pos = 0

    // A computed property with getter and setter (like getText/setText, but used as `edit.text = "x"`).
    // `newValue` is the implicit name of the assigned value. Setting the text moves the cursor to the end.
    var text: String {
        get { String(chars) }
        set { chars = Array(newValue); pos = chars.count }
    }
    var isEmpty: Bool { chars.isEmpty }

    // `mutating` marks a struct method that changes the struct's fields; it cannot be called on a `let` value.
    /// Inserts text at the cursor, dropping line breaks (e.g. from pasted text).
    mutating func insert(_ s: String) {
        // `for ... where` filters the loop. "\r\n" is a single Character in Swift (one grapheme cluster).
        for c in s where c != "\n" && c != "\r" && c != "\r\n" {
            chars.insert(c, at: pos)
            pos += 1
        }
    }

    /// Applies an editing key. Returns false if the key is not meant for the field, so the caller can use it.
    @discardableResult
    mutating func handle(_ e: KeyEvent) -> Bool {
        // `switch` over the `Key` enum; cases do not fall through, so no `break` is needed.
        switch e.key {
        case .left: pos = max(0, pos - 1)
        case .right: pos = min(chars.count, pos + 1)
        case .home: pos = 0
        case .end: pos = chars.count
        case .backspace: if pos > 0 { chars.remove(at: pos - 1); pos -= 1 }
        case .delete: if pos < chars.count { chars.remove(at: pos) }
        // `case .char(let c)` matches the enum case and binds its associated value (the typed Character) to `c`.
        case .char(let c):
            // `??` supplies a default when the left side is nil (no text on the pasteboard).
            if e.cmd && c == "v" { insert(NSPasteboard.general.string(forType: .string) ?? ""); return true }
            // Ctrl+Y clears the field.
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
        // Horizontal scrolling: the visible window starts late enough for the cursor to stay inside the field.
        let start = max(0, pos - w + 1)
        // `chars[a..<b]` slices the array (an `ArraySlice`), which is converted back to a String.
        let vis = String(chars[start..<min(chars.count, start + w)])
        s.text(x, y, fit(vis, w), fg, bg)
        return x + pos - start
    }
}

// MARK: - Dialog box

// `final class Dialog: Layer` = a class that cannot be subclassed and implements the `Layer` protocol.
/// A modal message box with an optional input line and a row of buttons. `completion` receives the
/// chosen button index (-1 for Esc) and the input text.
final class Dialog: Layer {
    // `unowned`: a non-owning reference. Swift frees objects by reference counting (ARC), not by a GC, so the
    // Commander (which holds this layer) and the layer must not hold strong references to each other, or
    // neither would ever be freed (a retain cycle). Unlike `weak`, `unowned` is not optional and assumes
    // the Commander outlives the layer.
    unowned let cmd: Commander
    let title: String
    let lines: [String]
    // `LineEdit?` is an optional: nil means the dialog has no input field. The compiler forces a nil check
    // before use, unlike a nullable Java field.
    var input: LineEdit?
    let buttons: [String]
    let danger: Bool
    // Keyboard focus: -1 = input field, 0 and up = button index.
    var focus: Int
    // A function type: a closure taking (button index, input text) and returning nothing (≈ `BiConsumer`).
    let completion: (Int, String) -> Void
    // A read-only computed property; its body `{ false }` returns false.
    var fullScreen: Bool { false }

    // `@escaping`: the closure is stored and called after `init` returns, which must be declared explicitly.
    // The default `{ _, _ in }` is a closure that ignores both arguments and does nothing.
    init(_ cmd: Commander, title: String, lines: [String], input: String? = nil, buttons: [String],
         danger: Bool = false, completion: @escaping (Int, String) -> Void = { _, _ in }) {
        self.cmd = cmd
        self.title = title
        self.lines = lines
        self.buttons = buttons
        self.danger = danger
        self.completion = completion
        // `if let i = input` unwraps the optional parameter. `LineEdit` is a struct, so `le` is configured
        // locally and then copied into `self.input`.
        if let i = input { var le = LineEdit(); le.text = i; self.input = le }
        // Focus starts in the input field if there is one, otherwise on the first button.
        focus = input == nil ? 0 : -1
    }

    /// Draws the dialog centred on screen, sized to fit its title, lines, buttons and input field.
    func render(_ s: Screen) {
        let bg = danger ? Col.red : Col.gray
        let fg = danger ? Col.white : Col.black
        // `reduce` folds the labels into the total button row width: each is "[ title ]" (+4), plus one blank
        // between buttons. `$0` and `$1` are the closure's first and second argument (accumulator, element).
        let btnW = buttons.reduce(0) { $0 + $1.count + 4 } + max(0, buttons.count - 1)
        // `.max()` returns an optional (nil for an empty array), hence `?? 0`.
        var inner = max(title.count + 4, btnW, lines.map { $0.count }.max() ?? 0)
        if input != nil { inner = max(inner, 52) }
        inner = min(inner, s.cols - 12)
        // Outer size: on each side two padding columns, the frame and one blank; vertically a padding row, the
        // frame (carrying the title), the lines, the input line, a blank row, the button row, frame and padding.
        let w = inner + 8
        let h = lines.count + (input == nil ? 0 : 1) + 6
        // `let a = ..., b = ...` declares two constants. Centred and nudged one row up; `max(0, ...)` keeps it on screen.
        let x = (s.cols - w) / 2, y = max(0, (s.rows - h) / 2 - 1)
        s.fill(x, y, w, h, fg, bg)
        s.shadow(x, y, w, h)
        s.box(x + 2, y + 1, w - 4, h - 2, Col.white, bg)
        // `"\(title)"` is string interpolation: the value is inserted into the string literal.
        let t = " \(title) "
        s.text(x + (w - t.count) / 2, y + 1, t, Col.white, bg)
        var yy = y + 2
        for l in lines {
            s.text(x + 4, yy, fit(l, inner, input == nil ? .center : .left), fg, bg)
            yy += 1
        }
        // `if let inp = input` runs only when there is an input field; `inp` is the unwrapped LineEdit.
        if let inp = input {
            let cx = inp.render(s, x: x + 4, y: yy, w: inner, fg: Col.black, bg: Col.cyan)
            // Assigning a tuple; the cursor is only shown while the input field has the focus.
            if focus == -1 { s.cursor = (cx, yy) }
            yy += 1
        }
        yy += 1
        var bx = x + (w - btnW) / 2
        // `enumerated()` yields (index, element) tuples, destructured in the loop header.
        for (i, b) in buttons.enumerated() {
            let label = "[ \(b) ]"
            let on = i == focus
            s.text(bx, yy, label, on ? Col.black : fg, on ? Col.cyan : bg)
            bx += label.count + 1
        }
    }

    /// Esc cancels (-1), Enter confirms the focused button (button 0 from the input field), Tab and
    /// Shift+Tab cycle the focus, Left/Right move between buttons, and a letter picks the button starting with it.
    func handle(_ e: KeyEvent) {
        switch e.key {
        case .esc: finish(-1)
        case .enter: finish(focus < 0 ? 0 : focus)
        case .tab:
            // The focus ring: the input field (-1, if present) followed by all button indices.
            // `Array(buttons.indices)` turns the range 0..<count into an array so the two can be concatenated.
            let order = (input != nil ? [-1] : []) + Array(buttons.indices)
            if let i = order.firstIndex(of: focus) {
                // Shift+Tab moves backwards: adding count - 1 is -1 modulo count without going negative.
                focus = order[(i + (e.shift ? order.count - 1 : 1)) % order.count]
            }
        // `case ... where cond` matches only if the extra condition holds; otherwise later cases are tried.
        case .left where focus >= 0: focus = max(0, focus - 1)
        case .right where focus >= 0: focus = min(buttons.count - 1, focus + 1)
        default:
            if focus == -1 {
                // Optional chaining: `handle` runs only if `input` is non-nil; as `input` is a `var` struct it is mutated in place.
                input?.handle(e)
            // `if case .char(let c) = e.key` is pattern matching outside a `switch`: true only for a typed character.
            // The comma adds a further condition; `where:` takes a closure as predicate (like a Java `Predicate`).
            } else if case .char(let c) = e.key,
                      let i = buttons.firstIndex(where: { $0.lowercased().first == c.lowercased().first }) {
                finish(i)
            }
        }
    }

    /// Removes the dialog from the layer stack, then reports the result to the completion closure.
    private func finish(_ i: Int) {
        cmd.pop(self)
        completion(i, input?.text ?? "")
    }
}

// MARK: - Selection list popup

/// A list popup to pick one entry from (locations, user menu, history, search results).
/// `onSelect` receives the chosen index; Esc closes the popup without calling it.
final class ListPopup: Layer {
    unowned let cmd: Commander
    let title: String
    let items: [String]
    var sel = 0
    var top = 0
    // When set, the popup is centred horizontally on this column (Commander uses the centre of a panel).
    var centerX: Int?
    let onSelect: (Int) -> Void
    var fullScreen: Bool { false }

    // `@escaping`: `onSelect` is stored and called after `init` returns.
    init(_ cmd: Commander, title: String, items: [String], onSelect: @escaping (Int) -> Void) {
        self.cmd = cmd
        self.title = title
        self.items = items
        self.onSelect = onSelect
    }

    /// Draws the visible part of the list, scrolling `top` so the selection stays visible.
    func render(_ s: Screen) {
        guard !items.isEmpty else { return }
        let w = min(s.cols - 4, max(title.count + 8, (items.map { $0.count }.max() ?? 0) + 4))
        let vis = min(items.count, s.rows - 6)
        let h = vis + 2
        // `Optional.map`: if `centerX` is set, centre on it, clamped to the screen; otherwise (`??`) centre on screen.
        let x = centerX.map { max(0, min(s.cols - w - 2, $0 - w / 2)) } ?? (s.cols - w) / 2
        // Vertically centred between the top row and the key bar.
        let y = max(1, (s.rows - 2 - h) / 2)
        // Scrolling is adjusted while rendering; there is no separate layout step.
        if sel < top { top = sel }
        if sel >= top + vis { top = sel - vis + 1 }
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

    /// Arrow keys, PgUp/PgDn, Home/End move the selection; Enter picks, Esc or F10 cancel.
    func handle(_ e: KeyEvent) {
        switch e.key {
        case .up: sel = max(0, sel - 1)
        case .down: sel = min(items.count - 1, sel + 1)
        case .pageUp: sel = max(0, sel - 10)
        case .pageDown: sel = min(items.count - 1, sel + 10)
        case .home: sel = 0
        case .end: sel = items.count - 1
        case .enter: cmd.pop(self); onSelect(sel)
        // Several patterns in one case, like stacked `case A: case B:` labels in Java.
        case .esc, .f(10): cmd.pop(self)
        default: break
        }
    }
}

// MARK: - Scrollable text box (help, info)

/// A scrollable read-only text window for help and information. Lines ending in ":" are shown as yellow headings.
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

    // Number of visible rows, updated by `render` and used by `handle` for paging.
    // Member order does not matter in Swift, so this stored property may follow `init`.
    private var visRows = 10

    func render(_ s: Screen) {
        let w = min(s.cols - 4, (lines.map { $0.count }.max() ?? 20) + 6)
        visRows = min(lines.count, s.rows - 5)
        let h = visRows + 2
        let x = (s.cols - w) / 2, y = max(0, (s.rows - 1 - h) / 2)
        // Clamp the scroll offset, e.g. after the window was resized.
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
        // Jumps past the end; the clamp below turns it into the last page.
        case .end: top = lines.count
        // Any other key closes the box.
        default: cmd.pop(self)
        }
        top = max(0, min(top, max(0, lines.count - visRows)))
    }
}

// MARK: - Progress box for background jobs

/// Modal progress display for a background job (copy, move, delete, find, directory size). The job
/// updates `message`, `detail` and `fraction` and polls `cancelled`, which Esc sets.
final class ProgressBox: Layer {
    unowned let cmd: Commander
    let title: String
    var message = ""
    var detail = ""
    // Progress 0...1, or negative when unknown (then a hint is shown instead of a bar).
    var fraction: Double = -1
    var cancelled = false
    var fullScreen: Bool { false }

    init(_ cmd: Commander, title: String) {
        self.cmd = cmd
        self.title = title
    }

    func render(_ s: Screen) {
        // With a progress bar the box is one row taller, so the cancel hint fits below the bar.
        let w = min(s.cols - 6, 60), h = fraction >= 0 ? 9 : 8
        let x = (s.cols - w) / 2, y = (s.rows - h) / 2 - 1
        s.fill(x, y, w, h, Col.black, Col.gray)
        s.shadow(x, y, w, h)
        s.box(x + 2, y + 1, w - 4, h - 2, Col.white, Col.gray)
        let t = " \(title) "
        s.text(x + (w - t.count) / 2, y + 1, t, Col.white, Col.gray)
        s.text(x + 4, y + 2, fit(message, w - 8), Col.black, Col.gray)
        // `fitTail` keeps the end of a long path, `fit` then pads it to the full width.
        s.text(x + 4, y + 3, fit(fitTail(detail, w - 8), w - 8), Col.black, Col.gray)
        if fraction >= 0 {
            let bw = w - 8
            // `Int(...)`/`Double(...)` are explicit conversions; Swift never converts between number types implicitly.
            let filled = Int(Double(bw) * min(1, fraction))
            s.text(x + 4, y + 5, String(repeating: "█", count: filled) + String(repeating: "░", count: bw - filled), Col.cyan, Col.gray)
        }
        let hint = fit(cancelled ? "Cancelling…" : "Esc to cancel", w - 8, .center)
        s.text(x + 4, fraction >= 0 ? y + 6 : y + 5, hint, Col.dgray, Col.gray)
        s.cursor = nil
    }

    func handle(_ e: KeyEvent) {
        // `if case .esc = e.key` tests for a single enum case without a `switch`.
        if case .esc = e.key { cancelled = true }
    }
}

// MARK: - Quick search (Ctrl-S)

/// The quick-search box (Ctrl-S): typing jumps the panel cursor to the first entry starting with the typed text.
final class QuickSearch: Layer {
    unowned let cmd: Commander
    let panel: Panel
    // `px`/`pw`: left column and width of the panel the box is drawn into.
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
        // `fx`/`fw`: column and width of the input field after the "Search:" label.
        let fx = x + 10, fw = w - 12
        // Shows only the end of long input so the cursor stays inside the field.
        s.text(fx, y + 1, fit(String(text.suffix(fw - 1)), fw), Col.black, Col.gray)
        s.cursor = (fx + min(text.count, fw - 1), y + 1)
    }

    func handle(_ e: KeyEvent) {
        switch e.key {
        // `where` restricts the case to characters typed without Ctrl or Cmd.
        case .char(let c) where !e.ctrl && !e.cmd:
            let t = (text + String(c)).lowercased()
            // The ".." entry is skipped. A character that would match nothing is rejected with a beep,
            // so `text` always matches an entry.
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
        // Any other key closes the search and is passed on to the normal panel key handling.
        default:
            cmd.pop(self)
            cmd.handleBase(e)
        }
    }
}

// MARK: - Pull-down menu (F9)

/// One entry of a pull-down menu: title, shortcut hint, the action to run and an optional check-mark
/// state. An empty title marks a separator line.
struct MenuItem {
    var title: String
    var hint: String = ""
    // An optional closure: `(() -> Void)?` is a function without parameters and result, or nil.
    var action: (() -> Void)? = nil
    // Evaluated on every redraw, so the check mark always reflects the current setting.
    var checked: (() -> Bool)? = nil
    // `static let`: a type-level constant (Java `static final`), used as `MenuItem.sep` or just `.sep`.
    static let sep = MenuItem(title: "")
    var isSep: Bool { title.isEmpty }
}

/// The F9 pull-down menu: the menu titles on the top row and the open menu dropped down below the current one.
final class PulldownMenu: Layer {
    unowned let cmd: Commander
    // An array of tuples (menu title, items); tuple elements are accessed as `.0` and `.1`.
    let menus: [(String, [MenuItem])]
    var cur: Int
    var sel = 0
    var fullScreen: Bool { false }

    init(_ cmd: Commander, menus: [(String, [MenuItem])], cur: Int) {
        self.cmd = cmd
        self.menus = menus
        self.cur = cur
        // Every stored property has a value now, so methods of `self` may be called (Swift enforces this
        // two-phase initialisation at compile time).
        sel = firstSelectable()
    }

    // Computed property: the items of the currently open menu.
    private var items: [MenuItem] { menus[cur].1 }
    // `firstIndex { ... }`: a trailing closure as the only argument, so the parentheses are omitted.
    private func firstSelectable() -> Int { menus[cur].1.firstIndex { !$0.isSep } ?? 0 }

    func render(_ s: Screen) {
        s.fill(0, 0, s.cols, 1, Col.black, Col.cyan)
        var x = 2
        var xs: [Int] = []
        // Menu titles on the top row; `xs` remembers each title's column so the drop-down opens beneath it.
        for (i, m) in menus.enumerated() {
            let lbl = " \(m.0) "
            xs.append(x)
            s.text(x, 0, lbl, i == cur ? Col.white : Col.black, i == cur ? Col.black : Col.cyan)
            x += lbl.count + 3
        }
        // Longest title plus hint (3 blanks apart), plus frame and margins.
        let w = (items.map { $0.title.count + ($0.hint.isEmpty ? 0 : $0.hint.count + 3) }.max() ?? 10) + 6
        let h = items.count + 2
        // Below its title, one column to the left, kept on screen (`- 2` leaves room for the shadow).
        let bx = max(0, min(s.cols - w - 2, xs[cur] - 1)), by = 1
        s.fill(bx, by, w, h, Col.black, Col.cyan)
        s.shadow(bx, by, w, h)
        s.box(bx, by, w, h, Col.black, Col.cyan)
        for (i, it) in items.enumerated() {
            let yy = by + 1 + i
            if it.isSep {
                // Separator: a single line joined to the double frame with "╟" and "╢".
                s.put(bx, yy, "╟", Col.black, Col.cyan)
                for xx in (bx + 1)..<(bx + w - 1) { s.put(xx, yy, "─", Col.black, Col.cyan) }
                s.put(bx + w - 1, yy, "╢", Col.black, Col.cyan)
                continue
            }
            let on = i == sel
            let f = on ? Col.white : Col.black, b = on ? Col.black : Col.cyan
            s.fill(bx + 1, yy, w - 2, 1, f, b)
            // `checked?()` calls the closure only if there is one; the result is `Bool?`, so `== true` treats nil as false.
            if it.checked?() == true { s.put(bx + 1, yy, "√", f, b) }
            s.text(bx + 2, yy, it.title, f, b)
            if !it.hint.isEmpty { s.text(bx + w - 2 - it.hint.count, yy, it.hint, f, b) }
        }
        s.cursor = nil
    }

    func handle(_ e: KeyEvent) {
        switch e.key {
        // Left/Right switch to the neighbouring menu with wrap-around; `+ menus.count - 1` avoids a negative remainder.
        case .left: cur = (cur + menus.count - 1) % menus.count; sel = firstSelectable()
        case .right: cur = (cur + 1) % menus.count; sel = firstSelectable()
        case .up: move(-1)
        case .down: move(1)
        case .home: sel = firstSelectable()
        case .enter: activate(sel)
        case .esc, .f(9), .f(10): cmd.pop(self)
        // A letter activates the first item whose title starts with it.
        case .char(let c):
            if let i = items.firstIndex(where: { !$0.isSep && $0.title.lowercased().first == c.lowercased().first }) {
                activate(i)
            }
        default: break
        }
    }

    /// Moves the selection by `d` (-1 or 1) with wrap-around, skipping separators.
    private func move(_ d: Int) {
        let n = items.count
        var i = sel
        // `repeat { ... } while cond` is Swift's do-while loop.
        repeat { i = (i + d + n) % n } while items[i].isSep
        sel = i
    }

    /// Closes the menu and runs the item's action, if any (`action?()` calls the optional closure only if set).
    private func activate(_ i: Int) {
        let it = items[i]
        guard !it.isSep else { return }
        cmd.pop(self)
        it.action?()
    }
}
