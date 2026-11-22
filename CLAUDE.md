# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Norton-Commander-style two-panel file manager for macOS. Swift Package, AppKit only, no dependencies.

## Build and verify

- Compile check: `swift build` (debug, host architecture only, a few seconds).
- Tests: `swift test` (Swift Testing: `@Test`, `#expect`; needs the Xcode toolchain). One test: `swift test --filter PanelTests`. The tests use `@testable import MacCommander` on the executable target and cover the code that runs without a window: `Screen` and the text helpers, `Panel` (against a temporary directory), Markdown rendering, `LineEdit` and `KeyEvent.from`. Layers can be tested by building `Commander(view: TerminalView(fontSize: 16))` off-screen in a `@MainActor` test (see `ViewerTests`); no window is needed.
- `#expect` cannot call a `mutating` method directly; store the result in a `let` first.
- Lint: `swiftlint` from the repo root (Homebrew; config `.swiftlint.yml`). The current code lints clean; keep it at 0 violations. Rules that clash with the existing style are disabled there on purpose, so do not re-enable them or "fix" the code for them.
- Release app: `./build.sh` builds arm64 and x86_64 separately (`--build-system native --triple ...`), merges them with `lipo` and writes `build/MacCommander.app` with an ad-hoc signature. It is slow; use it only when the `.app` itself is needed.
- Visual check without a window taking focus: `.build/debug/MacCommander --snapshot <out.png> --keys f9,down,enter` renders the screen after replaying the keys and exits. Key names: `up down left right pgup pgdn home end enter esc tab bs del ins space`, `f1`..`f10`, single characters, modifier prefixes `ctrl+ alt+ shift+ cmd+`, and `sleep` (waits 1.5 s). Write the PNG to the scratchpad and Read it.
- Snapshot mode runs against the real file system and the saved panel paths. Never replay keys that change files (F5-F8 with Enter, F2 in the editor).

## Architecture

- `Screen` is a character-cell grid (char + palette indices into `dosPalette`). `TerminalView` (an `NSView`) paints the grid and turns `NSEvent`s into `KeyEvent`s.
- `Commander` is the controller. `render()` clears and redraws the whole grid on every key event and every 0.5 s tick (clock, cursor blink). Never draw incrementally.
- Popups, menus, the viewer and the editor implement the `Layer` protocol and sit on `Commander.layers`. Only the top layer receives keys; `fullScreen` layers hide the panels underneath.
- Settings persist in `UserDefaults` via `Commander.saveState()` (keys such as `leftPath`, `history`).
- Shell commands run via `/bin/zsh -l -c` with stdin closed, so interactive programs do not work there. `cd` is handled internally to move the panel.
- Deletes and overwrites go to the Trash (`trashItem`); keep it that way.

## Conventions

- Match the existing idiomatic Swift style: short names, no Hungarian notation, no licence headers, `// MARK: -` section markers. The com.helger Java rules do not apply here.
- Comments explain Swift idioms for a reader who knows Java but not Swift (optionals, `guard`, closures, value-type structs, `[weak self]`). Keep that style when adding code.
- All text is in British English: dialogs, help text and README.
- A key binding is documented in three places: the README "Features" list, `helpText`, and the key bar labels (`baseLabels()`, `drawKeybar`). Change all three together.
- This is an independently maintained fork of `Johann123-x/MacCommander`: commit to `master` of `phax/MacCommander`; no upstream PRs, no changelog.
