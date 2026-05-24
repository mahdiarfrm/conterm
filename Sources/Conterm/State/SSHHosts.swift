import Foundation

/// Lightweight recents tracker for the SSH palette section.
/// Stored in UserDefaults so the list survives relaunch. Capped at
/// 10 entries; touching an existing alias moves it to the top.
enum SSHRecents {
    private static let key = "conterm.ssh.recents"
    private static let cap = 10

    static func load() -> [String] {
        let ud = UserDefaults.standard
        return (ud.array(forKey: key) as? [String]) ?? []
    }

    static func push(_ alias: String) {
        var list = load()
        list.removeAll { $0 == alias }
        list.insert(alias, at: 0)
        if list.count > cap { list.removeLast(list.count - cap) }
        UserDefaults.standard.set(list, forKey: key)
    }
}

/// Scans the user's shell history for `ssh <target>` invocations and
/// returns the unique targets newest-first. Surfaces hosts the user
/// actually `ssh`'d to from the shell, alongside entries from
/// `~/.ssh/config`, in the command palette's "Recent" section.
enum SSHHistory {
    /// `ssh` flags that take a separate argument, so when scanning a
    /// command line for the host we skip the next token after these.
    private static let flagsWithArg: Set<String> = [
        "-p", "-i", "-l", "-L", "-R", "-D", "-F", "-o", "-J",
        "-W", "-c", "-m", "-e", "-Q", "-b", "-B", "-I", "-S",
    ]

    /// Returns up to `limit` unique SSH targets, ordered newest first.
    /// Sort uses the zsh extended-format timestamp when available
    /// (`: <ts>:<dur>;<cmd>`) and falls back to file position for
    /// plain bash entries.
    static func recentTargets(limit: Int = 30) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var entries: [(time: Double, target: String)] = []
        var fallback: Double = 0

