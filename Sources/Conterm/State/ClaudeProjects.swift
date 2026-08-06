import Foundation

/// The directories you have run Claude in.
///
/// Claude keeps one folder per project under `~/.claude/projects`, named by
/// mangling the path — `/` and `.` both become `-`, which cannot be undone, so
/// the real path is read out of a transcript inside instead. That mangling is
/// also what makes the folder's *existence* a reliable answer to "has this
/// directory been trusted before", which is the question that decides whether a
/// new session will stop on Claude's trust prompt.
@MainActor
enum ClaudeProjects {
    static var root: String { "\(NSHomeDirectory())/.claude/projects" }

    /// Whether Claude has been run here before. A first run in a directory
    /// stops on "do you trust the files in this folder", and a session waiting
    /// on that is not a session that is working.
    static func isTrusted(_ directory: String) -> Bool {
        let path = "\(root)/\(AgentTranscriptStore.encode(cwd: directory))"
        return FileManager.default.fileExists(atPath: path)
    }

    /// The last answer, and when it was taken.
    ///
    /// Cached hard, because SwiftUI evaluates a `Menu`'s content eagerly and
    /// re-evaluates it with the view it lives in — so a menu built from this
    /// list asks for it on every frame the map draws. Uncached, that meant
    /// walking every project directory and reading a transcript out of each
    /// one, per frame, and a real Claude history runs to hundreds of megabytes.
    private static var cache: (at: Date, dirs: [String])?
    private static let cacheTTL: TimeInterval = 60

    /// Project directories, most recently used first.
    static func recent(limit: Int = 12) -> [String] {
        if let cache, Date().timeIntervalSince(cache.at) < cacheTTL {
            return Array(cache.dirs.prefix(limit))
        }
        let dirs = scan()
        cache = (Date(), dirs)
        return Array(dirs.prefix(limit))
    }

    private static func scan() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var dated: [(path: String, at: Date)] = []
        for name in names where !name.hasPrefix(".") {
            let dir = "\(root)/\(name)"
            guard let cwd = cwd(inProjectDirectory: dir),
                  fm.fileExists(atPath: cwd) else { continue }
            let at = (try? fm.attributesOfItem(atPath: dir)[.modificationDate]) as? Date
            dated.append((cwd, at ?? .distantPast))
        }
        var seen = Set<String>()
        return dated.sorted { $0.at > $1.at }
            .filter { seen.insert($0.path).inserted }
            .map(\.path)
    }

    /// The working directory a project folder stands for, taken from the newest
    /// transcript in it. `cwd` is not on the first line — the session header
    /// comes first — so a few lines are scanned before giving up.
    private static func cwd(inProjectDirectory dir: String) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let newest = files
            .filter { $0.hasSuffix(".jsonl") }
            .map { (path: "\(dir)/\($0)",
                    at: ((try? fm.attributesOfItem(atPath: "\(dir)/\($0)")[.modificationDate])
                         as? Date) ?? .distantPast) }
            .max { $0.at < $1.at }
        // Only the head of the file. `cwd` sits a couple of lines in, and a
        // long session's transcript is measured in megabytes — reading one
        // whole to learn its directory is the kind of thing that is fine once
        // and ruinous in a loop.
        guard let path = newest?.path,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: head, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// A path as you would say it out loud: the home directory as `~`, and only
    /// the last two components, since a menu of full paths is a menu you read
    /// rather than scan.
    static func shortLabel(_ path: String) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return p }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}
