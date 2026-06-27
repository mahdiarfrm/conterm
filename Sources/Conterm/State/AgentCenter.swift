import AppKit
import Foundation
import SwiftUI

/// Cumulative token usage + model for one Claude session, summed from its
/// transcript jsonl. `branch` rides along from the same file (each line
/// carries `gitBranch`).
struct AgentUsage: Equatable {
    var model: String?
    var branch: String?
    /// One-line summary of the latest user prompt — "what the agent is
    /// working on", surfaced in the roster so panes are distinguishable.
    var task: String?
    /// Transcript file's last-modified time — a proxy for "last agent
    /// activity", shown as a relative age so you can tell which agent has
    /// been grinding (or waiting) longest.
    var lastActivity: Date?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreateTokens: Int = 0
    var cacheReadTokens: Int = 0
    /// Assistant messages seen — a rough turn count.
    var turns: Int = 0
    /// Sub-agents (Task tool) this session is currently running, each read
    /// from its own `subagents/agent-*.jsonl`. Empty for opencode and for
    /// Claude sessions that haven't fanned out.
    var subAgents: [SubAgentInfo] = []
    /// Recent shell (Bash tool) commands the agent ran, oldest→newest, read
    /// from the transcript. Lets the command center show what the agent is
    /// actually doing at the shell. Claude only.
    var shellCommands: [ShellCommand] = []

    /// Tokens the session *produced* — input + output + cache writes.
    /// Cache READS are deliberately excluded: a long session re-reads the
    /// same cached context every turn, so summing them balloons the count
    /// into the tens of millions for a conversation that's actually small.
    /// Cost still bills every read (see `AgentPricing`).
    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreateTokens
    }
    /// Estimated spend in USD from the per-model rate table. Best-effort:
    /// Anthropic bills each request independently, so summing per-message
    /// usage × rate matches the session total.
    var estCost: Double { AgentPricing.cost(for: self) }
}

/// One sub-agent (Claude Code Task tool) spawned by a parent session, read
/// from its own `subagents/agent-<id>.jsonl`. Surfaced as a child row under
/// the parent so a fanned-out run shows each branch's task and spend.
struct SubAgentInfo: Equatable, Identifiable {
    let id: String            // agentId, taken from the transcript filename
    var task: String?         // the sub-agent's first prompt (its instructions)
    var model: String?
    var totalTokens: Int
    var estCost: Double
    var lastActivity: Date?
}

/// One Bash command the agent ran, surfaced as a shell-feed row. `id` is the
/// tool_use id from the transcript, so a streamed message re-logging the same
/// call is de-duped.
struct ShellCommand: Equatable, Identifiable {
    let id: String
    let command: String
    /// Transcript timestamp of the turn that ran it; ages the feed out.
    let at: Date
}

/// One row in the agent command center: a live agent in some pane, its
/// location, status, and (Claude only) token/cost. Holds weak handles for
/// jump-to-pane and writing back to the agent's tty.
struct AgentCenterEntry: Identifiable {
    let id: UUID                  // pane.id
    let windowIndex: Int          // 1-based
    let tabIndex: Int
    let paneIndex: Int            // 0 when the tab has a single pane
    let tabLabel: String
    let cwd: String?
    /// Exact transcript file for this pane's agent, when the hook supplied it
    /// (Claude only). Read in preference to guessing from `cwd`.
    let transcriptPath: String?
    let dirLabel: String
    let remoteHost: String?
    let phase: AgentStatus.Phase
    let tool: AgentTool
    let isCurrent: Bool

    weak var window: NSWindow?
    weak var owningState: AppState?
    weak var owningTab: Tab?
    weak var pane: Pane?

    var usage: AgentUsage?

    var locationLabel: String {
        var s = "Win \(windowIndex) · Tab \(tabIndex)"
        if paneIndex > 0 { s += " · ⌥\(paneIndex)" }
        return s
    }
}

/// Value-equality on the displayed fields only (the weak handles are
/// excluded) so a refresh that finds nothing new doesn't republish — which
/// is what made the roster flicker every tick.
extension AgentCenterEntry: Equatable {
    static func == (a: AgentCenterEntry, b: AgentCenterEntry) -> Bool {
        a.id == b.id && a.phase == b.phase && a.tool == b.tool
            && a.windowIndex == b.windowIndex && a.tabIndex == b.tabIndex
            && a.paneIndex == b.paneIndex && a.tabLabel == b.tabLabel
            && a.dirLabel == b.dirLabel && a.remoteHost == b.remoteHost
            && a.isCurrent == b.isCurrent && a.usage == b.usage
    }
}

