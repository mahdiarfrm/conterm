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
    /// Transcript file's creation time — the session's start, so cost can
    /// be shown as a burn rate.
    var firstActivity: Date?
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
    /// When its result came back, from the `tool_result` turn. nil while it is
    /// still running — a command's duration is the gap between the two, and it
    /// is the only duration the transcript records.
    var endedAt: Date? = nil
    /// Combined stdout/stderr, backfilled from the matching tool_result turn.
    var output: String? = nil

    /// How long it ran, once it has finished.
    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(at) }
    }
}

/// One tool call as the transcript records it: the `tool_use` block's name
/// and input, then the matching `tool_result`. Keyed by tool_use id, which
/// is what the hook events carry too.
struct ToolRecord: Equatable {
    /// Position in the transcript's run of tool calls, from 1. A reader
    /// keeps the last one it consumed and asks for what came after.
    let seq: Int
    let name: String
    /// The Bash command line, a file tool's path, or the compacted input.
    let input: String?
    let at: Date
    var endedAt: Date?
    var isError: Bool?
    var output: String?

    /// The call as a line: the Bash command itself; an MCP tool's name with
    /// its input after it, since the name is what says which tool ran.
    var commandLine: String? {
        guard name.hasPrefix("mcp__") else { return input }
        return input.map { "\(name) \($0)" } ?? name
    }
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
    /// Tool calls kept per transcript. The pane's own run list is shorter,
    /// and a result is only looked up while its run is still shown.
    private static let toolRecordCap = 400
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
        // Every tool call by tool_use id, for the pane's tool runs to read
        // back; `toolOrder` is insertion order so the oldest can be dropped.
        var tools: [String: ToolRecord] = [:]
        var toolOrder: [String] = []
        /// Tool calls ever recorded — the next record's `seq`.
        var toolSeq = 0

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
        guard let path = resolve(cwd: cwd, transcriptPath: transcriptPath, claudeFallback: true)
        else { return nil }
        let st = state(for: path)
        var usage = st.snapshot()
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        usage.lastActivity = attrs?[.modificationDate] as? Date
        usage.firstActivity = attrs?[.creationDate] as? Date
        usage.subAgents = liveSubAgents(forMain: path)
        return usage
    }

    /// A pane's view of its transcript's tool calls: every call recorded
    /// after `cursor` (in order), plus the current state of the calls it
    /// already knows by id. The cursor is only meaningful against the file
    /// it was read from — a different file (a new session in the same
    /// directory) starts it over.
    struct ToolFeed {
        let path: String
        let cursor: Int
        let new: [(id: String, record: ToolRecord)]
        let known: [String: ToolRecord]
    }

    func toolFeed(after cursor: Int, from path: String?, ids: [String],
                  forCwd cwd: String?, transcriptPath: String?,
                  claudeFallback: Bool = true) -> ToolFeed? {
        guard let resolved = resolve(cwd: cwd, transcriptPath: transcriptPath,
                                     claudeFallback: claudeFallback) else { return nil }
        let st = state(for: resolved)
        // Fewer records than the cursor claims means the file was replaced
        // or truncated: read it as new.
        let from = (path == resolved && cursor <= st.toolSeq) ? cursor : 0
        var new: [(String, ToolRecord)] = []
        for id in st.toolOrder {
            guard let r = st.tools[id], r.seq > from else { continue }
            new.append((id, r))
        }
        var known: [String: ToolRecord] = [:]
        for id in ids { if let r = st.tools[id] { known[id] = r } }
        return ToolFeed(path: resolved, cursor: st.toolSeq, new: new, known: known)
    }

    /// The transcript file for a pane's agent: the hook-supplied path when it
    /// exists, else — for Claude, whose project dir is derivable — the
    /// newest transcript in the cwd's project dir.
    private func resolve(cwd: String?, transcriptPath: String?, claudeFallback: Bool) -> String? {
        if let transcriptPath, !transcriptPath.isEmpty,
           FileManager.default.fileExists(atPath: transcriptPath) {
            return transcriptPath
        }
        guard claudeFallback, let cwd, !cwd.isEmpty else { return nil }
        return newestTranscript(in: "\(projectsRoot)/\(Self.encode(cwd: cwd))")
    }

    /// The accumulator for a file, caught up to its current end. Keyed by
    /// the resolved file, not the directory, so two panes in one cwd keep
    /// independent running totals.
    private func state(for path: String) -> FileState {
        var st = states[path] ?? FileState(path: path)
        if st.path != path { st = FileState(path: path) }
        accumulate(into: &st)
        states[path] = st
        return st
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
        if end < st.offset {
            // Truncated: a different file under the same name. Everything
            // read from the old one is stale, tool records included — a
            // record kept by id would hide the new file's call under it.
            st = FileState(path: st.path)
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
        // A Codex rollout line carries its item under `payload`; Claude's
        // transcript never does.
        if let payload = obj["payload"] as? [String: Any] {
            applyRolloutLine(obj, payload: payload, to: &st)
            return
        }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { st.branch = b }
        let type = obj["type"] as? String
        // A real user prompt → the agent's current task. Tool results and
        // tool-only / meta-wrapper user messages carry no text block and
        // leave the prior task in place.
        if type == "user", let msg = obj["message"] as? [String: Any] {
            if let prompt = Self.userPromptText(msg) { st.task = prompt }
            // Backfill each shell command's output and finish time from its
            // tool_result turn, matched by tool_use id — the gap between the
            // two turns is the only duration the transcript records.
            let resultAt = Self.parseTimestamp(obj["timestamp"] as? String)
            if let content = msg["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_result" {
                    guard let tid = block["tool_use_id"] as? String else { continue }
                    if st.tools[tid] != nil, st.tools[tid]!.endedAt == nil {
                        let text = Self.toolResultText(block["content"])
                        st.tools[tid]!.endedAt = resultAt ?? Date()
                        st.tools[tid]!.isError = (block["is_error"] as? Bool) ?? false
                        st.tools[tid]!.output = text.count > 6000
                            ? String(text.prefix(6000)) + "\n…(truncated)" : text
                    }
                    guard let bi = st.recentShell.firstIndex(where: { $0.id == tid && $0.output == nil })
                    else { continue }
                    st.recentShell[bi].endedAt = resultAt ?? Date()
                    let text = Self.toolResultText(block["content"])
                    if !text.isEmpty {
                        st.recentShell[bi].output = text.count > 6000
                            ? String(text.prefix(6000)) + "\n…(truncated)" : text
                    }
                }
            }
        }
        guard type == "assistant",
              let msg = obj["message"] as? [String: Any] else { return }
        if let m = msg["model"] as? String { st.model = m }
        // Pull Bash commands out of this turn's tool_use blocks for the shell
        // feed, de-duped by tool_use id and capped to the most recent 40.
        if let content = msg["content"] as? [[String: Any]] {
            let at = Self.parseTimestamp(obj["timestamp"] as? String) ?? Date()
            for block in content where (block["type"] as? String) == "tool_use" {
                guard let tid = block["id"] as? String, st.tools[tid] == nil,
                      let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any]
                st.toolSeq += 1
                st.tools[tid] = ToolRecord(seq: st.toolSeq, name: name,
                                           input: Self.toolInputSummary(name, input), at: at)
                st.toolOrder.append(tid)
                if st.toolOrder.count > Self.toolRecordCap {
                    let drop = st.toolOrder.removeFirst()
                    st.tools.removeValue(forKey: drop)
                }
            }
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

    /// One line of a Codex rollout (`~/.codex/sessions/…/rollout-*.jsonl`):
    /// `response_item` payloads carry the model's tool calls and their
    /// outputs, keyed by `call_id` — the id Codex's hooks report as
    /// `tool_use_id`. A shell call's command arrives as an argv; the line
    /// Codex ran is its last element when the argv is `bash -lc …`.
    private func applyRolloutLine(_ obj: [String: Any], payload: [String: Any],
                                  to st: inout FileState) {
        guard (obj["type"] as? String) == "response_item",
              let kind = payload["type"] as? String else { return }
        let at = Self.parseTimestamp(obj["timestamp"] as? String) ?? Date()
        switch kind {
        case "function_call", "local_shell_call", "custom_tool_call", "web_search_call":
            guard let cid = (payload["call_id"] as? String) ?? (payload["id"] as? String),
                  st.tools[cid] == nil else { return }
            let name: String
            let input: String?
            switch kind {
            case "local_shell_call":
                name = "shell"
                let action = payload["action"] as? [String: Any]
                input = Self.argvLine(action?["command"])
            case "web_search_call":
                name = "web_search"
                let action = payload["action"] as? [String: Any]
                input = (action?["query"] as? String)
                    ?? (action?["queries"] as? [String])?.joined(separator: " · ")
            case "custom_tool_call":
                name = (payload["name"] as? String) ?? "custom"
                input = Self.patchSummary(payload["input"] as? String)
            default:
                name = (payload["name"] as? String) ?? "function"
                input = Self.functionArguments(payload["arguments"])
            }
            st.toolSeq += 1
            var rec = ToolRecord(seq: st.toolSeq, name: name, input: input, at: at)
            // A search is logged once, complete.
            if kind == "web_search_call" { rec.endedAt = at; rec.isError = false; rec.output = "" }
            st.tools[cid] = rec
            st.toolOrder.append(cid)
            if st.toolOrder.count > Self.toolRecordCap {
                let drop = st.toolOrder.removeFirst()
                st.tools.removeValue(forKey: drop)
            }
        case "function_call_output", "custom_tool_call_output":
            guard let cid = payload["call_id"] as? String,
                  st.tools[cid] != nil, st.tools[cid]!.endedAt == nil else { return }
            let text = Self.toolResultText(payload["output"])
            st.tools[cid]!.endedAt = at
            st.tools[cid]!.isError = Self.rolloutOutputFailed(text)
            st.tools[cid]!.output = text.count > 6000
                ? String(text.prefix(6000)) + "\n…(truncated)" : text
        default:
            return
        }
    }

    /// `["bash", "-lc", "ls -la"]` → `ls -la`; any other argv joined.
    private static func argvLine(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        guard let argv = value as? [String], !argv.isEmpty else { return nil }
        if argv.count == 3, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(argv[0]),
           ["-lc", "-c"].contains(argv[1]) {
            return argv[2]
        }
        return argv.joined(separator: " ")
    }

    /// A function call's `arguments` is a JSON document in a string; the
    /// shell tool's carries `command` (argv or line), others their own
    /// telling field.
    private static func functionArguments(_ value: Any?) -> String? {
        guard let s = value as? String, let data = s.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let line = argvLine(dict["command"]) { return line }
        return toolInputSummary("function", dict)
    }

    /// An `apply_patch` input is the patch itself; the files it touches are
    /// what a row needs to say.
    private static func patchSummary(_ patch: String?) -> String? {
        guard let patch, !patch.isEmpty else { return nil }
        var files: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
            where line.hasPrefix(marker) {
                files.append(String(line.dropFirst(marker.count)))
            }
        }
        if files.isEmpty {
            let first = patch.split(whereSeparator: \.isNewline).first.map(String.init) ?? patch
            return first.count > 200 ? String(first.prefix(200)) + "…" : first
        }
        return files.joined(separator: ", ")
    }

    /// Codex reports a shell command's exit status inside the output text —
    /// as JSON metadata or as an `Exit code:` line — rather than as an
    /// error flag on the item.
    private static func rolloutOutputFailed(_ text: String) -> Bool {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let meta = obj["metadata"] as? [String: Any], let code = meta["exit_code"] as? Int {
                return code != 0
            }
            if let code = obj["exit_code"] as? Int { return code != 0 }
        }
        let head = text.prefix(300)
        if let r = head.range(of: #"(?i)exit[ _]code"?\s*[:=]\s*(-?\d+)"#, options: .regularExpression) {
            let digits = head[r].split(whereSeparator: { !$0.isNumber && $0 != "-" }).last ?? ""
            return Int(digits) != 0
        }
        return false
    }

    /// Input fields that say what a call is about, most telling first: the
    /// command for Bash, a path for the file tools, a query or URL for the
    /// web, a sub-agent's description before its whole prompt.
    private static let tellingInputKeys = [
        "command", "file_path", "query", "url", "pattern", "skill", "description", "prompt",
    ]

    /// What a tool call was, in one line: the telling field of its input,
    /// a task list's size, otherwise the input compacted.
    private static func toolInputSummary(_ name: String, _ input: [String: Any]?) -> String? {
        guard let input, !input.isEmpty else { return nil }
        for key in tellingInputKeys {
            guard let s = input[key] as? String else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            return t.count > 300 ? String(t.prefix(300)) + "…" : t
        }
        if let todos = input["todos"] as? [[String: Any]] {
            return todos.count == 1 ? "1 item" : "\(todos.count) items"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s.count > 300 ? String(s.prefix(300)) + "…" : s
    }

    /// A tool result's content is either a plain string or an array of
    /// blocks — Claude's `text`, Codex's `input_text` / `output_text` —
    /// flattened to the combined output text; image blocks contribute nothing.
    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
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
        syncToolPoll()
    }

    /// Rebuild the roster (statuses are live), then enrich Claude rows with
    /// transcript token/cost off the main thread. Token data is carried
    /// forward across rebuilds so it never blinks to nil between the
    /// synchronous roster pass and the async read, and `entries` is only
    /// republished when something actually changed.
    func refresh() {
        // The CLI's background sessions ride the same tick; its own
        // cache keeps the subprocess spawns far apart.
        BackgroundAgents.shared.refresh()
        let prior = Dictionary(entries.map { ($0.id, $0.usage) },
                               uniquingKeysWith: { a, _ in a })
        var roster = Self.buildRoster()
        for i in roster.indices {
            if let u = prior[roster[i].id] ?? nil { roster[i].usage = u }
        }
        if entries != roster { entries = roster }
        enrichToolRuns()

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

    // MARK: - Tool runs

    /// Bumped per scheduling burst so a burst cut short by a newer one
    /// doesn't keep firing.
    private var enrichGeneration = 0
    /// Runs while any Claude agent is mid-turn: the transcript is the
    /// record of its tool calls, and this is how fast the record is read.
    private var toolPoll: Timer?
    private static let toolPollInterval: TimeInterval = 1.0

    /// Read the transcript for the panes' tool runs a few beats after a tool
    /// event: the tool_use line lands around PreToolUse, its result around
    /// PostToolUse, and neither is on disk the instant the hook fires. Each
    /// pass fills what it finds; a pane with nothing outstanding costs a
    /// dictionary lookup.
    func scheduleToolEnrichment() {
        enrichGeneration &+= 1
        let gen = enrichGeneration
        Task { @MainActor [weak self] in
            for delay in [0.4, 1.2, 3.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.enrichGeneration == gen else { return }
                self.enrichToolRuns()
            }
        }
        syncToolPoll()
    }

    /// Keep the transcript poll running exactly while a Claude agent is
    /// working or has a call still open. The hook's OSC events arrive at
    /// once but libghostty admits one desktop notification per second
    /// app-wide, so calls that land inside that second exist only here.
    func syncToolPoll() {
        let active = Self.allPanes().contains { p in
            p.agent.tool.hasTranscript
                && (p.agent.phase == .working || p.toolRuns.contains(where: \.isRunning))
        }
        if active {
            guard toolPoll == nil else { return }
            clog("agent tools: transcript poll on")
            let t = Timer(timeInterval: Self.toolPollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.enrichToolRuns() }
            }
            RunLoop.main.add(t, forMode: .common)
            toolPoll = t
        } else if toolPoll != nil {
            clog("agent tools: transcript poll off")
            toolPoll?.invalidate()
            toolPoll = nil
        }
    }

    /// Bring every Claude pane's tool runs up to its transcript: calls the
    /// hook never reported are created, known ones get their full command,
    /// result text and verdict. A run the hook never closed (a denied
    /// permission) ends here too.
    func enrichToolRuns() {
        // Panes travel to the io queue as ids only and are looked up again on
        // return; one may have closed in between.
        struct Job { let pane: UUID; let cwd: String?; let transcript: String?
                     let path: String?; let cursor: Int; let ids: [String]; let claude: Bool }
        var jobs: [Job] = []
        for pane in Self.allPanes() where pane.agent.tool.hasTranscript && pane.agent.phase != .idle {
            jobs.append(Job(pane: pane.id, cwd: pane.cwd, transcript: pane.agentTranscriptPath,
                            path: pane.toolFeedPath, cursor: pane.toolFeedCursor,
                            ids: pane.toolRuns.filter(\.wantsTranscript).map(\.id),
                            claude: pane.agent.tool == .claude))
        }
        guard !jobs.isEmpty else { return }
        let store = self.store
        let work = jobs
        ioQueue.async {
            var found: [UUID: AgentTranscriptStore.ToolFeed] = [:]
            for job in work {
                if let feed = store.toolFeed(after: job.cursor, from: job.path, ids: job.ids,
                                             forCwd: job.cwd, transcriptPath: job.transcript,
                                             claudeFallback: job.claude) {
                    found[job.pane] = feed
                }
            }
            guard !found.isEmpty else {
                clog("agent tools: no transcript for \(work.count) pane(s): \(work.map { $0.transcript ?? "cwd:\($0.cwd ?? "-")" })")
                return
            }
            DispatchQueue.main.async {
                for pane in Self.allPanes() {
                    if let feed = found[pane.id] { pane.applyToolFeed(feed) }
                }
                self.syncToolPoll()
            }
        }
    }

    /// Every pane in every window. Empty without an app (the test host).
    private static func allPanes() -> [Pane] {
        guard let app = NSApp, let delegate = app.delegate as? AppDelegate else { return [] }
        return delegate.windows.flatMap { wc in
            wc.state.tabs.flatMap { $0.paneTree.root.leaves() }
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
                        dirLabel: friendlyDirLabel(for: pane.cwd),
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

    // MARK: - Jump + control

    /// The id visited by the last `jumpToNextAttention`, so repeated
    /// invocations walk the whole inbox instead of bouncing on one agent.
    private var lastAttentionJump: UUID?

    /// Jump to the next agent that needs you — the attention-inbox
    /// keyboard loop: invoke, respond, invoke again.
    func jumpToNextAttention() {
        refresh()
        let blocked = entries.filter { $0.phase == .attention }
        guard !blocked.isEmpty else { return }
        let next: AgentCenterEntry
        if let last = lastAttentionJump,
           let i = blocked.firstIndex(where: { $0.id == last }) {
            next = blocked[(i + 1) % blocked.count]
        } else {
            next = blocked[0]
        }
        lastAttentionJump = next.id
        jump(to: next)
    }

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
