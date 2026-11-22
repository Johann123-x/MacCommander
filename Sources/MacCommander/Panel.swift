import AppKit
import Darwin

// `struct` is a value type: assigning or passing it copies it (no shared reference as with a Java object).
// `var` fields are mutable, `let` would be final. No explicit visibility means `internal` (module-wide, like package-private).
/// One row of a panel listing: a file, directory, symlink or the synthetic ".." entry.
struct FileEntry {
    var name: String
    var url: URL
    var isDir: Bool
    // Fields with a default value may be omitted in the compiler-generated memberwise initialiser `FileEntry(name:url:isDir:...)`.
    var isLink = false
    var isPackage = false
    var isHidden = false
    var size: Int64 = 0
    var date: Date = .distantPast
    var mode: UInt16 = 0
    // Computed property: no storage, the body runs on every read (like a getter `isUp()`).
    var isUp: Bool { name == ".." }

    /// Unix permission string like "drwxr-xr-x" (with setuid/setgid/sticky as s/S, t/T).
    var permString: String {
        // `Int(mode)` is an explicit conversion; Swift never widens numeric types implicitly.
        let m = Int(mode)
        // `Character` is one user-visible character (grapheme), not a UTF-16 unit like Java's `char`.
        let type: Character = isLink ? "l" : (m & Int(S_IFMT) == Int(S_IFDIR) ? "d" : "-")
        // Type inference makes this a `[Character]` (≈ `ArrayList<Character>`); `var` because it is appended to.
        var out = [type]
        // Array of tuples `(Int, Character)`: anonymous value pairs, no class needed. `0o400` is an octal literal.
        let bits: [(Int, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"),
                                        (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                        (0o004, "r"), (0o002, "w"), (0o001, "x")]
        // `for (b, c) in bits` destructures each tuple into two constants.
        for (b, c) in bits { out.append(m & b != 0 ? c : "-") }
        // Nested function; it can read and modify the enclosing locals (`out`, `m`). `_` drops the argument label at call sites.
        // It overlays setuid/setgid/sticky on the x position: lower case if x was set, upper case if not (like `ls -l`).
        func special(_ flag: Int, _ idx: Int, _ on: Character, _ off: Character) {
            if m & flag != 0 { out[idx] = out[idx] == "x" ? on : off }
        }
        special(0o4000, 3, "s", "S")
        special(0o2000, 6, "s", "S")
        special(0o1000, 9, "t", "T")
        // `String([Character])` builds the string from the character array.
        return String(out)
    }
}

// Enum with raw values: each case maps to its name as String; `PanelMode(rawValue: "full")` returns an
// optional (nil for unknown text). Used to persist the mode in UserDefaults.
/// Brief = three name-only columns, full = one column with size, date and time.
enum PanelMode: String { case brief, full }
/// Sort order of a panel; `unsorted` keeps the order returned by the file system.
enum SortMode: String { case name, ext, time, size, unsorted }

// `class` is a reference type like a Java object; `final` forbids subclassing, as in Java.
/// One of the two file panels: current directory, its sorted listing, cursor, scroll offset and selection.
final class Panel {
    // `private(set)`: readable from outside, writable only inside this class.
    private(set) var path: String = "/"
    var entries: [FileEntry] = []
    /// Index into `entries` of the highlighted row.
    var cursor = 0
    /// Index of the first entry visible in the panel (scroll offset).
    var top = 0
    /// Names of the selected (Ins-marked) entries. `Set<String>()` ≈ `new HashSet<String>()`.
    var selected = Set<String>()
    // `Int64?` is an optional: either a value or nil (≈ `Optional<Long>`, but checked by the compiler).
    // As a dictionary value this gives two levels: key missing (never scanned) vs. key present with nil (scan running).
    /// Recursively computed directory sizes (by name); nil value = scan in progress.
    var dirSizes: [String: Int64?] = [:]
    /// Bumped on every directory change so stale scans are discarded.
    private(set) var generation = 0
    var mode: PanelMode = .full
    // `didSet` is a property observer: runs after every assignment, so changing the sort order re-lists the directory.
    var sort: SortMode = .name { didSet { reload() } }
    var showHidden = false
    /// Extra "Attr" column with Unix permissions (full mode only).
    var showPerms = false
    var visible = true
    /// Free bytes on the volume of `path`; nil when unknown.
    var freeSpace: Int64?
    /// Visible rows and columns of the listing, updated by `render` and used for paging and mouse hit tests.
    var listRows = 20
    var listCols = 1
    /// X position of each name column, recorded by `render` for `index(atX:y:)`.
    private var colX: [Int] = [0]

    // `init` is the constructor. `cd` returns nil on success, so each `!= nil` means "failed, try the next fallback":
    // the requested path, then the home directory, then the root. `_ =` discards an unused return value explicitly.
    init(path: String) {
        if cd(path) != nil, cd(NSHomeDirectory()) != nil { _ = cd("/") }
    }

    /// Entry under the cursor, or nil when the listing is empty. `entries.indices` is the range 0..<count.
    var current: FileEntry? { entries.indices.contains(cursor) ? entries[cursor] : nil }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    /// Number of entries visible at once (rows × columns), used for PgUp/PgDn.
    var pageSize: Int { max(1, listRows * listCols) }

    // MARK: Loading

    // `static` as in Java. `throws` marks a function that can raise an error (all errors are effectively checked),
    // and every call to it must be marked with `try`. `_ path` means the caller writes no label: `list(p, hidden:..., sort:...)`.
    /// Reads a directory and returns the sorted entries, with ".." first unless `path` is the root.
    static func list(_ path: String, hidden: Bool, sort: SortMode) throws -> [FileEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // `URLResourceKey`s name the file attributes to prefetch; `.isDirectoryKey` is shorthand for `URLResourceKey.isDirectoryKey`.
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isSymbolicLinkKey, .isHiddenKey, .isPackageKey]
        // `try` propagates a thrown error to the caller (like an undeclared rethrow); `FileManager.default` is the shared singleton.
        let items = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: hidden ? [] : [.skipsHiddenFiles])
        // `map { u in ... }` transforms each URL into a FileEntry (≈ `stream().map(u -> ...).toList()`); `u` is the closure parameter.
        var res: [FileEntry] = items.map { u in
            // `try?` turns a thrown error into nil instead of propagating it. `v` is therefore optional.
            let v = try? u.resourceValues(forKeys: Set(keys))
            // `v?.isDirectory` is optional chaining (nil if `v` is nil); `?? false` supplies a default (≈ `Optional.orElse(false)`).
            var isDir = v?.isDirectory ?? false
            let isLink = v?.isSymbolicLink ?? false
            // For a symlink, follow it to decide whether it points to a directory.
            if isLink {
                // `ObjCBool` is the Objective-C BOOL that this Foundation API expects; `&b` passes it by reference (an out-parameter).
                var b: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &b) { isDir = b.boolValue }
            }
            // Normalise to NFC: macOS file systems may return decomposed Unicode, which would break name comparisons.
            let name = u.lastPathComponent.precomposedStringWithCanonicalMapping
            // Raw POSIX `lstat` from Darwin (not following symlinks) to get the permission bits. `stat()` is the zeroed C struct.
            var st = stat()
            let mode = lstat(u.path, &st) == 0 ? UInt16(st.st_mode) : 0
            return FileEntry(name: name, url: u, isDir: isDir, isLink: isLink,
                             isPackage: v?.isPackage ?? false,
                             isHidden: (v?.isHidden ?? false) || name.hasPrefix("."),
                             size: Int64(v?.fileSize ?? 0),
                             date: v?.contentModificationDate ?? .distantPast, mode: mode)
        }
        // Local helpers. `as NSString` bridges to the Objective-C string class for its path methods.
        func ext(_ e: FileEntry) -> String { e.isDir ? "" : (e.name as NSString).pathExtension.lowercased() }
        // `localizedStandardCompare` is Finder-like ordering: case-insensitive and numbers compared numerically ("a2" < "a10").
        func byName(_ a: FileEntry, _ b: FileEntry) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        if sort != .unsorted {
            // `sort { a, b in ... }` sorts in place with a "less than" closure (≈ `list.sort(comparator)` but returning Bool).
            // Rules: directories always before files; then by the chosen key; ties fall back to the name.
            // Time and size sort descending (newest / largest first), name and extension ascending.
            res.sort { a, b in
                if a.isDir != b.isDir { return a.isDir }
                // `switch` on an enum must be exhaustive; no `break` needed, cases never fall through.
                switch sort {
                case .name, .unsorted: return byName(a, b)
                case .ext:
                    // Two constants declared in one `let`.
                    let ea = ext(a), eb = ext(b)
                    // Ternary operator as in Java.
                    return ea != eb ? ea < eb : byName(a, b)
                case .time: return a.date != b.date ? a.date > b.date : byName(a, b)
                case .size: return a.size != b.size ? a.size > b.size : byName(a, b)
                }
            }
        }
        if path != "/" {
            let parent = (path as NSString).deletingLastPathComponent
            res.insert(FileEntry(name: "..", url: URL(fileURLWithPath: parent), isDir: true), at: 0)
        }
        return res
    }

    // `@discardableResult` allows callers to ignore the returned value without a compiler warning.
    // `focus: String? = nil` is an optional parameter with a default value, so it can be left out.
    /// Changes the panel to `newPath`, re-reads it and puts the cursor on `focus` (a name) if given.
    /// Selection and computed directory sizes are reset.
    /// Returns an error message, or nil on success.
    @discardableResult
    func cd(_ newPath: String, focus: String? = nil) -> String? {
        // `standardizingPath` resolves `~`, `.` and `..`.
        var p = (newPath as NSString).standardizingPath
        if p.isEmpty { p = "/" }
        // `do { try ... } catch { ... }` ≈ try/catch; inside `catch` the error is available as the implicit `error`.
        do {
            let list = try Panel.list(p, hidden: showHidden, sort: sort)
            path = p
            entries = list
            selected = []
            dirSizes = [:]
            generation += 1
            top = 0
            // Optional chaining on `focus`: `f` is nil if no focus name was given.
            let f = focus?.precomposedStringWithCanonicalMapping
            // `flatMap` on an optional runs the closure only if `f` is non-nil (≈ `Optional.flatMap`).
            // `firstIndex { $0.name == n }` returns the index or nil; `$0` is the implicit first closure parameter.
            cursor = f.flatMap { n in list.firstIndex { $0.name == n } } ?? 0
            updateFree()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Moves to the parent directory and puts the cursor on the directory just left.
    func goUp() -> String? {
        // `guard cond else { return }` is an early exit: the else branch must leave the scope. Reads as "ensure that".
        guard path != "/" else { return nil }
        let name = (path as NSString).lastPathComponent
        return cd((path as NSString).deletingLastPathComponent, focus: name)
    }

    /// Re-reads the current directory, keeping cursor, selection and directory sizes where entries still exist.
    /// If the directory has vanished, walks up to the nearest existing parent.
    func reload(focus: String? = nil) {
        let keep = focus?.precomposedStringWithCanonicalMapping ?? current?.name
        // `guard let list = ...` unwraps the optional into a non-optional constant that stays in scope after the guard.
        guard let list = try? Panel.list(path, hidden: showHidden, sort: sort) else {
            var p = path
            while p != "/" {
                p = (p as NSString).deletingLastPathComponent
                // `cd` returns nil on success.
                if cd(p) == nil { return }
            }
            return
        }
        let old = cursor
        entries = list
        // Drop selected names that no longer exist.
        selected = selected.intersection(Set(list.map { $0.name }))
        // `filter { k, _ in ... }` on a dictionary gets (key, value) pairs; `_` ignores the value. Keeps sizes of surviving directories.
        dirSizes = dirSizes.filter { k, _ in list.contains { $0.name == k && $0.isDir } }
        // `if let a = x, let b = y` unwraps several optionals; the body runs only if all are non-nil.
        if let k = keep, let i = list.firstIndex(where: { $0.name == k }) {
            cursor = i
        } else {
            cursor = min(old, max(0, list.count - 1))
        }
        updateFree()
    }

    /// Refreshes `freeSpace` for the volume of the current directory (nil on error).
    func updateFree() {
        freeSpace = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Navigation & selection

    /// Moves the cursor by `d` rows (negative = up), clamped to the listing.
    func move(_ d: Int) {
        guard !entries.isEmpty else { return }
        cursor = max(0, min(entries.count - 1, cursor + d))
    }

    /// Ins / Space: toggles selection of the entry under the cursor (never "..").
    func toggleSelect() {
        // `guard let c = current, !c.isUp`: unwrap and test a condition in one guard.
        guard let c = current, !c.isUp else { return }
        if selected.contains(c.name) { selected.remove(c.name) } else { selected.insert(c.name) }
    }

    /// Size shown in the Size column: computed total for scanned directories.
    func sizeText(_ e: FileEntry) -> String {
        if e.isUp { return "►UP--DIR◄" }
        guard e.isDir else { return sizeString(e.size) }
        // The dictionary lookup returns `Int64??` (double optional). The patterns distinguish the three states:
        // `.some(.some(n))` size known, `.some(.none)` scan in progress, `.none` never scanned.
        // `case .some(.some(let n))` binds the inner value to `n` (like a destructuring pattern).
        switch dirSizes[e.name] {
        case .some(.some(let n)): return sizeString(n)
        case .some(.none): return "…"
        case .none: return "►SUB-DIR◄"
        }
    }

    /// Entries an operation (copy, move, delete) acts on: the selection, or else the entry under the cursor.
    func targets() -> [FileEntry] {
        let sel = entries.filter { selected.contains($0.name) && !$0.isUp }
        if !sel.isEmpty { return sel }
        if let c = current, !c.isUp { return [c] }
        return []
    }

    /// Selects or deselects files (not directories) whose names match a list of shell wildcards
    /// separated by `,` or `;`. `*.*` is treated as `*`, as in DOS.
    func select(pattern: String, on: Bool) {
        // Chained `split`/`map`/`filter` ≈ a Java stream pipeline (but eager, each step returns a new array).
        let pats = pattern.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0 == "*.*" ? "*" : $0 }
        // `for ... in ... where cond` filters inside the loop header.
        for e in entries where !e.isUp && !e.isDir {
            // C `fnmatch` from Darwin, case-insensitive; 0 means match.
            if pats.contains(where: { fnmatch($0, e.name, FNM_CASEFOLD) == 0 }) {
                if on { selected.insert(e.name) } else { selected.remove(e.name) }
            }
        }
    }

    /// Inverts the selection of all files (directories are left alone).
    func invert() {
        for e in entries where !e.isUp && !e.isDir {
            if selected.contains(e.name) { selected.remove(e.name) } else { selected.insert(e.name) }
        }
    }

    /// Used for mouse clicks; returns nil outside the list area.
    /// Entry index under an absolute screen position (panel is always at y = 0).
    func index(atX ax: Int, y ay: Int) -> Int? {
        // Row 0 is the top border and row 1 the column headers, so the list starts at y = 2.
        let r = ay - 2
        guard r >= 0, r < listRows else { return nil }
        var k = 0
        // `enumerated()` yields (index, element) pairs; picks the rightmost column whose start is left of the click.
        for (i, cx) in colX.enumerated() where ax >= cx { k = i }
        // Entries flow top to bottom, then to the next column.
        let idx = top + k * listRows + r
        return idx < entries.count ? idx : nil
    }

    // MARK: Rendering

    /// `reserveRight`: columns at the right end of the top border that are covered (clock).
    /// Draws the panel into the screen grid at the given rectangle, highlighting the cursor only if `active`.
    func render(_ s: Screen, x: Int, y: Int, w: Int, h: Int, active: Bool, reserveRight: Int = 0) {
        let fg = Col.lcyan, bg = Col.blue
        s.fill(x, y, w, h, fg, bg)
        guard w >= 20, h >= 6 else { return }
        s.box(x, y, w, h, fg, bg)
        let iw = w - 2
        let listY = y + 2
        // Total height minus top border, header row, separator, status line and bottom border.
        let rowsN = max(1, h - 5)
        let sepY = y + h - 3

        // Column start X, column width and X positions of the vertical separators.
        var cX: [Int] = [], cW: [Int] = [], seps: [Int] = []
        // Full mode: Name │ [Attr 10] │ Size 9 │ Date 8 │ Time 5
        let perms = mode == .full && showPerms && iw - 36 >= 8
        if mode == .full {
            // 25 = Size 9 + Date 8 + Time 5 + three separators; the Attr column adds 10 + 1.
            let nw = max(1, iw - 25 - (perms ? 11 : 0))
            cX = [x + 1]; cW = [nw]
            var sx = x + 1 + nw
            seps = [sx]
            if perms { sx += 11; seps.append(sx) }
            seps += [sx + 10, sx + 19]
        } else {
            // Brief mode: three equal name columns, the last one takes the remainder.
            let n = 3, cwid = max(1, (iw - (n - 1)) / n)
            // `0..<n` is a half-open range (0 to n-1), the usual `for (int k = 0; k < n; k++)`.
            for k in 0..<n {
                let sx = x + 1 + k * (cwid + 1)
                cX.append(sx)
                cW.append(k == n - 1 ? (x + w - 1 - sx) : cwid)
                if k > 0 { seps.append(sx - 1) }
            }
        }
        colX = cX

        // Frame details
        s.put(x, sepY, "╟", fg, bg)
        s.put(x + w - 1, sepY, "╢", fg, bg)
        for i in 1..<(w - 1) { s.put(x + i, sepY, "─", fg, bg) }
        for sx in seps {
            s.put(sx, y, "╤", fg, bg)
            for yy in (y + 1)..<sepY { s.put(sx, yy, "│", fg, bg) }
            s.put(sx, sepY, "┴", fg, bg)
        }

        // Column headers
        // Index of the Size separator (Attr column sits before it when enabled)
        let sz0 = perms ? 1 : 0
        if mode == .full {
            s.text(cX[0], y + 1, fit("Name", cW[0], .center), Col.yellow, bg)
            if perms { s.text(seps[0] + 1, y + 1, fit("Attr", 10, .center), Col.yellow, bg) }
            s.text(seps[sz0] + 1, y + 1, fit("Size", 9, .center), Col.yellow, bg)
            s.text(seps[sz0 + 1] + 1, y + 1, fit("Date", 8, .center), Col.yellow, bg)
            s.text(seps[sz0 + 2] + 1, y + 1, fit("Time", 5, .center), Col.yellow, bg)
        } else {
            for k in cX.indices { s.text(cX[k], y + 1, fit("Name", cW[k], .center), Col.yellow, bg) }
        }

        // Keep the cursor inside the visible page: scroll up if above `top`, down if below the last visible entry,
        // then clamp so the page is never scrolled past the end of the listing.
        // Scrolling
        listRows = rowsN
        listCols = cX.count
        let per = rowsN * listCols
        if cursor < top { top = cursor }
        if cursor >= top + per { top = cursor - per + 1 }
        top = max(0, min(top, max(0, entries.count - per)))

        // Entries
        for i in 0..<per {
            let idx = top + i
            guard idx < entries.count else { break }
            let e = entries[idx]
            // Entry i of the page goes to column k, row r (column-major layout).
            let k = i / rowsN, r = i % rowsN
            let yy = listY + r
            let isCur = active && idx == cursor
            let isSel = selected.contains(e.name)
            // Colours: selected yellow, directories white, hidden cyan, other files light cyan. `UInt8` is an unsigned byte palette index.
            var efg: UInt8 = isSel ? Col.yellow : (e.isDir ? Col.white : (e.isHidden ? Col.cyan : Col.lcyan))
            let ebg = isCur ? Col.cyan : bg
            // Cursor bar is cyan with black text, but selected entries keep yellow text so the selection stays visible.
            if isCur && !isSel { efg = Col.black }
            s.text(cX[k], yy, fit(e.name, cW[k]), efg, ebg)
            if mode == .full {
                for sx in seps { s.put(sx, yy, "│", isCur ? Col.black : fg, ebg) }
                if perms { s.text(seps[0] + 1, yy, e.isUp ? spaces(10) : e.permString, efg, ebg) }
                s.text(seps[sz0] + 1, yy, fit(sizeText(e), 9, .right), efg, ebg)
                s.text(seps[sz0 + 1] + 1, yy, e.isUp ? spaces(8) : dateFmt.string(from: e.date), efg, ebg)
                s.text(seps[sz0 + 2] + 1, yy, e.isUp ? spaces(5) : timeFmt.string(from: e.date), efg, ebg)
            }
        }

        // Mini status line
        let sy = y + h - 2
        if !selected.isEmpty {
            // `reduce(initial) { acc, e in ... }` ≈ stream reduce; here $0 is the running total and $1 the entry.
            // `(dirSizes[...] ?? nil) ?? 0` flattens the double optional: missing key or scan in progress both count as 0.
            let files = entries.filter { selected.contains($0.name) }
            let total = files.reduce(Int64(0)) { $0 + ($1.isDir ? ((dirSizes[$1.name] ?? nil) ?? 0) : $1.size) }
            // `\(expr)` is string interpolation, like a template; this pluralises "file" when needed.
            let t = " \(groupNum(total)) bytes in \(files.count) selected file\(files.count == 1 ? "" : "s") "
            s.text(x + 1, sy, fit(t, iw, .center), Col.yellow, bg)
        } else if let e = current {
            // No selection: show name (with an arrow for symlinks), size, date and time of the entry under the cursor.
            let sz = fit(sizeText(e), 9, .right)
            let right = sz + " " + (e.isUp ? spaces(8) : dateFmt.string(from: e.date)) + " "
                + (e.isUp ? spaces(5) : timeFmt.string(from: e.date))
            let nw = max(1, iw - right.count - 1)
            s.text(x + 1, sy, fit(e.isLink ? e.name + " →" : e.name, nw), fg, bg)
            s.text(x + 2 + nw, sy, String(right.prefix(max(0, iw - nw - 1))), fg, bg)
        }

        // Path title and free space
        // Title is centred on the top border; it must stay inside the corners and clear of the clock.
        let usable = max(4, w - 4 - reserveRight)
        let title = " " + shortPath(displayPath(path), usable - 2) + " "
        var tx = x + (w - title.count) / 2
        let maxEnd = x + w - 2 - reserveRight
        if tx + title.count > maxEnd { tx = max(x + 2, maxEnd - title.count) }
        s.text(tx, y, title, active ? Col.black : fg, active ? Col.cyan : bg)
        // `if let fs = freeSpace` runs the block only when the optional holds a value.
        if let fs = freeSpace {
            let t = " \(human(fs)) free "
            if t.count < w - 4 { s.text(x + (w - t.count) / 2, y + h - 1, t, fg, bg) }
        }
    }
}