/// Per-model API rates (USD per 1M tokens). Cache-write is the 5-minute
/// TTL premium (1.25× input); cache-read is 0.1× input. Unknown models
/// fall back to Opus-tier, Claude Code's default.
enum AgentPricing {
    struct Rate { let input, output, cacheWrite, cacheRead: Double }

    static func rate(for model: String?) -> Rate {
        let m = (model ?? "").lowercased()
        if m.contains("haiku")  { return Rate(input: 1, output: 5,  cacheWrite: 1.25, cacheRead: 0.10) }
        if m.contains("sonnet") { return Rate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30) }
        return Rate(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.50) // opus / default
    }

    static func cost(for u: AgentUsage) -> Double {
        let r = rate(for: u.model)
        return (Double(u.inputTokens)       * r.input
              + Double(u.outputTokens)      * r.output
              + Double(u.cacheCreateTokens) * r.cacheWrite
              + Double(u.cacheReadTokens)   * r.cacheRead) / 1_000_000
    }
}

/// Reads Claude Code session transcripts to surface live token/cost.
/// Transcripts live at `~/.claude/projects/<encoded-cwd>/<session>.jsonl`,
/// where every `/` and `.` in the absolute cwd becomes `-`; the active
/// session is the most-recently-modified file. Parsing is incremental —
/// each call reads only bytes appended since the last, up to the last
/// complete line — so a streaming 15 MB transcript isn't re-scanned every
/// tick. Confined to AgentCenter's serial io queue; never touched on main.
final class AgentTranscriptStore: @unchecked Sendable {
    private struct MsgTokens { var input = 0, output = 0, cacheCreate = 0, cacheRead = 0 }
    /// How long a shell command stays in the feed after its turn.
    private static let shellFeedTTL: TimeInterval = 300
    private struct FileState {
        static let shellFeedTTL = AgentTranscriptStore.shellFeedTTL
        var path: String
        var offset: UInt64 = 0
        // Per assistant message id → usage. Claude Code re-logs the same
        // message multiple times while streaming, so keying by id and
        // overwriting counts each message once; summing raw lines would
        // multiply tokens (and cost) several-fold.
        var perMessage: [String: MsgTokens] = [:]
        var model: String?
        var branch: String?
        var task: String?
        var anon = 0   // fallback key for assistant lines lacking an id
        // Bash commands the agent ran, oldest→newest, de-duped by tool_use id
        // (streaming re-logs the same assistant message). Capped to a tail.
        var recentShell: [ShellCommand] = []
        var shellSeen: Set<String> = []

        func snapshot() -> AgentUsage {
            var u = AgentUsage(model: model, branch: branch, task: task)
            for (_, m) in perMessage {
                u.inputTokens += m.input
                u.outputTokens += m.output
                u.cacheCreateTokens += m.cacheCreate
                u.cacheReadTokens += m.cacheRead
            }
            u.turns = perMessage.count
            // Age the shell feed out: keep only commands from the last few
            // minutes so a since-quiet agent's list clears instead of lingering.
            let cutoff = Date().addingTimeInterval(-Self.shellFeedTTL)
            u.shellCommands = recentShell.filter { $0.at >= cutoff }
            return u
        }
    }
    private var states: [String: FileState] = [:]
    private var projectsRoot: String { "\(NSHomeDirectory())/.claude/projects" }

    /// Claude Code's project-dir encoding of an absolute path.
    static func encode(cwd: String) -> String {
        String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
    }

    /// Current usage for a pane's agent. The hook-supplied `transcriptPath`
    /// pins the exact session file (immune to a shared cwd or a `cd` after
    /// launch); without it we fall back to the newest transcript in the cwd's
    /// project dir. nil when neither resolves to a readable file.
    func usage(forCwd cwd: String?, transcriptPath: String? = nil) -> AgentUsage? {
        let path: String
        if let transcriptPath, !transcriptPath.isEmpty,
           FileManager.default.fileExists(atPath: transcriptPath) {
            path = transcriptPath
        } else {
            guard let cwd, !cwd.isEmpty else { return nil }
            let dir = "\(projectsRoot)/\(Self.encode(cwd: cwd))"
            guard let newest = newestTranscript(in: dir) else { return nil }
            path = newest
        }

        // Key the accumulator by the resolved file, not the directory, so two
        // panes in one cwd keep independent running totals.
        var st = states[path] ?? FileState(path: path)
        if st.path != path { st = FileState(path: path) }
        accumulate(into: &st)
        states[path] = st
        var usage = st.snapshot()
        usage.lastActivity = (try? FileManager.default
            .attributesOfItem(atPath: path))?[.modificationDate] as? Date
        usage.subAgents = liveSubAgents(forMain: path)
        return usage
    }

