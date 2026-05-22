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