        // zsh
        if let zsh = readFile("\(home)/.zsh_history") {
            for raw in zsh.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                let (ts, cmd) = parseZshLine(line, fallback: &fallback)
                if let target = extractTarget(cmd) {
                    entries.append((ts, target))
                }
            }
        }
        // bash (no per-line timestamps unless HISTTIMEFORMAT is set, which
        // we don't try to parse — just use file order)
        if let bash = readFile("\(home)/.bash_history") {
            for raw in bash.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                fallback += 1
                if let target = extractTarget(line) {
                    entries.append((fallback, target))
                }
            }
        }

        // Newest first by actual timestamp (or fallback file-position).
        entries.sort { $0.time > $1.time }

        // Dedup preserving the newest occurrence (now first by the sort).
        var seen = Set<String>()
        var out: [String] = []
        for e in entries {
            if seen.insert(e.target).inserted {
                out.append(e.target)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Parses a single zsh history line. Returns the real epoch
    /// timestamp from extended format (`: 1730000000:0;ssh foo`)
    /// alongside the command text, or — for plain entries with no
    /// timestamp — the next value from `fallback` so file order
    /// still acts as a stable sort key.
    private static func parseZshLine(_ line: String,
                                      fallback: inout Double) -> (Double, String) {
        if line.hasPrefix(":") {
            // ":<sp>?<ts>:<dur>;<cmd>"
            let after = line.dropFirst()
            if let firstColon = after.firstIndex(of: ":"),
               let semi = after.firstIndex(of: ";"),
               firstColon < semi {
                let tsStr = after[after.startIndex..<firstColon]
                    .trimmingCharacters(in: .whitespaces)
                if let ts = Double(tsStr), ts > 0 {
                    let cmd = String(after[after.index(after: semi)...])
                    return (ts, cmd)
                }
            }
        }
        fallback += 1
        return (fallback, line)
    }

    private static func readFile(_ path: String) -> String? {
        if let s = try? String(contentsOfFile: path, encoding: .utf8) {
            return s
        }
        return try? String(contentsOfFile: path, encoding: .isoLatin1)
    }

    /// Returns the target host of an `ssh` invocation (`host`,
    /// `user@host`, etc.), or nil for any other command. Skips over
    /// flags and their arguments, so `ssh -p 22 -i ~/.ssh/k user@h`
    /// returns `user@h`.
    private static func extractTarget(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        // First token must be exactly `ssh` — not `sshfs`, not `sshpass`,
        // not `ssh-add`, etc., which would each pollute the list.
        guard parts.first == "ssh" else { return nil }
        var i = 1
        while i < parts.count {
            let p = parts[i]
            if p.hasPrefix("-") {
                i += flagsWithArg.contains(p) ? 2 : 1
            } else {
                return p
            }
        }
        return nil
    }
}

/// One entry from the user's `~/.ssh/config`. Wildcards (`Host *`,
/// `Host *.example.com`) are excluded — only concrete aliases the
/// user can actually type at a shell.
struct SSHHost: Identifiable, Hashable {
    var id: String { alias }
    let alias: String
    /// Optional resolved hostname (the `Hostname` field, if present)
    /// — shown as a subtitle so the user can disambiguate aliases
    /// that look similar.
    let hostname: String?
}

/// Reads `~/.ssh/config` (and any `Include` files it pulls in) and
/// returns the user's named ssh hosts. Cached for the lifetime of
/// the process; cheap to rebuild on demand if the user edits config.
enum SSHHosts {
    /// Concrete (non-wildcard) Host aliases, sorted alphabetically.
    static func loadAll() -> [SSHHost] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let primary = "\(home)/.ssh/config"
        var visited = Set<String>()
        var hosts: [SSHHost] = []
        parse(path: primary, visited: &visited, out: &hosts)
        // Dedupe by alias, keeping the first occurrence's hostname.
        var seen = Set<String>()
        let unique = hosts.filter { seen.insert($0.alias).inserted }
        return unique.sorted { $0.alias.lowercased() < $1.alias.lowercased() }
    }

    /// Recursive parser that follows `Include` directives. The
    /// `visited` set prevents include loops.
    private static func parse(path: String,
                               visited: inout Set<String>,
                               out: inout [SSHHost]) {
        let resolved = (path as NSString).expandingTildeInPath
        guard !visited.contains(resolved) else { return }
        visited.insert(resolved)
        guard let data = try? String(contentsOfFile: resolved, encoding: .utf8)
        else { return }

        // Streaming pass: when we see `Host x y z`, record those
        // aliases and watch for a `Hostname` line in the same block
        // until the next `Host`/`Match`/EOF.
        var currentAliases: [String] = []
        var currentHostname: String?
        func flush() {
            for a in currentAliases {
                out.append(SSHHost(alias: a, hostname: currentHostname))
            }
            currentAliases.removeAll(keepingCapacity: true)
            currentHostname = nil
        }
        for raw in data.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Field name = first whitespace-separated token,
            // case-insensitive per `man ssh_config`.
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let firstToken = parts.first else { continue }
            let field = firstToken.lowercased()
            let values = parts.dropFirst().map { String($0) }
            switch field {
            case "host":
                flush()
                // Filter out wildcard / negated aliases — we want
                // only ones the user can actually type as a target.
                currentAliases = values.filter { v in
                    !v.contains("*") && !v.contains("?") && !v.hasPrefix("!")
                }
            case "match":
                // Match blocks are conditional; skip what follows.
                flush()
            case "hostname":
                currentHostname = values.first
            case "include":
                // Each include path is relative to `~/.ssh/` per
                // ssh_config conventions.
                for inc in values {
                    let abs: String
                    if inc.hasPrefix("/") || inc.hasPrefix("~") {
                        abs = (inc as NSString).expandingTildeInPath
                    } else {
                        let sshDir = (resolved as NSString).deletingLastPathComponent
                        abs = (sshDir as NSString).appendingPathComponent(inc)
                    }
                    parse(path: abs, visited: &visited, out: &out)
                }
            default:
                break
            }
        }
        flush()
    }
}
