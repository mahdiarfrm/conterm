import Foundation

/// The agent session a pane is running, as the hook script records it in
/// `~/.conterm/agents/pane-<pane id>`: agent, pid and transcript path, one
/// per line. Rewritten on every session and turn event and removed at
/// SessionEnd, so unlike the OSC 9 events — which libghostty passes at most
/// once a second app-wide — it can't be lost when several agents start at
/// once. Session restore reads it to know which panes to resume.
struct AgentSessionRecord: Equatable {
    var agent: String
    /// The agent process. nil when the hook couldn't find it.
    var pid: pid_t?
    var transcriptPath: String

    /// The session id: the transcript's file name without `.jsonl`.
    var sessionID: String? {
        guard transcriptPath.hasSuffix(".jsonl") else { return nil }
        let id = String((transcriptPath as NSString).lastPathComponent.dropLast(6))
        return id.isEmpty ? nil : id
    }

    /// False once the recorded agent process is gone: a session that ended
    /// without SessionEnd. True when no pid was recorded.
    var isAlive: Bool {
        guard let pid, pid > 1 else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static var directory: String { "\(InstanceState.userHome)/.conterm/agents" }

    static func path(for paneID: UUID) -> String {
        "\(directory)/pane-\(paneID.uuidString)"
    }

    static func parse(_ text: String) -> AgentSessionRecord? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count >= 3, !lines[0].isEmpty, !lines[2].isEmpty else { return nil }
        return AgentSessionRecord(agent: lines[0], pid: pid_t(lines[1]),
                                  transcriptPath: lines[2])
    }

    static func read(paneID: UUID) -> AgentSessionRecord? {
        guard let text = try? String(contentsOfFile: path(for: paneID), encoding: .utf8)
        else { return nil }
        return parse(text)
    }

    /// Remove records no live session stands behind: unreadable ones, ones
    /// whose agent process is gone, and pid-less ones untouched for a week.
    /// A pane's record outlives the pane when the app quits, and pane ids
    /// are new each launch, so these would otherwise pile up. Records of
    /// another instance's running sessions stay.
    static func removeStale(now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasPrefix("pane-") {
            let path = "\(directory)/\(name)"
            let record = (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(parse)
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let stale: Bool
            if let record {
                stale = record.pid == nil
                    ? now.timeIntervalSince(modified ?? now) > 7 * 24 * 3600
                    : !record.isAlive
            } else {
                stale = true
            }
            if stale { try? fm.removeItem(atPath: path) }
        }
    }
}
