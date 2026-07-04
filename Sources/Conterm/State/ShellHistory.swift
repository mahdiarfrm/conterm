import Foundation

/// One previously-run shell command, ready to be re-run from the
/// command palette.
struct HistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let command: String
    /// When the command was last run, from zsh's extended-history
    /// timestamp. nil for bash / non-extended zsh history, which carry
    /// no time — those fall back to file order for recency.
    var date: Date? = nil
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

        var all: [(command: String, date: Date?)] = []
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
            all.append(contentsOf: bashLines
                .filter { !$0.hasPrefix("#") && !$0.isEmpty }
                .map { (command: $0, date: nil) })
        }
        // Reverse so newest is first (history files are append-only,
        // newest at the bottom).
        all.reverse()
        // Dedupe preserving order — keep the newest occurrence's timestamp.
        var seen = Set<String>()
        var unique: [(command: String, date: Date?)] = []
        for e in all where seen.insert(e.command).inserted { unique.append(e) }
        return unique.prefix(cap).map { HistoryEntry(command: $0.command, date: $0.date) }
    }

    /// Per-day command activity for the session-stats widget. Only zsh
    /// extended-history entries carry timestamps, so bash and plain zsh
    /// history contribute nothing — callers treat an empty result as
    /// "no data" and hide. Unlike `loadAll` this keeps duplicates
    /// (every run counts) and reads the whole file.
    struct Activity {
        /// startOfDay → number of commands run that day.
        var dayCounts: [Date: Int] = [:]
        /// Raw command lines run today, for top-command ranking.
        var todayCommands: [String] = []
    }

    static func activity(now: Date = Date()) -> Activity {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let lines = readLines("\(home)/.zsh_history") else { return Activity() }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        var act = Activity()
        for entry in parseZsh(lines) {
            guard let date = entry.date else { continue }
            let day = cal.startOfDay(for: date)
            act.dayCounts[day, default: 0] += 1
            if day == todayStart { act.todayCommands.append(entry.command) }
        }
        return act
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

    private static func parseZsh(_ lines: [String]) -> [(command: String, date: Date?)] {
        var out: [(command: String, date: Date?)] = []
        var continued: (text: String, date: Date?)?
        for raw in lines {
            // Continuation handling: zsh stores multi-line commands
            // with a trailing `\` on each non-final line.
            if var cont = continued {
                cont.text += "\n" + raw
                if raw.hasSuffix("\\") {
                    cont.text.removeLast()
                    continued = cont
                } else {
                    out.append((strip(cont.text), cont.date))
                    continued = nil
                }
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Extended format: ": <ts>:<dur>;<cmd>". Pull the epoch
            // timestamp out of the header, then drop the prefix.
            var body = trimmed
            var date: Date?
            if trimmed.hasPrefix(":"), let semi = trimmed.firstIndex(of: ";") {
                let header = trimmed[trimmed.index(after: trimmed.startIndex)..<semi]
                if let tsField = header.split(separator: ":").first,
                   let ts = TimeInterval(tsField.trimmingCharacters(in: .whitespaces)) {
                    date = Date(timeIntervalSince1970: ts)
                }
                body = String(trimmed[trimmed.index(after: semi)...])
            }
            if body.hasSuffix("\\") {
                body.removeLast()
                continued = (body, date)
            } else {
                out.append((strip(body), date))
            }
        }
        return out.filter { !$0.command.isEmpty }
    }

    private static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