    /// How recently a sub-agent's transcript must have changed to still count
    /// as running: a finished sub-agent stops being written, so it ages out.
    private static let subAgentLiveWindow: TimeInterval = 60

    /// Currently-running sub-agents for a session. They live beside the main
    /// transcript `<dir>/<session>.jsonl` under `<dir>/<session>/subagents/`.
    /// Each is parsed with the same incremental, id-deduped accumulator as a
    /// top-level transcript; quiet ones drop out and their accumulators are
    /// pruned so `states` stays bounded across a long fan-out.
    private func liveSubAgents(forMain main: String) -> [SubAgentInfo] {
        guard main.hasSuffix(".jsonl") else { return [] }
        let dir = String(main.dropLast(6)) + "/subagents"   // strip ".jsonl"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let now = Date()
        var out: [SubAgentInfo] = []
        var livePaths: Set<String> = []
        for n in names where n.hasPrefix("agent-") && n.hasSuffix(".jsonl") {
            let p = "\(dir)/\(n)"
            guard let mod = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
                  now.timeIntervalSince(mod) < Self.subAgentLiveWindow else { continue }
            livePaths.insert(p)
            var st = states[p] ?? FileState(path: p)
            if st.path != p { st = FileState(path: p) }
            accumulate(into: &st)
            states[p] = st
            let u = st.snapshot()
            let id = String(n.dropFirst(6).dropLast(6))   // "agent-" … ".jsonl"
            out.append(SubAgentInfo(id: id, task: u.task, model: u.model,
                                    totalTokens: u.totalTokens, estCost: u.estCost,
                                    lastActivity: mod))
        }
        // Drop accumulators for sub-agents that have gone quiet.
        for key in states.keys
        where key.hasPrefix(dir + "/") && !livePaths.contains(key) {
            states.removeValue(forKey: key)
        }
        return out.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    private func newestTranscript(in dir: String) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (path: String, date: Date)?
        for n in names where n.hasSuffix(".jsonl") {
            let p = "\(dir)/\(n)"
            guard let mod = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date
            else { continue }
            if best == nil || mod > best!.date { best = (p, mod) }
        }
        return best?.path
    }

    private func accumulate(into st: inout FileState) {
        guard let fh = FileHandle(forReadingAtPath: st.path) else { return }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        if end < st.offset {            // truncated → start over
            st.offset = 0; st.perMessage = [:]; st.anon = 0
        }
        if end <= st.offset { return }
        guard (try? fh.seek(toOffset: st.offset)) != nil,
              let data = try? fh.readToEnd(), !data.isEmpty,
              // Only consume through the last newline; the partial tail is
              // re-read next time (cutting on \n keeps each slice valid UTF-8).
              let lastNL = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNL]
        st.offset += UInt64(complete.count)

