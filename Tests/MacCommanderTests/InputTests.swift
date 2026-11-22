import AppKit
import Testing
@testable import MacCommander

struct LineEditTests {
    /// A key event without modifiers.
    private func key(_ k: Key) -> KeyEvent { KeyEvent(key: k) }

    @Test func typingAndCursorMovement() {
        // `var` because `LineEdit` is a struct (value type): `handle` is `mutating` and changes it in place.
        var l = LineEdit()
        for c in "acd" { l.handle(key(.char(c))) }
        l.handle(key(.left)); l.handle(key(.left))
        l.handle(key(.char("b")))
        #expect(l.text == "abcd")
        #expect(l.pos == 2)
        l.handle(key(.home))
        #expect(l.pos == 0)
        l.handle(key(.left))
        #expect(l.pos == 0)
        l.handle(key(.end))
        l.handle(key(.right))
        #expect(l.pos == 4)
    }

    @Test func backspaceAndDelete() {
        var l = LineEdit()
        l.text = "abc"
        l.handle(key(.backspace))
        #expect(l.text == "ab")
        l.handle(key(.home))
        l.handle(key(.backspace))
        #expect(l.text == "ab")
        l.handle(key(.delete))
        #expect(l.text == "b")
        l.handle(key(.end))
        l.handle(key(.delete))
        #expect(l.text == "b")
    }

    @Test func ctrlYClearsAndOtherShortcutsAreNotConsumed() {
        var l = LineEdit()
        l.text = "abc"
        var e = KeyEvent(key: .char("y"))
        e.ctrl = true
        // The result is stored first: `#expect` cannot call a `mutating` method on `l` directly.
        let consumedY = l.handle(e)
        #expect(consumedY)
        #expect(l.isEmpty)
        e.key = .char("s")
        // Returning false lets the caller handle Ctrl-S (quick search) itself.
        let consumedS = l.handle(e)
        #expect(!consumedS)
        let consumedF5 = l.handle(key(.f(5)))
        #expect(!consumedF5)
    }

    @Test func insertDropsLineBreaks() {
        var l = LineEdit()
        l.insert("a\nb\r\nc")
        #expect(l.text == "abc")
        #expect(l.pos == 3)
    }

    @Test func renderScrollsToKeepTheCursorVisible() {
        let s = Screen(cols: 10, rows: 1)
        var l = LineEdit()
        l.text = "abcdefgh"
        let cx = l.render(s, x: 2, y: 0, w: 5, fg: Col.gray, bg: Col.black)
        #expect(String((0..<10).map { s[$0, 0].ch }) == "  efgh    ")
        #expect(cx == 6)
    }
}

struct KeyEventTests {
    /// Builds a synthetic key-down event like the one AppKit delivers to `TerminalView.keyDown`.
    private func event(_ keyCode: UInt16, _ chars: String, ignoring: String? = nil,
                       _ flags: NSEvent.ModifierFlags = []) throws -> KeyEvent? {
        // `#require` unwraps the optional or fails the test right here.
        let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                              windowNumber: 0, context: nil, characters: chars,
                                              charactersIgnoringModifiers: ignoring ?? chars,
                                              isARepeat: false, keyCode: keyCode))
        return KeyEvent.from(e)
    }

    @Test func functionAndNavigationKeysMapByKeyCode() throws {
        #expect(try event(122, "")?.key == .f(1))
        #expect(try event(109, "")?.key == .f(10))
        #expect(try event(126, "")?.key == .up)
        #expect(try event(36, "\r")?.key == .enter)
        #expect(try event(53, "\u{1B}")?.key == .esc)
    }

    @Test func cmdDigitsActAsFunctionKeys() throws {
        // Cmd-1 … Cmd-0 replace F1 … F10 on Mac keyboards; the Cmd flag is cleared.
        let e1 = try #require(try event(18, "1", [.command]))
        #expect(e1.key == .f(1))
        #expect(!e1.cmd)
        #expect(try event(29, "0", [.command])?.key == .f(10))
    }

    @Test func ctrlShortcutsUseTheUnmodifiedLowercaseCharacter() throws {
        let e = try #require(try event(1, "\u{13}", ignoring: "S", [.control]))
        #expect(e.key == .char("s"))
        #expect(e.ctrl)
    }

    @Test func optionComposedCharactersArePlainText() throws {
        // On a German layout Option-L types "@"; it must reach the command line as text, not as Alt-@.
        let e = try #require(try event(37, "@", ignoring: "l", [.option]))
        #expect(e.key == .char("@"))
        #expect(!e.alt)
    }

    @Test func controlCharactersWithoutModifiersAreIgnored() throws {
        #expect(try event(0, "\u{01}") == nil)
    }
}
