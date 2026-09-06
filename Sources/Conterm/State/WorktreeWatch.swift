import AppKit
import Foundation
import SwiftUI

/// What an agent has done to the working tree, per repository.
///
/// The status pill answers "is Claude thinking". This answers the question
/// that actually decides whether you let it keep going: *what has it
/// changed*. A repo is watched while an agent is live in it, and its
/// snapshot is kept after the agent stops so the review outlives the run.
///
/// Everything is measured against a **baseline commit** — the repo's HEAD
/// the first time an agent was seen working there. Working-tree edits are
/// diffed against HEAD; commits the agent made are `baseline..HEAD`. Either
/// alone lies: diffing HEAD only shows nothing once the agent commits, and
/// a commit list alone misses everything still uncommitted.
@MainActor
final class WorktreeWatch: ObservableObject {
    static let shared = WorktreeWatch()

    enum Status: String, Equatable {
        case modified, added, deleted, renamed, untracked

        var glyph: String {
            switch self {
            case .modified:  return "pencil"
            case .added:     return "plus"
            case .deleted:   return "minus"
            case .renamed:   return "arrow.right"
            case .untracked: return "questionmark"
            }
        }
    }

    /// One changed path. Counts are `nil` for binary files, which numstat
    /// reports as `-` rather than a number.
    struct FileChange: Identifiable, Equatable {
        var id: String { path }
        let path: String
        var added: Int?
        var removed: Int?
        var status: Status
        /// Set for renames; the path this file used to have.
        var renamedFrom: String?
        /// Staged in the index. An agent that runs `git add` but not
        /// `git commit` leaves work that `git diff` alone would miss.
        var staged = false

        /// Counts are absent for two different reasons, and the card says
        /// which: numstat reports `-` for a tracked binary, and an untracked
        /// file too large to read is simply not counted.
        var countsUnknown: Bool { added == nil && removed == nil }
        var isBinary: Bool { countsUnknown && status != .untracked }
    }

    /// A commit the agent made since the baseline.
    struct Commit: Identifiable, Equatable {
        let id: String          // short sha
        let subject: String
        let at: Date
        var files: Int
        var added: Int
        var removed: Int
    }

    struct Snapshot: Equatable {
        var root: String
        var branch: String
        /// Baseline commit — HEAD when the agent was first seen here.
        var baseline: String
        var files: [FileChange] = []
        var commits: [Commit] = []
        /// Truncated file list: repos with thousands of changes are a
        /// runaway, not a review, and the card says so rather than
        /// rendering for a minute.
        var truncated = false
        var computedAt = Date()

