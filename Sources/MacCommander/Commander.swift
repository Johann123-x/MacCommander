import AppKit
import Darwin

// `final class` = a Java `final class`: cannot be subclassed. Classes are reference types (like Java
// objects); `struct`s are value types that are copied on assignment. Members without a modifier are
// `internal` (visible in the whole module, roughly Java package-private); `private` = this type only.
/// The application controller: owns both panels, the command line, the console output and the layer
/// stack, routes every key and mouse event and repaints the whole character grid in `render()`.
final class Commander {
    // `let` declares a constant (like a Java `final` field or local), `var` a mutable one.
    let view: TerminalView
    // A computed property: no storage, the `{ ... }` body is a getter run on every access (like `getScreen()`).
    /// The character grid of the view.
    var screen: Screen { view.screen }
    var left: Panel
    var right: Panel
    var active: Panel
    // `===` compares object identity (Java `==` on references); `==` would be value equality (Java `equals`).
    /// The inactive panel.
    var other: Panel { active === left ? right : left }
    /// The command line editor below the panels. `LineEdit` is a struct, so assigning `LineEdit()` resets it.
    var cmd = LineEdit()
    /// Executed command lines, oldest first; `histIdx` is the browse position for Ctrl-E / Ctrl-X.
    var history: [String] = []
    var histIdx = 0
    /// False when Ctrl-O hides the panels to show the console output behind them.
    var panelsOn = true
    /// Completed console output lines; `consolePartial` is the current line not yet ended by a newline.
    var console: [String] = []
    var consolePartial = ""
    /// Popups, menus, viewer and editor; the last element is the top layer and receives the keys.
    var layers: [Layer] = []
    var showClock = true
    // `Process?` is an optional: the value is either a `Process` or `nil`. Non-optional types can never be
    // nil, so the compiler forces a check before use (a compile-time version of Java's `Optional`/null).
    /// The shell command currently running, or nil.
    var running: Process?
    // A tuple with named elements: a lightweight anonymous value type, accessed as `mods.alt`.
    /// Modifier keys currently held, used to swap the key bar labels.
    var mods = (shift: false, ctrl: false, alt: false)
    private var timer: Timer?
    let home = NSHomeDirectory()

