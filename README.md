# MacCommander

A two-panel file manager for macOS, inspired by Norton Commander (NC 3/4/5 look), as a native app (Swift/AppKit, no dependencies).

> MacCommander is an independent project and is not affiliated with Gen Digital Inc. (Norton). "Norton Commander" is a trademark of its respective owners.

## Download

The ready-made app is available under [Releases](https://github.com/Johann123-x/MacCommander/releases): download `MacCommander-v1.0-macOS.zip`, unpack it and drag `MacCommander.app` to `/Applications`. Runs on macOS 13 and later on Apple silicon and Intel Macs (universal).

**First launch:** the app is not notarised by Apple, so macOS reports on first launch that it cannot be checked. To start it anyway:

- right-click `MacCommander.app` → **Open** → **Open**, or
- **System Settings → Privacy & Security** → click **Open Anyway** next to MacCommander at the bottom, or
- in Terminal: `xattr -dr com.apple.quarantine /Applications/MacCommander.app`

This is only needed once.

## Building and running

```bash
./build.sh
open build/MacCommander.app
```

To install, drag `build/MacCommander.app` to `/Applications`.

## Features

- Two blue panels with double frames, full/brief view, sorting, clock, free space
- F1 Help · F2 User menu · F3 Viewer (text/hex, formatted Markdown) · F4 Editor · F5 Copy · F6 Rename/move
  · F7 Make directory · F8 Delete (Trash) · F9 Pull-down menu · F10 Quit
- Alt-F1/F2 locations and volumes, Alt-F7 find file, Alt-F8 history, Ctrl-S quick search
- Command line (zsh) with output behind the panels (Ctrl-O); `cd` controls the panel
- Select with Space/Insert/Shift-arrows, `+` `-` `*` for groups
- Mouse: click, double-click, right-click selects, click on the key bar
- Cmd-1 … Cmd-0 replace F1 … F10 (Mac keyboards), Cmd-+/- font size

All deletions (including overwriting) go to the Trash.

### Markdown

For `.md` files, **F3** in the viewer and in the editor switches between raw text and the formatted view (headings, bold/italic, code, lists, quotes, tables, code blocks). The viewer starts formatted, the editor in raw text; the formatted view in the editor is read-only.

### Panel options (F9 → Left/Right)

- **Hidden files**: show or hide hidden files for this panel only (Ctrl-H = active panel)
- **Permissions**: an extra "Attr" column with the Unix permissions (e.g. `drwxr-xr-x`), in the full view only
