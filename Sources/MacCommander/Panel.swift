import AppKit
import Darwin

struct FileEntry {
    var name: String
    var url: URL
    var isDir: Bool
    var isLink = false
    var isPackage = false
    var isHidden = false
    var size: Int64 = 0
    var date: Date = .distantPast
    var mode: UInt16 = 0
    var isUp: Bool { name == ".." }

    /// Unix permission string like "drwxr-xr-x" (with setuid/setgid/sticky as s/S, t/T).
    var permString: String {
        let m = Int(mode)
        let type: Character = isLink ? "l" : (m & Int(S_IFMT) == Int(S_IFDIR) ? "d" : "-")
        var out = [type]
        let bits: [(Int, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"),
                                        (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                        (0o004, "r"), (0o002, "w"), (0o001, "x")]
        for (b, c) in bits { out.append(m & b != 0 ? c : "-") }
        func special(_ flag: Int, _ idx: Int, _ on: Character, _ off: Character) {
            if m & flag != 0 { out[idx] = out[idx] == "x" ? on : off }
        }
        special(0o4000, 3, "s", "S")
        special(0o2000, 6, "s", "S")
        special(0o1000, 9, "t", "T")
        return String(out)
    }
}

enum PanelMode: String { case brief, full }
enum SortMode: String { case name, ext, time, size, unsorted }

final class Panel {
    private(set) var path: String = "/"
    var entries: [FileEntry] = []
    var cursor = 0
    var top = 0
    var selected = Set<String>()
    /// Recursively computed directory sizes (by name); nil value = scan in progress.
    var dirSizes: [String: Int64?] = [:]
    /// Bumped on every directory change so stale scans are discarded.
    private(set) var generation = 0
    var mode: PanelMode = .full
    var sort: SortMode = .name { didSet { reload() } }
    var showHidden = false
    /// Extra "Attr" column with Unix permissions (full mode only).
    var showPerms = false
    var visible = true
    var freeSpace: Int64?
    var listRows = 20
    var listCols = 1
    private var colX: [Int] = [0]

    init(path: String) {
        if cd(path) != nil, cd(NSHomeDirectory()) != nil { _ = cd("/") }
    }

    var current: FileEntry? { entries.indices.contains(cursor) ? entries[cursor] : nil }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var pageSize: Int { max(1, listRows * listCols) }

    // MARK: Loading

    static func list(_ path: String, hidden: Bool, sort: SortMode) throws -> [FileEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isSymbolicLinkKey, .isHiddenKey, .isPackageKey]
        let items = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: hidden ? [] : [.skipsHiddenFiles])
        var res: [FileEntry] = items.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            var isDir = v?.isDirectory ?? false
            let isLink = v?.isSymbolicLink ?? false
            if isLink {
                var b: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &b) { isDir = b.boolValue }
            }
            let name = u.lastPathComponent.precomposedStringWithCanonicalMapping
            var st = stat()
            let mode = lstat(u.path, &st) == 0 ? UInt16(st.st_mode) : 0
            return FileEntry(name: name, url: u, isDir: isDir, isLink: isLink,
                             isPackage: v?.isPackage ?? false,
                             isHidden: (v?.isHidden ?? false) || name.hasPrefix("."),
                             size: Int64(v?.fileSize ?? 0),
                             date: v?.contentModificationDate ?? .distantPast, mode: mode)
        }
        func ext(_ e: FileEntry) -> String { e.isDir ? "" : (e.name as NSString).pathExtension.lowercased() }
        func byName(_ a: FileEntry, _ b: FileEntry) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        if sort != .unsorted {
            res.sort { a, b in
                if a.isDir != b.isDir { return a.isDir }
                switch sort {
                case .name, .unsorted: return byName(a, b)
                case .ext:
                    let ea = ext(a), eb = ext(b)
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

    /// Returns an error message, or nil on success.
    @discardableResult
    func cd(_ newPath: String, focus: String? = nil) -> String? {
        var p = (newPath as NSString).standardizingPath
        if p.isEmpty { p = "/" }
        do {
            let list = try Panel.list(p, hidden: showHidden, sort: sort)
            path = p
            entries = list
            selected = []
            dirSizes = [:]
            generation += 1
            top = 0
            let f = focus?.precomposedStringWithCanonicalMapping
            cursor = f.flatMap { n in list.firstIndex { $0.name == n } } ?? 0
            updateFree()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func goUp() -> String? {
        guard path != "/" else { return nil }
        let name = (path as NSString).lastPathComponent
        return cd((path as NSString).deletingLastPathComponent, focus: name)
    }

    func reload(focus: String? = nil) {
        let keep = focus?.precomposedStringWithCanonicalMapping ?? current?.name
        guard let list = try? Panel.list(path, hidden: showHidden, sort: sort) else {
            var p = path
            while p != "/" {
                p = (p as NSString).deletingLastPathComponent
                if cd(p) == nil { return }
            }
            return
        }
        let old = cursor
        entries = list
        selected = selected.intersection(Set(list.map { $0.name }))
        dirSizes = dirSizes.filter { k, _ in list.contains { $0.name == k && $0.isDir } }
        if let k = keep, let i = list.firstIndex(where: { $0.name == k }) {
            cursor = i
        } else {
            cursor = min(old, max(0, list.count - 1))
        }
        updateFree()
    }

    func updateFree() {
        freeSpace = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Navigation & selection

    func move(_ d: Int) {
        guard !entries.isEmpty else { return }
        cursor = max(0, min(entries.count - 1, cursor + d))
    }

    func toggleSelect() {
        guard let c = current, !c.isUp else { return }
        if selected.contains(c.name) { selected.remove(c.name) } else { selected.insert(c.name) }
    }

    /// Size shown in the Size column: computed total for scanned directories.
    func sizeText(_ e: FileEntry) -> String {
        if e.isUp { return "►UP--DIR◄" }
        guard e.isDir else { return sizeString(e.size) }
        switch dirSizes[e.name] {
        case .some(.some(let n)): return sizeString(n)
        case .some(.none): return "…"
        case .none: return "►SUB-DIR◄"
        }
    }

    func targets() -> [FileEntry] {
        let sel = entries.filter { selected.contains($0.name) && !$0.isUp }
        if !sel.isEmpty { return sel }
        if let c = current, !c.isUp { return [c] }
        return []
    }

    func select(pattern: String, on: Bool) {
        let pats = pattern.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0 == "*.*" ? "*" : $0 }
        for e in entries where !e.isUp && !e.isDir {
            if pats.contains(where: { fnmatch($0, e.name, FNM_CASEFOLD) == 0 }) {
                if on { selected.insert(e.name) } else { selected.remove(e.name) }
            }
        }
    }

    func invert() {
        for e in entries where !e.isUp && !e.isDir {
            if selected.contains(e.name) { selected.remove(e.name) } else { selected.insert(e.name) }
        }
    }

    /// Entry index under an absolute screen position (panel is always at y = 0).
    func index(atX ax: Int, y ay: Int) -> Int? {
        let r = ay - 2
        guard r >= 0, r < listRows else { return nil }
        var k = 0
        for (i, cx) in colX.enumerated() where ax >= cx { k = i }
        let idx = top + k * listRows + r
        return idx < entries.count ? idx : nil
    }

    // MARK: Rendering

    /// `reserveRight`: columns at the right end of the top border that are covered (clock).
    func render(_ s: Screen, x: Int, y: Int, w: Int, h: Int, active: Bool, reserveRight: Int = 0) {
        let fg = Col.lcyan, bg = Col.blue
        s.fill(x, y, w, h, fg, bg)
        guard w >= 20, h >= 6 else { return }
        s.box(x, y, w, h, fg, bg)
        let iw = w - 2
        let listY = y + 2
        let rowsN = max(1, h - 5)
        let sepY = y + h - 3

        var cX: [Int] = [], cW: [Int] = [], seps: [Int] = []
        // Full mode: Name │ [Attr 10] │ Size 9 │ Date 8 │ Time 5
        let perms = mode == .full && showPerms && iw - 36 >= 8
        if mode == .full {
            let nw = max(1, iw - 25 - (perms ? 11 : 0))
            cX = [x + 1]; cW = [nw]
            var sx = x + 1 + nw
            seps = [sx]
            if perms { sx += 11; seps.append(sx) }
            seps += [sx + 10, sx + 19]
        } else {
            let n = 3, cwid = max(1, (iw - (n - 1)) / n)
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
            let k = i / rowsN, r = i % rowsN
            let yy = listY + r
            let isCur = active && idx == cursor
            let isSel = selected.contains(e.name)
            var efg: UInt8 = isSel ? Col.yellow : (e.isDir ? Col.white : (e.isHidden ? Col.cyan : Col.lcyan))
            let ebg = isCur ? Col.cyan : bg
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
            let files = entries.filter { selected.contains($0.name) }
            let total = files.reduce(Int64(0)) { $0 + ($1.isDir ? ((dirSizes[$1.name] ?? nil) ?? 0) : $1.size) }
            let t = " \(groupNum(total)) bytes in \(files.count) selected file\(files.count == 1 ? "" : "s") "
            s.text(x + 1, sy, fit(t, iw, .center), Col.yellow, bg)
        } else if let e = current {
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
        if let fs = freeSpace {
            let t = " \(human(fs)) free "
            if t.count < w - 4 { s.text(x + (w - t.count) / 2, y + h - 1, t, fg, bg) }
        }
    }
}
