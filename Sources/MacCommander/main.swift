import AppKit

// `final class` = a class that cannot be subclassed (Java `final class`). Classes are reference types;
// `struct`s (see Screen.swift) are value types that are copied on assignment.
// Without an access modifier a declaration is `internal`: visible in the whole module (≈ package-private).
/// The application delegate: at launch it builds the menu bar, the window, the `TerminalView` and the
/// `Commander`, and on quit it saves the panel state. `NSObject` is the Objective-C root class AppKit expects.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // `var` = mutable, `let` = constant (like a Java `final` field or local).
    // `NSWindow!` is an implicitly unwrapped optional: nil until `applicationDidFinishLaunching` sets it,
    // then used without unwrapping. Accessing it while still nil crashes (like an NPE).
    var window: NSWindow!
    var commander: Commander!

    // `_ n: Notification`: `_` means callers pass the argument without a label, `n` is the internal name.
    // Swift calls normally carry argument labels, e.g. `NSSize(width: 1, height: 2)`.
    /// Called by AppKit once the event loop is running; this is where the UI is actually created.
    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        NSApp.applicationIconImage = makeIcon()
        // Font size saved by an earlier run (0.0 if never saved); the type `Double` is inferred.
        let saved = UserDefaults.standard.double(forKey: "fontSize")
        let view = TerminalView(fontSize: saved > 0 ? CGFloat(saved) : 16)
        // The window starts at the classic 80x25 text screen; `cw`/`ch` are one cell's width/height in points.
        let size = NSSize(width: view.cw * 80, height: view.ch * 25)
        // `.zero`, `.titled`, `.buffered`: leading-dot syntax, the type (`NSPoint`, `NSWindow.StyleMask`, ...) is
        // inferred from the parameter, like an enum constant with a static import. `[a, b]` here is an option set.
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MacCommander"
        window.backgroundColor = .black
        window.contentView = view
        // Resizing snaps to whole cells, so the grid never shows partial rows or columns.
        window.contentResizeIncrements = NSSize(width: view.cw, height: view.ch)
        window.contentMinSize = NSSize(width: view.cw * 60, height: view.ch * 14)
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.setFrameAutosaveName("MacCommanderMain")
        commander = Commander(view: view)
        window.makeFirstResponder(view)
        // `--snapshot` (see `runSnapshotIfRequested`) is a developer aid; a normal launch brings the window to the front.
        if CommandLine.arguments.contains("--snapshot") {
            window.orderBack(nil) // render in the background, never steal focus/keystrokes
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        runSnapshotIfRequested(view)
    }

    // A body consisting of a single expression returns it implicitly: `{ true }` means `{ return true }`.
    /// Quits the app when its only window is closed (by default a macOS app would keep running).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Persists the panel paths, history etc. to UserDefaults; skipped in snapshot mode so a test run
    /// does not overwrite the real settings.
    func applicationWillTerminate(_ n: Notification) {
        // `commander?.saveState()` is optional chaining: the call is skipped if `commander` is nil (no NPE).
        if !CommandLine.arguments.contains("--snapshot") { commander?.saveState() }
    }

    /// Builds the minimal macOS menu bar (app menu and Window menu); the file manager functions live in the F9 menu.
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        // `#selector(...)` names an Objective-C method that AppKit invokes through the responder chain when the
        // item is chosen (like referring to a method by name via reflection, but checked by the compiler).
        m.addItem(withTitle: "About MacCommander", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Hide MacCommander", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "Quit MacCommander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let w = NSMenu(title: "Window")
        w.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        // `addItem` returns the new item, so its modifier mask (Cmd+Ctrl+F) can be set in the same expression.
        w.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        winItem.submenu = w
        NSApp.mainMenu = main
        NSApp.windowsMenu = w
    }

    // Developer aid: MacCommander --snapshot out.png [--keys f9,down,…] renders and exits.
    /// Snapshot mode (`--snapshot <png> [--keys k1,k2,...]`): after a short delay it replays the keys one by one
    /// through `Commander.handle`, renders the final grid into a PNG file and terminates the process.
    /// Used to check the UI visually without interacting with the window; does nothing without `--snapshot`.
    private func runSnapshotIfRequested(_ view: TerminalView) {
        let args = CommandLine.arguments
        // `guard cond else { return }` is an early exit: the else block must leave the scope. It is Swift's idiom
        // for preconditions. `guard let i = ...` also unwraps an optional: `firstIndex` returns `Int?` (nil if not
        // found) and `i` is a plain `Int` for the rest of the function. A comma joins conditions like `&&`.
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = args[i + 1]
        // `flatMap` on an optional runs the closure only if `--keys` was found; `$0` is the closure's first argument
        // (the index). `?.` continues only if a value came out, and `?? []` supplies the default when the chain yields
        // nil (like `Optional.orElse`). `String.init` passes the initialiser as a function (like `String::new`) to turn
        // each `Substring` piece into a `String`.
        let keys = args.firstIndex(of: "--keys").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?
            .split(separator: ",").map(String.init) ?? []
        // A nested function. It captures `keys`, `out`, `view` and `self` like a Java lambda captures variables.
        // Each step handles one key and then schedules the next step on the main thread, so AppKit can process
        // the effects (redraws, timers) in between.
        func step(_ i: Int) {
            // Past the last key: render the final state, force the blinking cursor visible and write the PNG.
            guard i < keys.count else {
                self.commander.render()
                view.blinkOn = true
                // `if let rep = ...` runs the block only if the value is non-nil, binding the unwrapped value to `rep`.
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    // `try?` turns a thrown error into nil (errors are ignored here); `?.write` is skipped if PNG encoding failed.
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                // Ends the process at once (like `System.exit(0)`); `applicationWillTerminate` is not called.
                exit(0)
            }
            let k = keys[i]
            // `sleep` entries only add a delay; tokens `parseKey` cannot parse are silently skipped.
            if !k.hasPrefix("sleep"), let e = parseKey(k) { self.commander.handle(e) }
            // `DispatchQueue.main.asyncAfter` runs the closure later on the main (UI) thread, like a one-shot Swing
            // `Timer` or a delayed `SwingUtilities.invokeLater`. `{ step(i + 1) }` is a trailing closure: a closure
            // that is the last argument may be written after the parentheses.
            DispatchQueue.main.asyncAfter(deadline: .now() + (k.hasPrefix("sleep") ? 1.5 : 0.05)) { step(i + 1) }
        }
        // The first key is replayed after 0.6 s, giving the window time to lay out and draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { step(0) }
    }
}

