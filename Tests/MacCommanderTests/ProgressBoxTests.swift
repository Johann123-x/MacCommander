import AppKit
import Testing
@testable import MacCommander

@MainActor
final class ProgressBoxTests {
    let cmd = Commander(view: TerminalView(fontSize: 16))

    /// Renders `box` on an 80×25 screen and returns all rows.
    private func rows(_ box: ProgressBox) -> [String] {
        let s = Screen(cols: 80, rows: 25)
        box.render(s)
        return (0..<s.rows).map { y in String((0..<s.cols).map { s[$0, y].ch }) }
    }

    // A fraction below 0 means "no progress bar"; 0 and above show the bar.
    @Test(arguments: [-1.0, 0.0, 0.5])
    func showsTheCancelHintWithAndWithoutProgressBar(fraction: Double) {
        let box = ProgressBox(cmd, title: "Copy")
        box.fraction = fraction
        #expect(rows(box).contains { $0.contains("Esc to cancel") })
        box.handle(KeyEvent(key: .esc))
        #expect(box.cancelled)
        let after = rows(box)
        #expect(after.contains { $0.contains("Cancelling…") })
        if fraction >= 0 {
            // The bar is still there; the hint is in its own row below it.
            let bar = after.firstIndex { $0.contains("░") || $0.contains("█") }
            let hint = after.firstIndex { $0.contains("Cancelling…") }
            #expect(bar != nil)
            // `map` on an optional transforms the value if there is one (like `Optional.map` in Java).
            #expect(hint == bar.map { $0 + 1 })
        }
    }
}
