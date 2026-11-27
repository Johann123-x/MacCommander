import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var commander: Commander!

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        NSApp.applicationIconImage = makeIcon()
        let saved = UserDefaults.standard.double(forKey: "fontSize")
        let view = TerminalView(fontSize: saved > 0 ? CGFloat(saved) : 16)
        let size = NSSize(width: view.cw * 80, height: view.ch * 25)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MacCommander"
        window.backgroundColor = .black
        window.contentView = view
        window.contentResizeIncrements = NSSize(width: view.cw, height: view.ch)
        window.contentMinSize = NSSize(width: view.cw * 60, height: view.ch * 14)
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.setFrameAutosaveName("MacCommanderMain")
        commander = Commander(view: view)
        window.makeFirstResponder(view)
        if CommandLine.arguments.contains("--snapshot") {
            window.orderBack(nil) // render in the background, never steal focus/keystrokes
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        runSnapshotIfRequested(view)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        if !CommandLine.arguments.contains("--snapshot") { commander?.saveState() }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "About MacCommander", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Hide MacCommander", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "Quit MacCommander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let w = NSMenu(title: "Window")
        w.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        w.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        winItem.submenu = w
        NSApp.mainMenu = main
        NSApp.windowsMenu = w
    }

    // Developer aid: MacCommander --snapshot out.png [--keys f9,down,…] renders and exits.
    private func runSnapshotIfRequested(_ view: TerminalView) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = args[i + 1]
        let keys = args.firstIndex(of: "--keys").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?
            .split(separator: ",").map(String.init) ?? []
        func step(_ i: Int) {
            guard i < keys.count else {
                self.commander.render()
                view.blinkOn = true
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
            let k = keys[i]
            let parts = k.split(separator: ":").compactMap { Int($0) }
            if (k.hasPrefix("click:") || k.hasPrefix("hover:")), parts.count == 2 {
                if k.hasPrefix("click:") { self.commander.mouse(x: parts[0], y: parts[1], right: false, clicks: 1) }
                else { self.commander.hover(x: parts[0], y: parts[1]) }
            } else if !k.hasPrefix("sleep"), let e = parseKey(k) { self.commander.handle(e) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (k.hasPrefix("sleep") ? 1.5 : 0.05)) { step(i + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { step(0) }
    }
}

private func parseKey(_ s: String) -> KeyEvent? {
    var e = KeyEvent(key: .esc)
    var name = s
    while let r = name.range(of: "+"), name.count > 1 {
        let mod = String(name[..<r.lowerBound])
        switch mod {
        case "ctrl": e.ctrl = true
        case "alt": e.alt = true
        case "shift": e.shift = true
        case "cmd": e.cmd = true
        default: break
        }
        name = String(name[r.upperBound...])
    }
    let named: [String: Key] = ["up": .up, "down": .down, "left": .left, "right": .right, "pgup": .pageUp, "pgdn": .pageDown,
                                "home": .home, "end": .end, "enter": .enter, "esc": .esc, "tab": .tab, "bs": .backspace,
                                "del": .delete, "ins": .insert, "space": .char(" ")]
    if let k = named[name] { e.key = k; return e }
    if name.hasPrefix("f"), let n = Int(name.dropFirst()) { e.key = .f(n); return e }
    if name.hasPrefix("t:") { // type text
        return nil
    }
    guard let c = name.first else { return nil }
    e.key = .char(c)
    return e
}

func makeIcon() -> NSImage {
    NSImage(size: NSSize(width: 512, height: 512), flipped: true) { r in
        let outer = NSBezierPath(roundedRect: r.insetBy(dx: 28, dy: 28), xRadius: 92, yRadius: 92)
        NSColor.black.setFill()
        outer.fill()
        outer.addClip()
        let inner = r.insetBy(dx: 64, dy: 70)
        let ph = inner.height - 58
        dosPalette[1].setFill()
        NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: ph).fill()
        dosPalette[11].setStroke()
        for i in 0..<2 {
            let pw = inner.width / 2
            let pr = NSRect(x: inner.minX + CGFloat(i) * pw, y: inner.minY, width: pw, height: ph).insetBy(dx: 10, dy: 10)
            for inset in [CGFloat(0), 12] {
                let p = NSBezierPath(rect: pr.insetBy(dx: inset, dy: inset))
                p.lineWidth = 6
                p.stroke()
            }
            dosPalette[3].setFill()
            if i == 0 { NSRect(x: pr.minX + 22, y: pr.minY + 60, width: pr.width - 44, height: 22).fill() }
        }
        dosPalette[3].setFill()
        NSRect(x: inner.minX, y: inner.maxY - 40, width: inner.width, height: 40).fill()
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(CommandLine.arguments.contains("--snapshot") ? .accessory : .regular)
app.run()