// `private` at file level = visible in this file only. `-> KeyEvent?` returns an optional (nil = no key).
/// Parses one `--keys` token such as `f9`, `ctrl+s`, `enter` or `x` into a `KeyEvent`; nil if unsupported.
private func parseKey(_ s: String) -> KeyEvent? {
    // `KeyEvent` is a struct, so `e` must be a `var` to change its fields. `.esc` is only a placeholder.
    var e = KeyEvent(key: .esc)
    var name = s
    // `while let`: loop as long as a "+" is found, binding its range to `r`; `name.count > 1` keeps a lone "+"
    // as a character key. Swift strings cannot be indexed by Int (a `Character` may span several code points),
    // so positions are opaque `String.Index` values; `name[..<r.lowerBound]` slices up to the "+".
    while let r = name.range(of: "+"), name.count > 1 {
        let mod = String(name[..<r.lowerBound])
        // `switch` on a String. Cases do not fall through (no `break` needed) and the switch must be exhaustive,
        // hence `default`. Unknown modifiers are ignored.
        switch mod {
        case "ctrl": e.ctrl = true
        case "alt": e.alt = true
        case "shift": e.shift = true
        case "cmd": e.cmd = true
        default: break
        }
        // `r.upperBound...` is a one-sided range: from just after the "+" to the end.
        name = String(name[r.upperBound...])
    }
    // Dictionary literal `[key: value]`. `.char(" ")` is an enum case carrying an associated value
    // (see `Key` in TerminalView.swift).
    let named: [String: Key] = ["up": .up, "down": .down, "left": .left, "right": .right, "pgup": .pageUp, "pgdn": .pageDown,
                                "home": .home, "end": .end, "enter": .enter, "esc": .esc, "tab": .tab, "bs": .backspace,
                                "del": .delete, "ins": .insert, "space": .char(" ")]
    // A dictionary lookup returns an optional (nil if the key is absent), hence `if let`.
    if let k = named[name] { e.key = k; return e }
    // `.f(n)` builds the enum case carrying the function key number; `dropFirst()` strips the "f".
    if name.hasPrefix("f"), let n = Int(name.dropFirst()) { e.key = .f(n); return e }
    // Typing whole texts is not implemented; such tokens are ignored.
    if name.hasPrefix("t:") { // type text
        return nil
    }
    // Anything else is taken as a single character key (its first `Character`).
    guard let c = name.first else { return nil }
    e.key = .char(c)
    return e
}

/// Draws the Dock icon in code: two blue panels with cyan double frames, a cursor bar and a key bar strip.
func makeIcon() -> NSImage {
    // The trailing closure `{ r in ... }` is the drawing handler; `r` is its parameter (the image rect).
    // `makeIcon` consists of this single expression, so it is returned without `return`.
    // `flipped: true` makes y grow downwards, like the text grid.
    NSImage(size: NSSize(width: 512, height: 512), flipped: true) { r in
        let outer = NSBezierPath(roundedRect: r.insetBy(dx: 28, dy: 28), xRadius: 92, yRadius: 92)
        NSColor.black.setFill()
        outer.fill()
        outer.addClip()
        let inner = r.insetBy(dx: 64, dy: 70)
        // Panel height, leaving room below for the key bar strip.
        let ph = inner.height - 58
        dosPalette[1].setFill()
        NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: ph).fill()
        dosPalette[11].setStroke()
        // `0..<2` is a half-open range (0 and 1), like `for (int i = 0; i < 2; i++)`.
        for i in 0..<2 {
            let pw = inner.width / 2
            let pr = NSRect(x: inner.minX + CGFloat(i) * pw, y: inner.minY, width: pw, height: ph).insetBy(dx: 10, dy: 10)
            // Two nested rectangles give the double-line frame of a DOS panel.
            for inset in [CGFloat(0), 12] {
                let p = NSBezierPath(rect: pr.insetBy(dx: inset, dy: inset))
                p.lineWidth = 6
                p.stroke()
            }
            dosPalette[3].setFill()
            // Only the left panel gets the cursor bar.
            if i == 0 { NSRect(x: pr.minX + 22, y: pr.minY + 60, width: pr.width - 44, height: 22).fill() }
        }
        dosPalette[3].setFill()
        NSRect(x: inner.minX, y: inner.maxY - 40, width: inner.width, height: 40).fill()
        return true
    }
}

// Top-level statements in main.swift are the program entry point, like the body of Java's
// `public static void main`. Only this file may contain executable top-level code.
// They create the application object, attach the delegate and enter the AppKit event loop.
let app = NSApplication.shared
// NSApplication holds its delegate only weakly, so this global constant keeps it alive.
let delegate = AppDelegate()
app.delegate = delegate
// `.accessory` = no Dock icon and no menu bar, so a snapshot run stays out of the user's way.
app.setActivationPolicy(CommandLine.arguments.contains("--snapshot") ? .accessory : .regular)
// Runs the event loop; it does not return while the app is running.
app.run()
