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

    /// Project directories, most recently used first. Read from disk, so call
    /// this when a menu opens rather than from a SwiftUI body.
    static func recent(limit: Int = 12) -> [String] {
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
            .prefix(limit)
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
        guard let path = newest?.path,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
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