        var line = Data()
        for byte in complete {
            if byte == 0x0A { applyLine(line, to: &st); line.removeAll(keepingCapacity: true) }
            else { line.append(byte) }
        }
    }

    private func applyLine(_ line: Data, to st: inout FileState) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { st.branch = b }
        let type = obj["type"] as? String
        // A real user prompt → the agent's current task. Tool results and
        // tool-only / meta-wrapper user messages carry no text block and
        // leave the prior task in place.
        if type == "user", let msg = obj["message"] as? [String: Any],
           let prompt = Self.userPromptText(msg) {
            st.task = prompt
        }
        guard type == "assistant",
              let msg = obj["message"] as? [String: Any] else { return }
        if let m = msg["model"] as? String { st.model = m }
        // Pull Bash commands out of this turn's tool_use blocks for the shell
        // feed, de-duped by tool_use id and capped to the most recent 40.
        if let content = msg["content"] as? [[String: Any]] {
            let at = Self.parseTimestamp(obj["timestamp"] as? String) ?? Date()
            for block in content
                where (block["type"] as? String) == "tool_use"
                    && (block["name"] as? String) == "Bash" {
                guard let tid = block["id"] as? String, !st.shellSeen.contains(tid),
                      let input = block["input"] as? [String: Any],
                      let cmd = (input["command"] as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !cmd.isEmpty else { continue }
                st.shellSeen.insert(tid)
                st.recentShell.append(ShellCommand(
                    id: tid,
                    command: cmd.count > 200 ? String(cmd.prefix(200)) + "…" : cmd,
                    at: at))
                if st.recentShell.count > 40 {
                    st.recentShell.removeFirst(st.recentShell.count - 40)
                }
            }
        }
        guard let us = msg["usage"] as? [String: Any] else { return }
        // Dedupe: a streamed message id reappears with the same/growing usage;
        // overwrite so it's counted once.
        let id: String
        if let mid = msg["id"] as? String, !mid.isEmpty { id = mid }
        else { st.anon += 1; id = "anon-\(st.anon)" }
        st.perMessage[id] = MsgTokens(
            input:       (us["input_tokens"] as? Int) ?? 0,
            output:      (us["output_tokens"] as? Int) ?? 0,
            cacheCreate: (us["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheRead:   (us["cache_read_input_tokens"] as? Int) ?? 0)
    }

    /// First meaningful line of a user message's text, condensed to a
    /// one-liner. Skips wrapper/meta/attachment lines (so a pasted-image
    /// turn doesn't surface as `[Image: …]`), returning nil when there's no
    /// real prompt — which leaves the standing task in place.
    private static func userPromptText(_ msg: [String: Any]) -> String? {
        let raw: String?
        if let s = msg["content"] as? String {
            raw = s
        } else if let arr = msg["content"] as? [[String: Any]] {
            raw = arr.first {
                ($0["type"] as? String) == "text"
                    && ($0["text"] as? String)?.isEmpty == false
            }?["text"] as? String
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { l in
                !l.isEmpty
                    && !l.hasPrefix("<")
                    && !l.hasPrefix("Caveat:")
                    && !l.hasPrefix("[Image")
                    && !l.hasPrefix("[Pasted")
                    && !l.hasPrefix("[Request interrupted")
            }
        guard let line, !line.isEmpty else { return nil }
        return line.count > 140 ? String(line.prefix(140)) + "…" : line
    }

    // Touched only on AgentCenter's serial io queue (see the type doc), so the
    // shared formatters need no locking.
    nonisolated(unsafe) private static let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso8601Plain = ISO8601DateFormatter()

    /// Parse a transcript line's ISO-8601 `timestamp` (with or without
    /// fractional seconds). nil when absent/unparseable.
    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso8601Frac.date(from: s) ?? iso8601Plain.date(from: s)
    }
}

/// App-wide roster of every running AI agent across all windows, with the
/// transcript-derived token/cost for Claude sessions. One shared instance;
/// each open command-center surface drives the refresh cadence while it's
/// visible (ref-counted) so idle windows cost nothing.
@MainActor
final class AgentCenter: ObservableObject {
    static let shared = AgentCenter()

    @Published private(set) var entries: [AgentCenterEntry] = []
    /// Live count of running agents across all windows — always current
    /// (event-driven, no timer), so the toolbar's agent pill can appear
    /// the moment an agent starts even with no center surface open.
    @Published private(set) var runningCount = 0

    private let store = AgentTranscriptStore()
    private let ioQueue = DispatchQueue(label: "conterm.agentcenter.io", qos: .utility)
    private var timer: Timer?
    private var observers = 0

    /// Start (or join) the periodic refresh while a center surface shows.
    func beginObserving() {
        observers += 1
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func endObserving() {
        observers = max(0, observers - 1)
        if observers == 0 { timer?.invalidate(); timer = nil }
    }

    /// Event-driven presence update — called from `Tab.recomputeAgentPhase`
    /// whenever any pane's agent phase changes. Updates `runningCount` and,
    /// if a center surface is open, refreshes the roster immediately rather
    /// than waiting for the next 2s tick.
    func noteAgentActivity() {
        let c = (NSApp.delegate as? AppDelegate)?.windows.reduce(0) { acc, wc in
            acc + wc.state.tabs.reduce(0) { a, t in
                a + t.paneTree.root.leaves().reduce(0) {
                    $0 + ($1.agent.phase != .idle ? 1 : 0)
                }
            }
        } ?? 0
        if c != runningCount { runningCount = c }
        if observers > 0 { refresh() }
    }

    /// Rebuild the roster (statuses are live), then enrich Claude rows with
    /// transcript token/cost off the main thread. Token data is carried
    /// forward across rebuilds so it never blinks to nil between the
    /// synchronous roster pass and the async read, and `entries` is only
    /// republished when something actually changed.
    func refresh() {
        let prior = Dictionary(entries.map { ($0.id, $0.usage) },
                               uniquingKeysWith: { a, _ in a })
        var roster = Self.buildRoster()
        for i in roster.indices {
            if let u = prior[roster[i].id] ?? nil { roster[i].usage = u }
        }
        if entries != roster { entries = roster }

        let claude = roster.compactMap { e in
            e.tool == .claude ? (e.id, e.cwd, e.transcriptPath) : nil
        }
        guard !claude.isEmpty else { return }
        let store = self.store
        ioQueue.async {
            var byID: [UUID: AgentUsage] = [:]
            for (id, cwd, transcript) in claude {
                if let u = store.usage(forCwd: cwd, transcriptPath: transcript) { byID[id] = u }
            }
            guard !byID.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var updated = self.entries
                var changed = false
                for i in updated.indices where byID[updated[i].id] != nil {
                    if updated[i].usage != byID[updated[i].id] {
                        updated[i].usage = byID[updated[i].id]
                        changed = true
                    }
                }
                if changed { self.entries = updated }
            }
        }
    }

    // MARK: - Roster

    private static func buildRoster() -> [AgentCenterEntry] {
        guard let delegate = NSApp.delegate as? AppDelegate else { return [] }
        var rows: [AgentCenterEntry] = []
        for (wi, wc) in delegate.windows.enumerated() {
            let st = wc.state
            for (ti, tab) in st.tabs.enumerated() {
                let leaves = tab.paneTree.root.leaves()
                for (pi, pane) in leaves.enumerated() where pane.agent.phase != .idle {
                    let current = wc.window.isKeyWindow
                        && st.selectedID == tab.id
                        && tab.paneTree.activePaneID == pane.id
                    rows.append(AgentCenterEntry(
                        id: pane.id,
                        windowIndex: wi + 1,
                        tabIndex: ti + 1,
                        paneIndex: leaves.count > 1 ? pi + 1 : 0,
                        tabLabel: tab.title.isEmpty ? "shell" : tab.title,
                        cwd: pane.cwd,
                        transcriptPath: pane.agentTranscriptPath,
                        dirLabel: friendlyDir(pane.cwd),
                        remoteHost: pane.remoteHost,
                        phase: pane.agent.phase,
                        tool: pane.agent.tool,
                        isCurrent: current,
                        window: wc.window,
                        owningState: st,
                        owningTab: tab,
                        pane: pane,
                        usage: nil))
                }
            }
        }
        return rows.sorted { a, b in
            let ra = rank(a.phase), rb = rank(b.phase)
            if ra != rb { return ra < rb }
            if a.windowIndex != b.windowIndex { return a.windowIndex < b.windowIndex }
            if a.tabIndex != b.tabIndex { return a.tabIndex < b.tabIndex }
            return a.paneIndex < b.paneIndex
        }
    }

    /// needs-you first, then working, then the rest.
    private static func rank(_ p: AgentStatus.Phase) -> Int {
        switch p {
        case .attention:   return 0
        case .working:     return 1
        case .interrupted: return 2
        case .ready:       return 3
        case .idle:        return 4
        }
    }

    private static func friendlyDir(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    // MARK: - Jump + control

    /// Bring the agent's window forward, select its tab + pane, and pull
    /// keyboard focus (the surface mounts a beat after the window keys).
    func jump(to e: AgentCenterEntry) {
        guard let st = e.owningState, let tab = e.owningTab, let pane = e.pane else { return }
        st.select(tab.id)
        tab.paneTree.focus(pane)
        if let win = e.window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            st.focusActiveSurface()
        }
    }

    /// Type a follow-up line into the agent's pane, then submit it with a
    /// real Return keypress (a pasted newline wouldn't submit).
    func respond(to e: AgentCenterEntry, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let c = e.pane?.controller else { return }
        c.sendText(t)
        c.sendReturn()
    }

    /// Accept a default prompt option (a real Return keypress).
    func accept(_ e: AgentCenterEntry) { e.pane?.controller?.sendReturn() }

    /// Send Esc — cancels a Claude turn / declines a prompt.
    func interrupt(_ e: AgentCenterEntry) { e.pane?.controller?.sendText("\u{1b}") }
}