    /// Restores panel paths and options from `UserDefaults` (macOS preferences, like `java.util.prefs`),
    /// registers with the view and starts the 0.5 s repaint timer.
    init(view: TerminalView) {
        self.view = view
        let d = UserDefaults.standard
        // `??` is the nil-coalescing operator: use the left value if not nil, else the right one
        // (like `Optional.orElse`).
        left = Panel(path: d.string(forKey: "leftPath") ?? NSHomeDirectory())
        right = Panel(path: d.string(forKey: "rightPath") ?? NSHomeDirectory() + "/Desktop")
        active = left
        // Iterating over an array of tuples and destructuring each into `p` and `k`.
        for (p, k) in [(left, "left"), (right, "right")] {
            p.showPerms = d.bool(forKey: k + "Perms")
            p.showHidden = d.object(forKey: k + "Hidden") != nil ? d.bool(forKey: k + "Hidden") : d.bool(forKey: "showHidden")
            // `if let m = ...` unwraps an optional: the body runs only if the value is not nil, with `m` bound to it.
            // `flatMap(PanelMode.init)` passes the string to the enum's failable `init(rawValue:)`, which returns nil
            // for an unknown value, so a stale preference is ignored.
            if let m = d.string(forKey: k + "Mode").flatMap(PanelMode.init) { p.mode = m }
            // Setting `sort` reloads the panel (a `didSet` observer in Panel runs after each assignment), hence the `else` branch.
            if let s = d.string(forKey: k + "Sort").flatMap(SortMode.init) { p.sort = s } else { p.reload() }
        }
        if d.object(forKey: "showClock") != nil { showClock = d.bool(forKey: "showClock") }
        if d.string(forKey: "activePanel") == "right" { active = right }
        history = d.stringArray(forKey: "history") ?? []
        histIdx = history.count
        view.commander = self
        console = ["", "MacCommander – a dual-panel file manager for macOS, inspired by Norton Commander",
                   "F1 = Help   F9 = Menu   Cmd-1 … Cmd-0 work as F1 … F10", ""]
        // Trailing-closure syntax: the last argument, a closure (lambda), is written after the parentheses.
        // `[weak self]` is a capture list. Swift uses reference counting (ARC), not a garbage collector, so a
        // closure holding `self` strongly while `self` holds the timer would form a cycle that is never freed.
        // A weak capture makes `self` optional inside the closure. `_ in` ignores the closure's parameter.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // `guard ... else { return }` is an early exit: if the condition fails, the else block must leave the
            // scope. `guard let self` unwraps the weak reference and keeps `self` non-optional for the rest.
            guard let self else { return }
            self.view.blinkOn.toggle()
            self.render()
        }
        render()
    }

    /// Persists panel paths, modes, options, font size and the last 100 history entries to `UserDefaults`.
    func saveState() {
        let d = UserDefaults.standard
        d.set(left.path, forKey: "leftPath")
        d.set(right.path, forKey: "rightPath")
        d.set(left.mode.rawValue, forKey: "leftMode")
        d.set(right.mode.rawValue, forKey: "rightMode")
        d.set(left.sort.rawValue, forKey: "leftSort")
        d.set(right.sort.rawValue, forKey: "rightSort")
        d.set(left.showHidden, forKey: "leftHidden")
        d.set(right.showHidden, forKey: "rightHidden")
        d.set(left.showPerms, forKey: "leftPerms")
        d.set(right.showPerms, forKey: "rightPerms")
        d.set(showClock, forKey: "showClock")
        d.set(active === left ? "left" : "right", forKey: "activePanel")
        d.set(Double(view.fontSize), forKey: "fontSize")
        d.set(Array(history.suffix(100)), forKey: "history")
    }

    // MARK: - Layers

    // `_` before a parameter name means the call site passes it without a label: `push(x)` not `push(l: x)`.
    /// Shows a layer on top of everything else.
    func push(_ l: Layer) { layers.append(l); render() }
    // `{ $0 === l }` is a closure with shorthand argument `$0` (the first parameter), like `x -> x == l`.
    /// Removes the given layer wherever it is in the stack.
    func pop(_ l: Layer) { layers.removeAll { $0 === l }; render() }

    // MARK: - Rendering

    /// Clears and redraws the whole grid: base screen (unless a full-screen layer hides it) and then every
    /// layer from the topmost full-screen one upwards. Called on every event and timer tick.
    func render() {
        screen.clear()
        let fullIdx = layers.lastIndex { $0.fullScreen }
        if fullIdx == nil { renderBase() }
        // `fullIdx ?? 0`: with no full-screen layer, draw all layers on top of the base screen.
        for l in layers.suffix(from: fullIdx ?? 0) { l.render(screen) }
        view.needsDisplay = true
    }

    /// Horizontal position and width of a panel: the left one gets the left half, the right one the rest.
    private func panelGeometry(_ p: Panel) -> (x: Int, w: Int) {
        // Integer division, so for an odd column count the right panel is one column wider.
        let lw = screen.cols / 2
        return p === left ? (0, lw) : (lw, screen.cols - lw)
    }

    /// Draws the normal screen: console output, the two panels, the clock, the command line and the key bar.
    /// Rows 0 to R-3 belong to the panels, row R-2 is the command line, row R-1 the key bar.
    private func renderBase() {
        let R = screen.rows, C = screen.cols
        // "User screen" (command output) behind the panels
        let consoleH = R - 2
        // The ternary appends the unfinished line only if there is one; `+` concatenates arrays.
        let all = console + (consolePartial.isEmpty ? [] : [consolePartial])
        // Only the last `consoleH` lines fit; they are bottom-aligned above the command line.
        let tail = all.suffix(consoleH)
        var y = consoleH - tail.count
        for line in tail {
            // `prefix(C)` truncates to the screen width; it returns a Substring, so `String(...)` converts it back.
            screen.text(0, y, String(line.prefix(C)), Col.gray, Col.black)
            y += 1
        }
        if panelsOn {
            // `for ... where` filters the loop: only visible panels are drawn.
            for p in [left, right] where p.visible {
                let g = panelGeometry(p)
                // The clock sits in the top-right corner, so the panel touching the right edge leaves 6 columns free.
                let clockCols = showClock && g.x + g.w >= C ? 6 : 0
                p.render(screen, x: g.x, y: 0, w: g.w, h: R - 2, active: p === active, reserveRight: clockCols)
            }
        }
        if showClock {
            let t = timeFmt.string(from: Date())
            screen.text(C - t.count, 0, t, Col.black, Col.cyan)
        }
        // Command line
        // The prompt shows the shortened active path and `…` while a command is running instead of `>`.
        let prompt = shortPath(displayPath(active.path), max(10, C / 2)) + (running != nil ? "… " : ">")
        screen.text(0, R - 2, prompt, Col.gray, Col.black)
        // `cmd.render` returns the column where the text cursor goes.
        let cx = cmd.render(screen, x: prompt.count, y: R - 2, w: C - prompt.count, fg: Col.gray, bg: Col.black)
        screen.cursor = (cx, R - 2)
        drawKeybar(screen, baseLabels())
    }

    /// Labels for F1 to F10 in the key bar, depending on the held modifier key.
    private func baseLabels() -> [String] {
        if mods.alt { return ["Left", "Right", "", "", "", "", "Find", "Histry", "", ""] }
        if mods.shift { return ["", "", "", "New", "", "", "", "", "", ""] }
        return ["Help", "Menu", "View", "Edit", "Copy", "RenMov", "Mkdir", "Delete", "PullDn", "Quit"]
    }

    /// Called by the view when a modifier key is pressed or released, so the key bar can change labels.
    func modifiersChanged(_ f: NSEvent.ModifierFlags) {
        // An unlabelled tuple can be assigned to the labelled one; elements are matched by position.
        mods = (f.contains(.shift), f.contains(.control), f.contains(.option))
        if layers.isEmpty { render() }
    }

    // MARK: - Input

    /// Entry point for every key: Cmd-+/- changes the font, otherwise the top layer or the base screen
    /// handles the key; then the screen is redrawn.
    func handle(_ e: KeyEvent) {
        // `case .char(let c) = e.key` is pattern matching on an enum with associated values: it succeeds only
        // if `key` is the `.char` case and binds its payload to `c`. Commas in an `if` act like `&&`.
        if e.cmd, case .char(let c) = e.key, c == "=" || c == "+" || c == "-" {
            changeFont(c == "-" ? -1 : 1)
            return
        }
        if let top = layers.last { top.handle(e) } else { handleBase(e) }
        render()
    }

    /// Key handling when no layer is open: function keys, panel navigation and typing into the command line.
    func handleBase(_ e: KeyEvent) {
        let p = active
        // Swift `switch` has no fall-through (no `break` needed) and must be exhaustive, hence `default`.
        switch e.key {
        // `case .f(let n)` matches the function-key case and extracts its number.
        case .f(let n):
            if e.alt {
                switch n {
                case 1: driveMenu(left)
                case 2: driveMenu(right)
                case 7: findFile()
                case 8: historyMenu()
                default: break
                }
                return
            }
            if e.shift && n == 4 { newFile(); return }
            switch n {
            case 1: showHelp()
            case 2: userMenu()
            case 3: viewCurrent()
            case 4: editCurrent()
            case 5: copyOrMove(move: false)
            case 6: copyOrMove(move: true)
            case 7: makeDir()
            case 8: deleteFiles()
            case 9: openMenu()
            case 10: confirmQuit()
            default: break
            }
        case .tab:
            if panelsOn && other.visible { active = other }
        case .enter:
            if e.ctrl || e.cmd { insertName(); return }
            if !cmd.isEmpty { execute(cmd.text) } else if panelsOn { openCurrent() }
        case .esc:
            if !cmd.isEmpty { cmd = LineEdit() } else if !panelsOn { panelsOn = true }
        case .up:
            guard panelsOn else { return }
            if e.shift { p.toggleSelect() }
            p.move(-1)
        case .down:
            guard panelsOn else { return }
            if e.shift { p.toggleSelect() }
            p.move(1)
        case .pageUp:
            if e.ctrl || e.cmd { cdUp() } else { p.move(-p.pageSize) }
        case .pageDown:
            if e.ctrl || e.cmd { enterCurrent() } else { p.move(p.pageSize) }
        case .home:
            // Home/End go to the command line if it has text, otherwise they move the panel cursor.
            if !cmd.isEmpty { cmd.handle(e) } else { p.cursor = 0 }
        case .end:
            if !cmd.isEmpty { cmd.handle(e) } else { p.cursor = max(0, p.entries.count - 1) }
        case .left:
            // In brief mode entries are laid out in columns, so left/right jump one column (`listRows` entries).
            if e.cmd { cdUp() } else if !cmd.isEmpty { cmd.handle(e) } else { p.move(p.mode == .brief ? -p.listRows : -p.pageSize) }
        case .right:
            if e.cmd { enterCurrent() } else if !cmd.isEmpty { cmd.handle(e) } else { p.move(p.mode == .brief ? p.listRows : p.pageSize) }
        case .insert:
            p.toggleSelect(); p.move(1)
        case .backspace, .delete:
            cmd.handle(e)
        // `c` is a `Character`: one user-visible character (grapheme), not a 16-bit `char` as in Java.
        case .char(let c):
            if e.ctrl { ctrlKey(c); return }
            if e.cmd { cmdKey(c); return }
            if cmd.isEmpty && panelsOn {
                switch c {
                case " ":
                    // Space on a directory also starts a background size scan. `dirSizes[name] == nil` means no entry yet
                    // (an entry holding nil means a scan is in progress). The inner `c` shadows the outer `c`.
                    if let c = p.current, c.isDir, !c.isUp, p.dirSizes[c.name] == nil { scanDirSize(p, c) }
                    p.toggleSelect(); p.move(1); return
                case "+": selectGroup(true); return
                case "-": selectGroup(false); return
                case "*": p.invert(); return
                default: break
                }
            }
            cmd.insert(String(c))
        default:
            break
        }
    }

    /// Ctrl-key shortcuts on the base screen.
    private func ctrlKey(_ c: Character) {
        switch c {
        case "o": panelsOn.toggle()
        case "u": swapPanels()
        case "r": left.reload(); right.reload()
        case "e":
            // Ctrl-E / Ctrl-X step backwards / forwards through the history; past the end clears the line.
            if histIdx > 0 { histIdx -= 1; cmd.text = history[histIdx] }
        case "x":
            if histIdx < history.count - 1 { histIdx += 1; cmd.text = history[histIdx] } else { histIdx = history.count; cmd = LineEdit() }
        case "s": quickSearch()
        case "h": toggleHidden()
        case "b": active.mode = active.mode == .full ? .brief : .full
        // Optional chaining: `running?.interrupt()` calls the method only if `running` is not nil, else nothing.
        case "c": running?.interrupt()
        case "f": findFile()
        case "y": cmd = LineEdit()
        default: break
        }
    }

    /// Cmd-key shortcuts on the base screen.
    private func cmdKey(_ c: Character) {
        switch c {
        case "v": cmd.insert(NSPasteboard.general.string(forType: .string) ?? "")
        case "c": copyPaths()
        case "f": findFile()
        case "r": left.reload(); right.reload()
        case "t": openTerminal()
        default: break
        }
    }

    // MARK: - Mouse

    // `right isRight`: the caller writes the external label `right:`, the body uses the internal name `isRight`.
    /// Mouse click in grid coordinates: a click on the key bar acts as the function key below it, a click in
    /// a panel activates it and moves the cursor; double-click opens, right-click toggles the selection.
    func mouse(x: Int, y: Int, right isRight: Bool, clicks: Int) {
        guard layers.isEmpty else { return }
        let R = screen.rows
        if y == R - 1 {
            // The key bar is divided into 10 equal slots; `max(1, ...)` avoids division by zero.
            let slot = min(9, x / max(1, screen.cols / 10))
            handle(KeyEvent(key: .f(slot + 1)))
            return
        }
        guard panelsOn, y < R - 2 else { return }
        let p = x < screen.cols / 2 ? left : right
        guard p.visible else { return }
        active = p
        if let idx = p.index(atX: x, y: y) {
            p.cursor = idx
            if isRight { p.toggleSelect() } else if clicks == 2 { openCurrent() }
        }
        render()
    }

    /// Scroll wheel: scrolls a full-screen layer by sending up/down keys, otherwise moves the panel cursor.
    func scroll(x: Int, y: Int, delta: Int) {
        if let l = layers.last {
            if l.fullScreen { l.handle(KeyEvent(key: delta < 0 ? .up : .down)); render() }
            return
        }
        guard panelsOn else { return }
        let p = x < screen.cols / 2 ? left : right
        // A hidden panel's half of the screen shows the console; scrolling there must not move its cursor.
        guard p.visible else { return }
        p.move(delta)
        render()
    }

    // MARK: - Navigation

    /// Goes to the parent directory; Panel methods return an error message (String?) or nil on success.
    private func cdUp() {
        if let err = active.goUp() { showError(err) }
    }

    /// Enters the directory under the cursor, including packages such as `.app` bundles.
    private func enterCurrent() {
        guard let f = active.current else { return }
        if f.isUp { cdUp(); return }
        if f.isDir, let err = active.cd(f.url.path) { showError(err) }
    }

    /// Enter on an entry: opens a directory in the panel, any other file (and packages) with its default app.
    private func openCurrent() {
        guard let f = active.current else { return }
        if f.isUp { cdUp(); return }
        if f.isDir && !f.isPackage {
            if let err = active.cd(f.url.path) { showError(err) }
        } else {
            NSWorkspace.shared.open(f.url)
        }
    }

    /// Ctrl-Enter: inserts the name under the cursor into the command line, shell-quoted if needed.
    private func insertName() {
        guard let f = active.current else { return }
        let n = f.isUp ? ".." : f.name
        // Single-quote the name if it contains shell metacharacters; an embedded `'` becomes `'\''`.
        let q = n.rangeOfCharacter(from: CharacterSet(charactersIn: " '\"$&()[]{};|<>*?!#")) != nil
            ? "'" + n.replacingOccurrences(of: "'", with: "'\\''") + "'" : n
        cmd.insert(q + " ")
    }

    /// Ctrl-U: exchanges the two panels on screen.
    private func swapPanels() {
        // Tuple assignment swaps both variables in one statement.
        (left, right) = (right, left)
    }

    // `p: Panel? = nil` is an optional parameter with a default value (Java would need an overload).
    /// Ctrl-H: hidden files on/off for the active panel only.
    private func toggleHidden(_ p: Panel? = nil) {
        // The local `p` shadows the parameter, now non-optional.
        let p = p ?? active
        p.showHidden.toggle()
        p.reload()
    }

    /// Options menu: both panels on/off together.
    private func toggleHiddenBoth() {
        let on = !(left.showHidden && right.showHidden)
        for p in [left, right] where p.showHidden != on { p.showHidden = on; p.reload() }
    }

    /// Ctrl-S: opens the quick-search popup aligned with the active panel.
    private func quickSearch() {
        guard panelsOn else { return }
        let g = panelGeometry(active)
        push(QuickSearch(self, panel: active, px: g.x, pw: g.w))
    }

    // `as NSString` bridges the Swift String to the Objective-C class that has the path helper methods.
    /// Turns user input into an absolute, normalised path: expands `~` and resolves it against `base`.
    func resolve(_ t: String, base: String) -> String {
        var s = t.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("~") { s = (s as NSString).expandingTildeInPath }
        if !s.hasPrefix("/") { s = (base as NSString).appendingPathComponent(s) }
        return (s as NSString).standardizingPath
    }

    // MARK: - Command line execution

    // Internal instead of private only so that the tests can call it.
    /// Runs a command line: `cd`, `exit`, `cls`/`clear` are handled internally, everything else runs
    /// asynchronously in `zsh -l -c` with output streamed into the console.
    func execute(_ line: String) {
        if history.last != line { history.append(line) }
        histIdx = history.count
        cmd = LineEdit()
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "cd" || t.hasPrefix("cd ") {
            // `dropFirst(2)` removes "cd"; Swift strings cannot be indexed by integer (characters vary in size),
            // so such collection methods are used instead of `substring(2)`.
            var arg = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            // Strip one pair of matching quotes around the argument.
            if arg.count >= 2, let f = arg.first, (f == "'" || f == "\""), arg.last == f { arg = String(arg.dropFirst().dropLast()) }
            let target = arg.isEmpty ? home : resolve(arg, base: active.path)
            // `\(err)` is string interpolation, like `"cd: " + err`.
            if let err = active.cd(target) { consoleWrite("cd: \(err)\n"); panelsOn = false }
            return
        }
        if t == "exit" { confirmQuit(); return }
        if t == "cls" || t == "clear" { console = []; consolePartial = ""; return }
        guard running == nil else { NSSound.beep(); return }

        consoleWrite(shortPath(displayPath(active.path), max(10, screen.cols / 2)) + ">" + line + "\n")
        panelsOn = false
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", line]
        proc.currentDirectoryURL = active.url
        var env = ProcessInfo.processInfo.environment
        var path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // GUI apps get a minimal PATH, so add the usual Homebrew locations in front.
        for p in ["/usr/local/bin", "/opt/homebrew/bin"] where !path.contains(p) { path = p + ":" + path }
        env["PATH"] = path
        env["TERM"] = "dumb"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // stdin is closed, so interactive programs see end-of-input instead of hanging.
        proc.standardInput = FileHandle.nullDevice
        // The command is complete when the process has exited AND all its output has been read. A `DispatchGroup`
        // (≈ a Java `CountDownLatch`) counts both events; `notify` runs the closure once the count reaches zero.
        let done = DispatchGroup()
        done.enter()
        done.enter()
        var finished = false
        // Prints the exit code and reloads the panels; runs once, on the main thread.
        func finish(_ status: Int32) {
            guard !finished else { return }
            finished = true
            if !consolePartial.isEmpty { consoleWrite("\n") }
            if status != 0 { consoleWrite("[exit code \(status)]\n") }
            running = nil
            left.reload()
            right.reload()
            render()
        }
        // Called on a background thread whenever output is available; empty data means end of file.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; done.leave(); return }
            let s = String(decoding: d, as: UTF8.self)
            // UI state may only be touched on the main thread: `DispatchQueue.main.async` queues the closure there
            // (like `SwingUtilities.invokeLater`). `self?.` is optional chaining on the weak `self`.
            DispatchQueue.main.async { self?.consoleWrite(s); self?.render() }
        }
        proc.terminationHandler = { pr in
            done.leave()
            // A background job (`cmd &`) can keep the output pipe open after the shell has exited; don't wait for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(pr.terminationStatus) }
        }
        // Queued on the main thread after the last output chunk, because that chunk was queued before `leave()`.
        done.notify(queue: .main) { finish(proc.terminationStatus) }
        // `do { try ... } catch { ... }` is Java's try/catch; every throwing call must be marked with `try`.
        // Inside `catch` the exception is available as the implicit `error`.
        do {
            try proc.run()
            running = proc
        } catch {
            consoleWrite("Error: \(error.localizedDescription)\n")
        }
    }

    /// Appends shell output to the console: strips ANSI escape sequences, expands tabs, handles CR/LF and
    /// drops other control characters. Keeps at most 3000 lines.
    func consoleWrite(_ s: String) {
        // Removes CSI sequences (ESC [ ... final byte), e.g. colours and cursor movement.
        var clean = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        // Removes OSC sequences (ESC ] ... BEL), e.g. terminal title changes.
        clean = clean.replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "\t", with: "    ")
        // Iterating a String yields `Character`s (graphemes).
        for ch in clean {
            // CR LF forms a single grapheme in Swift, so it arrives as one `Character` and must be compared here.
            if ch == "\n" || ch == "\r\n" {
                console.append(consolePartial)
                consolePartial = ""
            // A lone CR returns to the line start; the line is cleared so the following text overwrites it.
            } else if ch == "\r" {
                consolePartial = ""
            } else if let a = ch.asciiValue, a < 32 {
                continue
            } else {
                consolePartial.append(ch)
            }
        }
        if console.count > 3000 { console.removeFirst(console.count - 3000) }
    }

    // MARK: - F3 / F4

    /// F3: views the file under the cursor; on a directory it calculates the directory size instead.
    private func viewCurrent() {
        guard panelsOn, let f = active.current, !f.isUp else { return }
        if f.isDir { dirSize(f.url, name: f.name); return }
        guard FileManager.default.isReadableFile(atPath: f.url.path) else { showError("Cannot read \(f.name)"); return }
        push(Viewer(self, path: f.url.path))
    }

    /// F4: edits the file under the cursor in the built-in editor.
    private func editCurrent() {
        guard panelsOn, let f = active.current, !f.isUp, !f.isDir else { return }
        openEditor(f.url.path)
    }

    /// Opens the editor layer; `Editor(...)` is a failable initialiser that returns nil for unsuitable files.
    private func openEditor(_ path: String) {
        if let ed = Editor(self, path: path) { push(ed) } else { showError("Cannot edit \((path as NSString).lastPathComponent): not a UTF-8 text file or too large.") }
    }

    /// Shift-F4: asks for a file name and opens it in the editor (a new file if it does not exist).
    private func newFile() {
        // `[unowned self]` captures `self` without retaining it and without making it optional; it would crash
        // if `self` were gone, which cannot happen since the Commander lives as long as the app.
        // `b, t in` names the closure parameters: the pressed button index and the input text.
        push(Dialog(self, title: "Edit", lines: ["Edit file:"], input: "", buttons: ["OK", "Cancel"]) { [unowned self] b, t in
            guard b == 0, !t.isEmpty else { return }
            self.openEditor(self.resolve(t, base: self.active.path))
        })
    }

    // MARK: - F5 / F6 copy & move

    /// F5 / F6: asks for the target, defaulting to the other panel's directory.
    private func copyOrMove(move: Bool) {
        let items = active.targets()
        guard !items.isEmpty else { return }
        let verb = move ? "Rename/Move" : "Copy"
        let what = items.count == 1 ? "\"\(items[0].name)\"" : "\(items.count) files"
        let def = other.visible ? other.path : active.path
        push(Dialog(self, title: verb, lines: ["\(verb) \(what) to:"], input: def,
                    buttons: [move ? "Rename/Move" : "Copy", "Cancel"]) { [unowned self] b, text in
            guard b == 0, !text.isEmpty else { return }
            self.transfer(items, to: text, move: move)
        })
    }

    /// Works out source/target pairs for a copy or move and asks before overwriting existing targets.
    /// Target rules: an existing directory receives the items, a name ending in `/` or several items create
    /// a directory, otherwise the single item is copied or renamed to that name.
    private func transfer(_ items: [FileEntry], to text: String, move: Bool) {
        let fm = FileManager.default
        let dest = resolve(text, base: active.path)
        // `&isDir` passes the variable by reference to an `inout` parameter (an out-parameter, no Java equivalent).
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: dest, isDirectory: &isDir)
        let destURL = URL(fileURLWithPath: dest)
        // An array of (source, target) tuples; it is assigned exactly once in each branch below.
        var pairs: [(URL, URL)]
        if exists && isDir.boolValue {
            // `map` with `$0` builds a new array, like `stream().map(...).toList()`.
            pairs = items.map { ($0.url, destURL.appendingPathComponent($0.name)) }
        } else if text.hasSuffix("/") || items.count > 1 {
            do { try fm.createDirectory(atPath: dest, withIntermediateDirectories: true) } catch {
                showError(error.localizedDescription); return
            }
            pairs = items.map { ($0.url, destURL.appendingPathComponent($0.name)) }
        } else {
            pairs = [(items[0].url, destURL)]
        }
        // `$0.1` is the second element of the tuple (the target).
        let conflicts = pairs.filter { fm.fileExists(atPath: $0.1.path) && !sameFile($0.0, $0.1) }
        if conflicts.isEmpty {
            runTransfer(pairs, move: move, overwrite: false)
        } else {
            let msg = conflicts.count == 1 ? "\"\(conflicts[0].1.lastPathComponent)\" already exists."
                : "\(conflicts.count) target files already exist."
            push(Dialog(self, title: "Warning", lines: [msg, "Overwrite? (old versions are moved to the Trash)"],
                        buttons: ["Overwrite", "Skip", "Cancel"], danger: true) { [unowned self] b, _ in
                if b == 0 || b == 1 { self.runTransfer(pairs, move: move, overwrite: b == 0) }
            })
        }
    }

    /// Performs the copy or move on a background thread with a progress box; existing targets are moved to
    /// the Trash first when overwriting, or skipped otherwise.
    private func runTransfer(_ pairs: [(URL, URL)], move: Bool, overwrite: Bool) {
        let prog = ProgressBox(self, title: move ? "Rename/Move" : "Copy")
        prog.fraction = 0
        push(prog)
        // Captured now so the reload at the end affects the right panels even if the user switches panels.
        let src = active, dst = other
        // `DispatchQueue.global().async` runs the closure on a background thread pool (like an ExecutorService).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager()
            var errors: [String] = []
            // `enumerated()` yields (index, element) pairs; the element tuple is destructured at the same time.
            for (i, (s, d)) in pairs.enumerated() {
                if prog.cancelled { break }
                DispatchQueue.main.async {
                    prog.message = "\(move ? "Moving" : "Copying") \(i + 1) of \(pairs.count)"
                    prog.detail = s.lastPathComponent + " → " + displayPath(d.deletingLastPathComponent().path)
                    prog.fraction = Double(i) / Double(pairs.count)
                    self?.render()
                }
                let same = sameFile(s, d)
                if same && !move { errors.append("\(s.lastPathComponent): source and target are the same file"); continue }
                // The trailing `/` prevents `/a/bc` from counting as inside `/a/b`.
                if !same && (d.path + "/").hasPrefix(s.path + "/") {
                    errors.append("\(s.lastPathComponent): cannot copy a directory into itself"); continue
                }
                if !same && fm.fileExists(atPath: d.path) {
                    if !overwrite { continue }
                    // Falls back to a plain delete if the Trash is not available (e.g. on some network volumes).
                    do { try fm.trashItem(at: d, resultingItemURL: nil) } catch {
                        do { try fm.removeItem(at: d) } catch { errors.append("\(d.lastPathComponent): \(error.localizedDescription)"); continue }
                    }
                }
                do {
                    if move { try fm.moveItem(at: s, to: d) } else { try fm.copyItem(at: s, to: d) }
                } catch {
                    errors.append("\(s.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pop(prog)
                src.selected = []
                // For a single item, focus the new name in a panel that shows the target directory.
                if pairs.count == 1, let d = pairs.first?.1 {
                    let dir = d.deletingLastPathComponent().standardizedFileURL.path
                    if dir == src.path { src.reload(focus: d.lastPathComponent) } else { src.reload() }
                    if dir == dst.path { dst.reload(focus: d.lastPathComponent) } else { dst.reload() }
                } else {
                    src.reload(); dst.reload()
                }
                if !errors.isEmpty { self.showError(errors.prefix(8).joined(separator: "\n")) }
                self.render()
            }
        }
    }

    // MARK: - F7 / F8

    /// F7: asks for a name and creates the directory (intermediate directories too), then focuses it.
    private func makeDir() {
        push(Dialog(self, title: "Make directory", lines: ["Create the directory:"], input: "", buttons: ["OK", "Cancel"]) { [unowned self] b, t in
            guard b == 0, !t.isEmpty else { return }
            let path = self.resolve(t, base: self.active.path)
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                // Focus the first path component below the current directory, since only that is visible in the panel.
                let rel = path.hasPrefix(self.active.path + "/") ? String(path.dropFirst(self.active.path.count + 1)) : path
                // `.first.map(String.init)` converts the optional Substring to an optional String.
                self.active.reload(focus: rel.split(separator: "/").first.map(String.init))
            } catch {
                self.showError(error.localizedDescription)
            }
        })
    }

    /// F8: after confirmation, moves the targets to the Trash on a background thread with a progress box.
    private func deleteFiles() {
        let items = active.targets()
        guard !items.isEmpty else { return }
        let what = items.count == 1 ? "\"\(items[0].name)\"" : "\(items.count) files/directories"
        push(Dialog(self, title: "Delete", lines: ["Do you wish to delete", what, "(moved to the Trash)"],
                    buttons: ["Delete", "Cancel"], danger: true) { [unowned self] b, _ in
            guard b == 0 else { return }
            let prog = ProgressBox(self, title: "Delete")
            prog.fraction = 0
            self.push(prog)
            let p = self.active
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let fm = FileManager()
                var errors: [String] = []
                for (i, f) in items.enumerated() {
                    if prog.cancelled { break }
                    DispatchQueue.main.async {
                        prog.message = "Moving to Trash \(i + 1) of \(items.count)"
                        prog.detail = f.name
                        prog.fraction = Double(i) / Double(items.count)
                        self?.render()
                    }
                    do { try fm.trashItem(at: f.url, resultingItemURL: nil) } catch {
                        errors.append("\(f.name): \(error.localizedDescription)")
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pop(prog)
                    p.selected = []
                    self.left.reload(); self.right.reload()
                    if !errors.isEmpty { self.showError(errors.prefix(8).joined(separator: "\n")) }
                    self.render()
                }
            }
        })
    }

    // MARK: - Selection

    /// `+` / `-`: selects or unselects the entries matching a wildcard mask.
    private func selectGroup(_ on: Bool) {
        let p = active
        push(Dialog(self, title: on ? "Select" : "Unselect", lines: ["File mask (e.g. *.txt, *.jpg):"], input: "*",
                    buttons: ["OK", "Cancel"]) { b, t in
            if b == 0 { p.select(pattern: t, on: on) }
        })
    }

    // `static func` ≈ a Java static method. The tuple return type `(left:, right:)` returns two values at once.
    /// Compares the files (not directories) of two panels and returns the names to select on each side.
    /// Files present on one side only are always selected. Files present on both sides are selected
    /// - by date: on the side where the file is newer;
    /// - by content: on both sides when the sizes or the bytes differ.
    /// `cancelled` is polled between files, so a long content comparison can be stopped.
    static func differences(_ l: [FileEntry], _ r: [FileEntry], byContent: Bool,
                            cancelled: () -> Bool = { false }) -> (left: Set<String>, right: Set<String>) {
        // Builds a name -> entry dictionary; duplicate names keep the first entry.
        let ln = Dictionary(l.filter { !$0.isDir }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let rn = Dictionary(r.filter { !$0.isDir }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var ls = Set(ln.keys.filter { rn[$0] == nil })
        var rs = Set(rn.keys.filter { ln[$0] == nil })
        for (name, a) in ln {
            guard let b = rn[name] else { continue }
            if cancelled() { break }
            if byContent {
                if a.size != b.size || !filesEqual(a.url, b.url) { ls.insert(name); rs.insert(name) }
            } else if a.date > b.date {
                ls.insert(name)
            } else if b.date > a.date {
                rs.insert(name)
            }
        }
        return (ls, rs)
    }

    /// Selects the result of a comparison in both panels, or reports that there are no differences.
    private func applyComparison(_ d: (left: Set<String>, right: Set<String>)) {
        left.selected = d.left
        right.selected = d.right
        if d.left.isEmpty && d.right.isEmpty { info("Compare", ["The directories are identical."]) }
    }

    /// Compares the file contents in the background; Esc cancels. The result is dropped if either panel
    /// changed directory in the meantime.
    private func compareContents() {
        let prog = ProgressBox(self, title: "Compare")
        prog.message = "Comparing file contents…"
        push(prog)
        let l = left.entries, r = right.entries, lp = left.path, rp = right.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let d = Commander.differences(l, r, byContent: true) { prog.cancelled }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pop(prog)
                guard !prog.cancelled, self.left.path == lp, self.right.path == rp else { return }
                self.applyComparison(d)
            }
        }
    }

    /// Asks whether to compare the two panels by date or by content and selects the differing files.
    private func compareDirs() {
        push(Dialog(self, title: "Compare", lines: ["Compare the files by:"], buttons: ["Date", "Content", "Cancel"]) { [unowned self] b, _ in
            if b == 0 {
                self.applyComparison(Commander.differences(self.left.entries, self.right.entries, byContent: false))
            } else if b == 1 {
                self.compareContents()
            }
        })
    }

    // MARK: - Popups and menus

    /// Shows an error dialog, wrapping the message to fit the screen.
    func showError(_ msg: String) {
        let lines = wrap(msg, min(64, screen.cols - 16))
        push(Dialog(self, title: "Error", lines: lines, buttons: ["OK"], danger: true))
    }

    func info(_ title: String, _ lines: [String]) {
        push(Dialog(self, title: title, lines: lines, buttons: ["OK"]))
    }

    private func confirmQuit() {
        push(Dialog(self, title: "The Commander", lines: ["Do you want to quit the Commander?"], buttons: ["Yes", "No"]) { b, _ in
            if b == 0 { NSApp.terminate(nil) }
        })
    }

    func showHelp() {
        push(TextBox(self, title: "Help", lines: helpText))
    }

    /// Alt-F1 / Alt-F2: popup with common locations and mounted volumes for the given panel.
    private func driveMenu(_ p: Panel) {
        // An array of (label, path) tuples.
        var locs: [(String, String)] = [("/", "/"), ("~  (Home)", home)]
        for d in ["Desktop", "Documents", "Downloads"] { locs.append(("~/" + d, home + "/" + d)) }
        locs.append(("/Applications", "/Applications"))
        let keys: [URLResourceKey] = [.volumeNameKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            where v.path != "/" {
            // `try?` turns a thrown error into nil, so `?.volumeName` and `??` fall back to the folder name.
            let name = (try? v.resourceValues(forKeys: Set(keys)))?.volumeName ?? v.lastPathComponent
            locs.append(("Volume: " + name, v.path))
        }
        let popup = ListPopup(self, title: p === left ? "Left" : "Right", items: locs.map { $0.0 }) { [unowned self] i in
            self.active = p
            p.visible = true
            self.panelsOn = true
            if let err = p.cd(locs[i].1) { self.showError(err) }
        }
        // Centre the popup over the panel it belongs to.
        popup.centerX = p === left ? screen.cols / 4 : screen.cols * 3 / 4
        if let i = locs.firstIndex(where: { $0.1 == p.path }) { popup.sel = i }
        push(popup)
    }

    // `() -> Void` is a function type: a closure without parameters or result (like a `Runnable`).
    /// F2: user menu with Finder, Terminal, clipboard and size actions.
    private func userMenu() {
        let entries: [(String, () -> Void)] = [
            ("Open in Finder", { [unowned self] in
                if let f = self.active.current, !f.isUp { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                else { NSWorkspace.shared.open(self.active.url) }
            }),
            ("Open with default application", { [unowned self] in
                if let f = self.active.current, !f.isUp { NSWorkspace.shared.open(f.url) }
            }),
            ("Open Terminal here", { [unowned self] in self.openTerminal() }),
            ("Copy path to clipboard", { [unowned self] in self.copyPaths() }),
            ("Calculate directory size", { [unowned self] in
                if let f = self.active.current, f.isDir, !f.isUp { self.dirSize(f.url, name: f.name) }
                else { self.dirSize(self.active.url, name: displayPath(self.active.path)) }
            }),
            ("Compare directories", { [unowned self] in self.compareDirs() }),
        ]
        push(ListPopup(self, title: "User Menu", items: entries.map { $0.0 }) { i in entries[i].1() })
    }

    /// Alt-F8: history popup, newest first; the chosen entry is put into the command line.
    private func historyMenu() {
        guard !history.isEmpty else { info("History", ["The command history is empty."]); return }
        let items = Array(history.reversed())
        push(ListPopup(self, title: "History", items: items) { [unowned self] i in self.cmd.text = items[i] })
    }

    /// Opens Terminal.app in the active directory.
    private func openTerminal() {
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([active.url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Cmd-C: copies the full paths of the selected entries (or the current directory) to the clipboard.
    private func copyPaths() {
        let paths = active.targets().map { $0.url.path }
        let s = paths.isEmpty ? active.path : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Space on a directory: sum all file sizes below it in the background, show in Size column.
    private func scanDirSize(_ p: Panel, _ e: FileEntry) {
        // `generation` changes whenever the panel changes directory; a result for an old generation is discarded.
        let gen = p.generation, name = e.name, url = e.url
        // `dirSizes` holds `Int64?` values, so the entry is a double optional: `.some(nil)` stores an entry
        // whose value is nil, meaning "scan in progress", unlike a missing entry.
        p.dirSizes[name] = .some(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            if let en = FileManager().enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
                var n = 0
                // `for case let u as URL in en` iterates and casts each element, skipping elements that are not URLs.
                for case let u as URL in en {
                    n += 1
                    if n % 2000 == 0 {
                        var stale = false
                        // `main.sync` runs the check on the main thread and waits, since `p` is only safe to read there.
                        DispatchQueue.main.sync { stale = p.generation != gen }
                        if stale { return }
                    }
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
                }
            }
            DispatchQueue.main.async {
                // Drop the result if the panel moved on or the entry was removed by a reload.
                guard let self, p.generation == gen, p.dirSizes[name] != nil else { return }
                p.dirSizes[name] = .some(total)
                self.render()
            }
        }
    }

    /// F3 on a directory: counts files, directories and bytes below it and shows the result in a dialog.
    private func dirSize(_ url: URL, name: String) {
        let prog = ProgressBox(self, title: "Directory size")
        prog.message = "Scanning " + name
        push(prog)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var total: Int64 = 0, files = 0, dirs = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
            if let en = FileManager().enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
                for case let u as URL in en {
                    if prog.cancelled { break }
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    if v?.isDirectory == true { dirs += 1 } else { files += 1; total += Int64(v?.fileSize ?? 0) }
                    if (files + dirs) % 3000 == 0 {
                        // Copy the current total so the main-thread closure does not read the variable being mutated here.
                        let t = total
                        DispatchQueue.main.async { prog.detail = "\(human(t)) so far…"; self?.render() }
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let cancelled = prog.cancelled
                self.pop(prog)
                self.info("Directory size", [name, "", "\(groupNum(total)) bytes (\(human(total)))",
                                             "\(groupNum(Int64(files))) files, \(groupNum(Int64(dirs))) directories"]
                          + (cancelled ? ["(cancelled – incomplete)"] : []))
            }
        }
    }

    /// Alt-F7: recursive file name search below the active directory (case-insensitive wildcards,
    /// several patterns separated by `,` or `;`); results are shown in a list that jumps to the file.
    private func findFile() {
        let root = active.path
        push(Dialog(self, title: "Find File", lines: ["File name to find (wildcards allowed),", "searching below " + fitTail(displayPath(root), 40) + ":"],
                    input: "*", buttons: ["Find", "Cancel"]) { [unowned self] b, t in
            guard b == 0, !t.isEmpty else { return }
            let pats = t.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
                // A pattern without wildcards matches as a substring.
                .map { $0.contains("*") || $0.contains("?") ? $0 : "*\($0)*" }
            let hidden = self.active.showHidden
            let prog = ProgressBox(self, title: "Find File")
            prog.message = "Searching for " + t
            self.push(prog)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var results: [String] = []
                var scanned = 0
                let opts: FileManager.DirectoryEnumerationOptions = hidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
                if let en = FileManager().enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [], options: opts, errorHandler: { _, _ in true }) {
                    for case let u as URL in en {
                        if prog.cancelled || results.count >= 2000 { break }
                        scanned += 1
                        // File names on APFS may be decomposed Unicode; normalise to NFC so they match the typed pattern.
                        let name = u.lastPathComponent.precomposedStringWithCanonicalMapping
                        // `fnmatch` is the C library function from Darwin, called directly; 0 means a match.
                        if pats.contains(where: { fnmatch($0, name, FNM_CASEFOLD) == 0 }) { results.append(u.path) }
                        if scanned % 500 == 0 {
                            let p = u.path, n = results.count
                            DispatchQueue.main.async { prog.detail = "\(n) found – " + p; self?.render() }
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pop(prog)
                    if results.isEmpty { self.info("Find File", ["No files found."]); return }
                    // Show the paths relative to the search root.
                    let rel = results.map { relativePath($0, under: root) }
                    self.push(ListPopup(self, title: "\(results.count) found", items: rel) { [unowned self] i in
                        let p = results[i]
                        self.panelsOn = true
                        if let err = self.active.cd((p as NSString).deletingLastPathComponent, focus: (p as NSString).lastPathComponent) {
                            self.showError(err)
                        }
                    })
                }
            }
        })
    }

    /// F9: builds and opens the pull-down menu bar (Left, Files, Commands, Options, Right).
    /// Menu items hold closures for the action and for the check mark state.
    func openMenu() {
        // A nested function, visible only inside `openMenu`.
        func panelMenu(_ p: Panel) -> [MenuItem] {
            var items = [
                MenuItem(title: "Brief", hint: "Ctrl-B", action: { p.mode = .brief }, checked: { p.mode == .brief }),
                MenuItem(title: "Full", action: { p.mode = .full }, checked: { p.mode == .full }),
                MenuItem.sep,
            ]
            let sorts: [(String, SortMode)] = [("Name", .name), ("Extension", .ext), ("Time", .time), ("Size", .size), ("Unsorted", .unsorted)]
            for (t, m) in sorts { items.append(MenuItem(title: t, action: { p.sort = m }, checked: { p.sort == m })) }
            items += [
                MenuItem.sep,
                MenuItem(title: "On/Off", action: { [unowned self] in p.visible.toggle(); if !p.visible && self.active === p, self.other.visible { self.active = self.other } }, checked: { p.visible }),
                MenuItem(title: "Hidden files", hint: "Ctrl-H", action: { [unowned self] in self.toggleHidden(p) }, checked: { p.showHidden }),
                MenuItem(title: "Permissions", action: { p.showPerms.toggle(); if p.showPerms { p.mode = .full } }, checked: { p.showPerms }),
                MenuItem(title: "Re-read", hint: "Ctrl-R", action: { p.reload() }),
                MenuItem(title: "Location…", hint: p === left ? "Alt-F1" : "Alt-F2", action: { [unowned self] in self.driveMenu(p) }),
            ]
            return items
        }
        let files: [MenuItem] = [
            MenuItem(title: "Help", hint: "F1", action: { [unowned self] in self.showHelp() }),
            MenuItem(title: "User menu", hint: "F2", action: { [unowned self] in self.userMenu() }),
            MenuItem(title: "View", hint: "F3", action: { [unowned self] in self.viewCurrent() }),
            MenuItem(title: "Edit", hint: "F4", action: { [unowned self] in self.editCurrent() }),
            MenuItem(title: "New file…", hint: "Shift-F4", action: { [unowned self] in self.newFile() }),
            MenuItem(title: "Copy", hint: "F5", action: { [unowned self] in self.copyOrMove(move: false) }),
            MenuItem(title: "Rename or move", hint: "F6", action: { [unowned self] in self.copyOrMove(move: true) }),
            MenuItem(title: "Make directory", hint: "F7", action: { [unowned self] in self.makeDir() }),
            MenuItem(title: "Delete", hint: "F8", action: { [unowned self] in self.deleteFiles() }),
            MenuItem.sep,
            MenuItem(title: "Select group", hint: "+", action: { [unowned self] in self.selectGroup(true) }),
            MenuItem(title: "Unselect group", hint: "-", action: { [unowned self] in self.selectGroup(false) }),
            MenuItem(title: "Invert selection", hint: "*", action: { [unowned self] in self.active.invert() }),
            MenuItem.sep,
            MenuItem(title: "Quit", hint: "F10", action: { [unowned self] in self.confirmQuit() }),
        ]
        let commands: [MenuItem] = [
            MenuItem(title: "Find file", hint: "Alt-F7", action: { [unowned self] in self.findFile() }),
            MenuItem(title: "History", hint: "Alt-F8", action: { [unowned self] in self.historyMenu() }),
            MenuItem(title: "Quick search", hint: "Ctrl-S", action: { [unowned self] in self.quickSearch() }),
            MenuItem.sep,
            MenuItem(title: "Swap panels", hint: "Ctrl-U", action: { [unowned self] in self.swapPanels() }),
            MenuItem(title: "Panels on/off", hint: "Ctrl-O", action: { [unowned self] in self.panelsOn.toggle() }),
            MenuItem(title: "Compare directories", action: { [unowned self] in self.compareDirs() }),
            MenuItem(title: "Directory size", action: { [unowned self] in self.dirSize(self.active.url, name: displayPath(self.active.path)) }),
            MenuItem.sep,
            MenuItem(title: "Open in Finder", action: { [unowned self] in NSWorkspace.shared.open(self.active.url) }),
            MenuItem(title: "Terminal here", hint: "Cmd-T", action: { [unowned self] in self.openTerminal() }),
            MenuItem(title: "Clear output", action: { [unowned self] in self.console = []; self.consolePartial = "" }),
        ]
        let options: [MenuItem] = [
            MenuItem(title: "Hidden files (both)", action: { [unowned self] in self.toggleHiddenBoth() }, checked: { [unowned self] in self.left.showHidden && self.right.showHidden }),
            MenuItem(title: "Clock", action: { [unowned self] in self.showClock.toggle() }, checked: { [unowned self] in self.showClock }),
            MenuItem.sep,
            MenuItem(title: "Larger font", hint: "Cmd-+", action: { [unowned self] in self.changeFont(1) }),
            MenuItem(title: "Smaller font", hint: "Cmd--", action: { [unowned self] in self.changeFont(-1) }),
        ]
        push(PulldownMenu(self, menus: [("Left", panelMenu(left)), ("Files", files), ("Commands", commands),
                                        ("Options", options), ("Right", panelMenu(right))],
                          cur: active === left ? 0 : 4))
    }

    // MARK: - Font size

    /// Changes the font size by `d` points (9 to 40) and resizes the window to keep the same columns and rows.
    func changeFont(_ d: CGFloat) {
        guard let win = view.window else { return }
        let cols = screen.cols, rows = screen.rows
        view.setFont(max(9, min(40, view.fontSize + d)))
        // The window snaps its size to whole character cells.
        win.contentResizeIncrements = NSSize(width: view.cw, height: view.ch)
        win.contentMinSize = NSSize(width: view.cw * 60, height: view.ch * 14)
        win.setContentSize(NSSize(width: CGFloat(cols) * view.cw, height: CGFloat(rows) * view.ch))
        render()
    }
}

// A global constant at file level; Swift allows top-level declarations outside any type.
/// The F1 help text, one string per screen line.
let helpText: [String] = [
    "MacCommander – two-panel file manager for macOS",
    " Inspired by Norton Commander; not affiliated with Gen Digital/Norton.",
    "",
    "Function keys:",
    " On Mac keyboards press them with fn – or use Cmd-1 … Cmd-0.",
    " F1  Help                     F6  Rename / move",
    " F2  User menu                F7  Make directory",
    " F3  View (folder: size)      F8  Delete (to the Trash)",
    " F4  Edit                     F9  Pull-down menu",
    " F5  Copy                     F10 Quit",
    " Shift-F4   edit a new file",
    " Alt-F1/F2  location/volume for the left/right panel",
    " Alt-F7     find file (also Ctrl-F)",
    " Alt-F8     command history",
    "",
    "Panels:",
    " Tab              switch panel",
    " ↑↓ PgUp PgDn     move the cursor (Home/End: first/last)",
    " Enter            open folder / open file with the default app",
    " Ctrl-PgUp, Cmd-← parent directory",
    " Ctrl-PgDn, Cmd-→ enter folder/package (.app)",
    " Space, Insert, Shift-↑↓   select files",
    " + / - / *        select / unselect / invert a group",
    " Ctrl-S           quick search by name",
    " Ctrl-O           panels off/on (show command output)",
    " Ctrl-U           swap panels",
    " Ctrl-B           brief/full view",
    " Ctrl-H           hidden files on/off (active panel)",
    " Ctrl-R           re-read",
    " Cmd-C            copy path(s) to the clipboard",
    " Mouse: click moves the cursor, double-click opens, right-click selects",
    "",
    "Command line:",
    " Type and press Enter – runs in zsh in the active directory.",
    " Run interactive programs (vim, top …) in Terminal (Cmd-T).",
    " cd <path>        change the active panel's directory",
    " Ctrl-C           cancel the running command",
    " Ctrl-Enter       insert the file name",
    " Ctrl-E / Ctrl-X  previous / next command",
    " Esc              clear the line (or bring the panels back)",
    " Cmd-V            paste",
    "",
    "Viewer:  F4 hex/text, ←→ sideways, Esc/F3/F10 close",
    "Editor:  F2 save, Ctrl-Y delete line, Esc/F10 close",
    "Markdown (.md): F3 toggles raw/formatted view (viewer and editor)",
    "Font size: Cmd-+ / Cmd--",
]