        var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) }
                        + commits.reduce(0) { $0 + $1.added } }
        var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) }
                          + commits.reduce(0) { $0 + $1.removed } }
        /// Paths touched, counting a path once whether it was committed or
        /// is still dirty.
        var fileCount: Int { files.count }
        var isEmpty: Bool { files.isEmpty && commits.isEmpty }

        /// "7 files · +240 −31", the one line the agent card carries.
        var summary: String {
            var parts: [String] = []
            if fileCount > 0 { parts.append("\(fileCount) file\(fileCount == 1 ? "" : "s")") }
            if !commits.isEmpty {
                parts.append("\(commits.count) commit\(commits.count == 1 ? "" : "s")")
            }
            parts.append("+\(added) −\(removed)")
            return parts.joined(separator: " · ")
        }
    }

    /// Keyed by repository root — two agents in one repo share a working
    /// tree, so they share a snapshot.
    @Published private(set) var snapshots: [String: Snapshot] = [:]

    /// Baseline commit per root, set when the root is first seen with a
    /// live agent and held until the snapshot is cleared.
    private var baselines: [String: String] = [:]
    /// Resolved repo root per pane cwd, cached — `rev-parse` on every tick
    /// for every agent pane is a subprocess we don't need to spawn.
    private var rootCache: [String: String?] = [:]
    /// Roots kept in the rotation after their agent stopped, so a review
    /// opened on a finished run keeps refreshing. Cleared by `acknowledge`.
    private var pinned: Set<String> = []

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var computing: Set<String> = []

    private init() {
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        inactiveObs = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if NSApp?.isActive ?? true { start() }
    }

    isolated deinit {
        timer?.invalidate()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    private func start() {
        guard timer == nil else { return }
        // 4 s: fast enough that a review opened right after a turn is
        // current, slow enough that a repo the size of a monorepo isn't
        // being statted continuously.
        let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 1
        timer = t
        refresh()
    }

    private func stop() { timer?.invalidate(); timer = nil }

    /// Snapshot for a pane, by its working directory.
    func snapshot(forCwd cwd: String?) -> Snapshot? {
        guard let cwd, let root = rootCache[cwd] ?? nil else { return nil }
        return snapshots[root]
    }

    /// Drop a repo's snapshot and re-baseline it at the current HEAD —
    /// "I have reviewed up to here", so the next look starts clean.
    func acknowledge(root: String) {
        snapshots.removeValue(forKey: root)
        baselines.removeValue(forKey: root)
        pinned.remove(root)
        // The next refresh re-baselines at whatever HEAD is by then.
        refresh()
    }

    /// Recompute now — the review card opens on the current tree, not on
    /// whatever the last tick happened to catch.
    func refreshNow() { refresh() }

    /// Keep refreshing this root whether or not an agent is still in it: a
    /// review left open on a finished run must not go stale.
    func pin(root: String) {
        pinned.insert(root)
        refresh()
    }

    /// Repository root for a directory, answered from cache when known and
    /// off the main thread otherwise. `nil` outside a repo.
    ///
    /// A root resolved this way is watched from here on even with no agent
    /// in it: asking to review a directory is reason enough to track it.
    func resolveRoot(forCwd cwd: String?,
                     then: @escaping @MainActor (String?) -> Void) {
        guard let cwd, !cwd.isEmpty else { return then(nil) }
        if let cached = rootCache[cwd] {
            if let root = cached { pinned.insert(root) }
            then(cached)
            return
        }
        Task.detached(priority: .userInitiated) {
            let root = Self.repoRoot(cwd)
            await MainActor.run {
                self.rootCache[cwd] = root
                if let root { self.pinned.insert(root) }
                self.refresh()
                then(root)
            }
        }
    }

    // MARK: - Roster

    /// Working directories of every pane currently running an agent. A
    /// small walk, same shape as `AgentCenter.noteAgentActivity`.
    private static func agentCwds() -> [String] {
        guard let delegate = NSApp.delegate as? AppDelegate else { return [] }
        var out: [String] = []
        for wc in delegate.windows {
            for tab in wc.state.tabs {
                for pane in tab.paneTree.root.leaves()
                where pane.agent.phase != .idle && pane.remoteHost == nil {
                    if let cwd = pane.cwd, !cwd.isEmpty { out.append(cwd) }
                }
            }
        }
        return out
    }

    private func refresh() {
        let cwds = Set(Self.agentCwds())
        // Resolve unknown directories to repo roots off the main thread;
        // the result is cached, including the negative (not a repo).
        let unresolved = cwds.filter { rootCache[$0] == nil }
        if !unresolved.isEmpty {
            Task.detached(priority: .utility) {
                var found: [String: String?] = [:]
                for cwd in unresolved { found[cwd] = Self.repoRoot(cwd) }
                await MainActor.run {
                    for (k, v) in found { self.rootCache[k] = v }
                    self.refresh()
                }
            }
        }
        let roots = Set(cwds.compactMap { rootCache[$0] ?? nil }).union(pinned)
        for root in roots {
            guard !computing.contains(root) else { continue }
            let baseline = baselines[root]
            computing.insert(root)
            Task.detached(priority: .utility) {
                let result = Self.compute(root: root, baseline: baseline)
                await MainActor.run {
                    self.computing.remove(root)
                    guard let result else { return }
                    // First sight of this repo fixes the baseline; the
                    // snapshot it produced measured against HEAD, so it is
                    // empty of commits by construction and correct.
                    if self.baselines[root] == nil {
                        self.baselines[root] = result.baseline
                    }
                    if self.snapshots[root] != result { self.snapshots[root] = result }
                }
            }
        }
    }

    // MARK: - git

    /// `git -C <dir> …`, off the main thread. nil on any non-zero exit.
    ///
    /// `--no-optional-locks` matters here: an agent runs git constantly,
    /// and a status that takes `index.lock` to refresh the index can fail
    /// its command. Read-only inspection must never contend for that lock.
    nonisolated private static func git(_ dir: String, _ args: [String],
                                        limit: Int = 4_000_000) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--no-optional-locks", "-C", dir] + args
        // A repo mid-rebase or with a pager configured must not stall us.
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data.prefix(limit), encoding: .utf8)
    }

    nonisolated private static func repoRoot(_ cwd: String) -> String? {
        git(cwd, ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Diff text for one path, for the review card's hunk view. Untracked
    /// files have no diff, so they are rendered from disk as all-added.
    nonisolated static func diff(root: String, path: String,
                                 untracked: Bool) -> String {
        if untracked {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(data: data.prefix(200_000), encoding: .utf8)
            else { return "(new file — binary or unreadable)" }
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "+" + $0 }
                .joined(separator: "\n")
        }
        return git(root, ["diff", "HEAD", "--", path], limit: 400_000)
            ?? "(no diff)"
    }

    nonisolated private static let maxFiles = 400
    /// Untracked files above this are not line-counted: the number would
    /// cost more to produce than it is worth reading.
    nonisolated private static let maxCountedFileBytes = 1_000_000

    nonisolated private static func compute(root: String,
                                            baseline: String?) -> Snapshot? {
        guard let head = git(root, ["rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            // A repo with no commits yet has no HEAD to diff against.
            return nil
        }
        let base = baseline ?? head
        var snap = Snapshot(
            root: root,
            branch: git(root, ["rev-parse", "--abbrev-ref", "HEAD"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD",
            baseline: base)

        // Working tree vs HEAD: status for the kind of change, numstat for
        // the size of it. Merged by path.
        var byPath: [String: FileChange] = [:]
        var order: [String] = []
        for entry in statusEntries(root: root) {
            byPath[entry.path] = entry
            order.append(entry.path)
        }
        for (path, add, del) in numstat(root: root, args: ["diff", "--numstat", "-M", "HEAD"]) {
            if byPath[path] != nil {
                byPath[path]?.added = add
                byPath[path]?.removed = del
            }
        }
        // Truncate before counting anything: a repo with an unignored
        // dependency directory lists tens of thousands of untracked files,
        // and reading them all every tick is the difference between a
        // background watch and a background job.
        if order.count > maxFiles {
            snap.truncated = true
            order = Array(order.prefix(maxFiles))
        }
        // Untracked files carry no numstat; count their lines directly, and
        // only for files small enough that reading them is free. The rest
        // keep nil counts, which the card renders as "not counted" rather
        // than as a misleading zero.
        for path in order where byPath[path]?.status == .untracked {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            guard let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size]) as? Int,
                  size <= maxCountedFileBytes else { continue }
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
               let text = String(data: data, encoding: .utf8) {
                byPath[path]?.added = text.isEmpty ? 0
                    : text.split(separator: "\n", omittingEmptySubsequences: false).count
                byPath[path]?.removed = 0
            }
        }
        snap.files = order.compactMap { byPath[$0] }

        // Commits the agent made since the baseline. Empty on the tick
        // that sets the baseline, which is the correct answer then.
        if base != head {
            snap.commits = commits(root: root, range: "\(base)..\(head)")
        }
        return snap
    }

    nonisolated private static func statusEntries(root: String) -> [FileChange] {
        guard let raw = git(root, ["status", "--porcelain=v1", "-z",
                                   "--untracked-files=all"]) else { return [] }
        return parseStatus(raw)
    }

    /// `git status --porcelain=v1 -z`, NUL-separated so paths needing
    /// quotes survive intact. Rename records carry the old path as an
    /// extra NUL-separated field.
    nonisolated static func parseStatus(_ raw: String) -> [FileChange] {
        var out: [FileChange] = []
        var fields = raw.split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
        if fields.last?.isEmpty == true { fields.removeLast() }
        var i = 0
        while i < fields.count {
            let record = fields[i]
            i += 1
            guard record.count > 3 else { continue }
            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            let path = String(record.dropFirst(3))
            var change = FileChange(path: path, status: .modified)
            change.staged = x != " " && x != "?"
            // A rename or copy always carries its origin as the next
            // NUL-separated field. Consume it before anything else: a
            // record like `RD` classifies as deleted, and skipping the
            // consume there would read the origin path as the next record
            // and desynchronise the whole listing.
            if x == "R" || x == "C", i < fields.count {
                change.renamedFrom = fields[i]
                i += 1
            }
            switch (x, y) {
            case ("?", _):           change.status = .untracked
            case ("A", _), (_, "A"): change.status = .added
            case ("D", _), (_, "D"): change.status = .deleted
            case ("R", _), ("C", _): change.status = .renamed
            default:                 change.status = .modified
            }
            out.append(change)
        }
        return out
    }

    nonisolated private static func numstat(root: String,
                                            args: [String]) -> [(String, Int?, Int?)] {
        guard let raw = git(root, args) else { return [] }
        return parseNumstat(raw)
    }

    /// numstat rows as (path, added, removed). Binary files report `-`,
    /// which stays nil so the card can say "binary" instead of "+0 −0".
    nonisolated static func parseNumstat(_ raw: String) -> [(String, Int?, Int?)] {
        var out: [(String, Int?, Int?)] = []
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2,
                                   omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            out.append((renameTarget(String(parts[2])), Int(parts[0]), Int(parts[1])))
        }
        return out
    }

    /// The path a numstat row ends at. Renames arrive either whole
    /// (`old.txt => dir/old.txt`) or with the unchanged part factored out
    /// (`src/{a.txt => b.txt}`); both must resolve to the path `git status`
    /// reports, or the row won't merge and the rename shows no counts.
    nonisolated static func renameTarget(_ raw: String) -> String {
        guard let arrow = raw.range(of: " => ") else { return raw }
        guard let open = raw.range(of: "{"), let close = raw.range(of: "}"),
              open.upperBound <= arrow.lowerBound,
              arrow.upperBound <= close.lowerBound else {
            return String(raw[arrow.upperBound...])
        }
        return String(raw[raw.startIndex..<open.lowerBound])
            + String(raw[arrow.upperBound..<close.lowerBound])
            + String(raw[close.upperBound...])
    }

    nonisolated private static func commits(root: String, range: String) -> [Commit] {
        // Unit separator between fields, record separator *leading* each
        // commit: a subject can contain anything a delimiter might be, and
        // numstat rows follow their header, so a trailing separator would
        // file every commit's stats under the next one.
        guard let raw = git(root, ["log", "--no-merges",
                                   "--pretty=format:\u{1e}%h\u{1f}%at\u{1f}%s",
                                   "--numstat", range]) else { return [] }
        return parseCommits(raw)
    }

    nonisolated static func parseCommits(_ raw: String) -> [Commit] {
        var out: [Commit] = []
        for block in raw.split(separator: "\u{1e}") {
            let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            let head = lines.removeFirst()
            let f = head.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 3, let ts = Double(f[1]) else { continue }
            var c = Commit(id: String(f[0]),
                           subject: String(f[2]),
                           at: Date(timeIntervalSince1970: ts),
                           files: 0, added: 0, removed: 0)
            for line in lines where !line.isEmpty {
                let parts = line.split(separator: "\t", maxSplits: 2,
                                       omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                c.files += 1
                c.added += Int(parts[0]) ?? 0
                c.removed += Int(parts[1]) ?? 0
            }
            out.append(c)
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
