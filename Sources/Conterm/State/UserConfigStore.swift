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

    /// Read a single key's value. Returns nil if the key isn't set or
    /// is commented out. Last-write-wins (matches libghostty's parser).
    static func read(key: String) -> String? {
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        var hit: String?
        for raw in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Match `<key> = …` allowing leading whitespace.
            guard let eq = line.firstIndex(of: "=") else { continue }
            let lhs = line[..<eq].trimmingCharacters(in: .whitespaces)
            if lhs == key {
                hit = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return hit
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
    }

    /// Quote a value if it contains spaces. Theme names + font families
    /// often need this.
    static func quote(_ s: String) -> String {
        if s.isEmpty { return s }
        if s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return s }
        return "\"\(s)\""
    }
}
