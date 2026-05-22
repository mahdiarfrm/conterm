import Foundation

/// One previously-run shell command, ready to be re-run from the
/// command palette.
struct HistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let command: String
}

/// Best-effort reader for the user's shell history. Looks at zsh
/// (`~/.zsh_history` — extended format) and bash (`~/.bash_history`),
/// in that order. Dedupes and returns newest-first.
enum ShellHistory {
    /// Cap on entries we keep in memory. Most shells store thousands;
    /// we only need enough for fuzzy-search to feel rich. Anything
    /// older than this in the file is dropped.
    private static let cap = 2000

    static func loadAll() -> [HistoryEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let zsh  = "\(home)/.zsh_history"
        let bash = "\(home)/.bash_history"

        var all: [String] = []
        // Zsh's extended history file format: `: timestamp:duration;command`
        // when `setopt EXTENDED_HISTORY`, plain `command` otherwise.
        // Multi-line commands continue with a trailing `\`.
        if let zshLines = readLines(zsh) {
            all.append(contentsOf: parseZsh(zshLines))
        }
        if let bashLines = readLines(bash) {
            // Bash history has plain command lines, occasionally with
            // `#timestamp` markers above if `HISTTIMEFORMAT` is set —
            // we just skip those.
            all.append(contentsOf: bashLines.filter { !$0.hasPrefix("#") && !$0.isEmpty })
        }
        // Reverse so newest is first (history files are append-only,
        // newest at the bottom).
        all.reverse()
        // Dedupe preserving order.
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0).inserted }
        return Array(unique.prefix(cap)).map { HistoryEntry(command: $0) }
    }

    private static func readLines(_ path: String) -> [String]? {
        // zsh's history can contain bytes that aren't valid UTF-8
        // (because the file is stored in the shell's locale, often
        // metafied). Try UTF-8 first, fall back to latin-1 so the
        // reader doesn't silently give up on a few stray bytes.
        if let data = try? String(contentsOfFile: path, encoding: .utf8) {
            return data.components(separatedBy: .newlines)
        }
        if let data = try? String(contentsOfFile: path, encoding: .isoLatin1) {
            return data.components(separatedBy: .newlines)
        }
        return nil
    }

    private static func parseZsh(_ lines: [String]) -> [String] {
        var out: [String] = []
        var continued: String?
        for raw in lines {
            // Continuation handling: zsh stores multi-line commands
            // with a trailing `\` on each non-final line.
            if var cont = continued {
                cont += "\n" + raw
                if raw.hasSuffix("\\") {
                    cont.removeLast()
                    continued = cont
                } else {
                    out.append(strip(cont))
                    continued = nil
                }
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Extended format: ": <ts>:<dur>;<cmd>". Drop the prefix.
            var body = trimmed
            if trimmed.hasPrefix(":") {
                if let semi = trimmed.firstIndex(of: ";") {
                    body = String(trimmed[trimmed.index(after: semi)...])
                }
            }
            if body.hasSuffix("\\") {
                body.removeLast()
                continued = body
            } else {
                out.append(strip(body))
            }
        }
        return out.filter { !$0.isEmpty }
    }

    private static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
