import Foundation

/// Read / write key=value lines in ~/.config/conterm/config. Used by
/// the Settings panel's theme + font controls so toggling a swatch
/// rewrites a single line and triggers a libghostty config reload —
/// without nuking the user's hand-written customization above.
@MainActor
enum UserConfigStore {
    static var path: String {
        let home = NSHomeDirectory()
        return "\(home)/.config/conterm/config"
    }

    /// Parsed config keyed by the file's modification date. A whole-file
    /// parse on every single-key lookup is wasteful — launch alone reads
    /// theme + font-family + font-size. The mtime guard keeps the cache
    /// honest against external edits (hand-edits, Reload).
    private static var cache: (mtime: Date, values: [String: String])?

    /// Read a single key's value. Returns nil if the key isn't set or
    /// is commented out. Last-write-wins (matches libghostty's parser).
    static func read(key: String) -> String? {
        parsed()[key]
    }

    private static func parsed() -> [String: String] {
        let mtime = (try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if let cache, let mtime, cache.mtime == mtime {
            return cache.values
        }
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            cache = nil
            return [:]
        }
        var values: [String: String] = [:]
        for raw in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Match `<key> = …` allowing leading whitespace. Last
            // assignment wins, so a later line overwrites an earlier one.
            guard let eq = line.firstIndex(of: "=") else { continue }
            let lhs = line[..<eq].trimmingCharacters(in: .whitespaces)
            values[lhs] = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let mtime { cache = (mtime, values) }
        return values
    }

    /// Replace (or append) `key = value` and re-write the file. The new
    /// value is written verbatim — if it should be quoted (e.g. theme
    /// names with spaces), the caller wraps it. Empty `value` *removes*
    /// the key (so users can fall back to inheriting the bundled
    /// default).
    static func write(key: String, value: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true)
        var lines: [String] = (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init) ?? []

        let pattern = "^[ \\t]*\(NSRegularExpression.escapedPattern(for: key))[ \\t]*=.*$"
        let regex = try? NSRegularExpression(pattern: pattern)

        var replaced = false
        for i in lines.indices {
            let line = lines[i]
            // Skip commented lines — let users keep `# theme = X` notes.
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            if stripped.hasPrefix("#") { continue }
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            if regex?.firstMatch(in: line, range: range) != nil {
                if value.isEmpty {
                    lines[i] = ""
                } else {
                    lines[i] = "\(key) = \(value)"
                }
                replaced = true
                break
            }
        }
        if !replaced && !value.isEmpty {
            // Trim trailing blank lines, then add ours with a separating
            // blank so the file stays tidy on repeated writes.
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            lines.append("")
            lines.append("\(key) = \(value)")
        }
        // Collapse 3+ consecutive blank lines down to one — keeps the
        // file from growing whitespace forever.
        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 1 { collapsed.append(line) }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }
        let joined = collapsed.joined(separator: "\n") + "\n"
        try? joined.write(toFile: path, atomically: true, encoding: .utf8)
        // Drop the parse cache — a same-second rewrite can land on an
        // unchanged mtime, which would otherwise serve stale values.
        cache = nil
    }

    /// Quote a value if it contains spaces. Theme names + font families
    /// often need this.
    static func quote(_ s: String) -> String {
        if s.isEmpty { return s }
        if s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return s }
        return "\"\(s)\""
    }

    // MARK: - Managed theme block

    // Sentinels bounding the picker-owned theme block. Kept verbatim so
    // `strippingManagedThemeBlock` can find and replace it on each pick.
    static let themeBlockBegin =
        "# >>> conterm theme (managed — set in Settings ▸ Appearance; edits here are overwritten)"
    static let themeBlockEnd = "# <<< conterm theme"
    private static let themeIDMarker = "# conterm-theme-id = "

    /// Apply a theme by appending its colors as EXPLICIT keys at EOF.
    /// Ghostty resolves `background`/`foreground`/`palette` set anywhere
    /// in the config — even a `config-file`-included one — above a bare
    /// `theme =` line, so a hardcoded palette silently shadows the pick.
    /// Emitting the theme's own colors as the LAST explicit keys makes
    /// the pick win regardless. Non-destructive: the user's earlier lines
    /// stay (just overridden); removing this block restores them.
    /// `colorLines` are verbatim `key = value` lines from the theme file.
    static func writeManagedThemeBlock(themeID: String, colorLines: [String]) {
        var lines = currentLines()
        lines = strippingManagedThemeBlock(lines)
        lines = strippingTopLevelTheme(lines)
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        lines.append("")
        lines.append(themeBlockBegin)
        // Name recorded as a comment (not an active `theme =`) so the
        // colors below are self-sufficient — no dependency on libghostty
        // resolving the theme by name.
        lines.append("\(themeIDMarker)\(themeID)")
        lines.append(contentsOf: colorLines)
        lines.append(themeBlockEnd)
        persist(lines)
    }

    /// Drop the managed theme block so the user's own config (and any
    /// `config-file`-included Ghostty config) sets the colors again.
    static func removeManagedThemeBlock() {
        let lines = strippingManagedThemeBlock(currentLines())
        persist(lines)
    }

    /// The theme id recorded inside the managed block, if present — the
    /// picker's current selection. nil when the block is absent (the
    /// user's config owns the colors).
    static func managedThemeID() -> String? {
        let lines = currentLines()
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == themeBlockBegin
        }) else { return nil }
        for line in lines[start...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == themeBlockEnd { break }
            if t.hasPrefix(themeIDMarker) {
                return String(t.dropFirst(themeIDMarker.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func currentLines() -> [String] {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
    }

    private static func persist(_ lines: [String]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true)
        let joined = lines.joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n")) + "\n"
        try? joined.write(toFile: path, atomically: true, encoding: .utf8)
        cache = nil
    }

    /// Remove the managed block (begin…end inclusive). Tolerates a
    /// missing end sentinel by cutting to EOF.
    private static func strippingManagedThemeBlock(_ lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == themeBlockBegin
        }) else { return lines }
        let end = lines[start...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == themeBlockEnd
        }) ?? (lines.count - 1)
        var result = lines
        result.removeSubrange(start...min(end, lines.count - 1))
        return result
    }

    /// Drop any uncommented top-level `theme = …` line — the picker owns
    /// the theme key now, so a stray earlier assignment can't linger.
    private static func strippingTopLevelTheme(_ lines: [String]) -> [String] {
        lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { return true }
            guard let eq = t.firstIndex(of: "=") else { return true }
            return t[..<eq].trimmingCharacters(in: .whitespaces) != "theme"
        }
    }
}
