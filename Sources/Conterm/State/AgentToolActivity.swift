import Foundation
import SwiftUI

/// What an agent's tool call is doing — the infrastructure it reaches for,
/// or the kind of work it is otherwise about. A pane shows one bubble per
/// kind in flight beside its agent pill, so a glance says "Claude is in
/// terraform and searching the web right now", and folds the finished
/// calls into a History capsule that opens the record.
///
/// The infrastructure cases are the tools Conterm has a surface for —
/// cockpits, widgets, overviews. The rest cover the agent's own hands:
/// shell, files, search, the web, sub-agents, plans, skills, MCP.
enum AgentToolKind: String, CaseIterable, Codable, Equatable {
    case terraform, ansible, kubernetes, helm, docker, ssh, git, github
    case shell, read, edit, search, webSearch, webFetch, agent, todo, skill, mcp

    var displayName: String {
        switch self {
        case .terraform:  return "Terraform"
        case .ansible:    return "Ansible"
        case .kubernetes: return "Kubernetes"
        case .helm:       return "Helm"
        case .docker:     return "Docker"
        case .ssh:        return "SSH"
        case .git:        return "Git"
        case .github:     return "GitHub"
        case .shell:      return "Shell"
        case .read:       return "Read"
        case .edit:       return "Edit"
        case .search:     return "Search"
        case .webSearch:  return "Web search"
        case .webFetch:   return "Web fetch"
        case .agent:      return "Sub-agent"
        case .todo:       return "Tasks"
        case .skill:      return "Skill"
        case .mcp:        return "MCP"
        }
    }

    /// Ring accent. Brands keep their colour, lifted a little because the
    /// ring glows on a near-black bed; the agent's own actions get hues of
    /// their own so a glance still tells them apart.
    var color: Color {
        switch self {
        case .terraform:  return Color(red: 0.60, green: 0.40, blue: 0.90)
        case .ansible:    return Color(red: 0.95, green: 0.30, blue: 0.28)
        case .kubernetes: return Color(red: 0.28, green: 0.50, blue: 0.95)
        case .helm:       return Color(red: 0.36, green: 0.66, blue: 0.96)
        case .docker:     return Color(red: 0.16, green: 0.62, blue: 0.95)
        case .ssh:        return Theme.sshAccent
        case .git:        return Color(red: 0.96, green: 0.40, blue: 0.26)
        case .github:     return Color(red: 0.82, green: 0.86, blue: 0.92)
        case .shell:      return Color(white: 0.78)
        case .read:       return Color(red: 0.55, green: 0.72, blue: 0.95)
        case .edit:       return Color(red: 0.45, green: 0.85, blue: 0.60)
        case .search:     return Color(red: 0.80, green: 0.62, blue: 0.95)
        case .webSearch:  return Color(red: 0.30, green: 0.82, blue: 0.80)
        case .webFetch:   return Color(red: 0.48, green: 0.56, blue: 0.98)
        case .agent:      return AgentTool.claude.glowColor
        case .todo:       return Color(red: 0.98, green: 0.80, blue: 0.35)
        case .skill:      return Color(red: 0.95, green: 0.70, blue: 0.90)
        case .mcp:        return Color(red: 0.92, green: 0.45, blue: 0.75)
        }
    }

    /// Executables that place a shell command in this family. Matched on
    /// the basename of a command's first word, so `/usr/local/bin/kubectl`
    /// and `kubectl` read the same.
    private static let executables: [String: AgentToolKind] = [
        "terraform": .terraform, "tofu": .terraform, "terragrunt": .terraform,
        "ansible": .ansible, "ansible-playbook": .ansible, "ansible-galaxy": .ansible,
        "ansible-vault": .ansible, "ansible-inventory": .ansible, "ansible-lint": .ansible,
        "ansible-pull": .ansible, "ansible-console": .ansible, "ansible-doc": .ansible,
        "kubectl": .kubernetes, "k9s": .kubernetes, "kubens": .kubernetes,
        "kubectx": .kubernetes, "minikube": .kubernetes, "kind": .kubernetes,
        "k3s": .kubernetes, "k3d": .kubernetes, "kustomize": .kubernetes, "oc": .kubernetes,
        "helm": .helm, "helmfile": .helm,
        "docker": .docker, "docker-compose": .docker, "podman": .docker,
        "podman-compose": .docker, "nerdctl": .docker, "colima": .docker,
        "ssh": .ssh, "scp": .ssh, "sftp": .ssh, "ssh-copy-id": .ssh, "mosh": .ssh,
        "git": .git,
        "gh": .github,
    ]

    /// Words a command may open with that say nothing about what it is.
    private static let wrappers: Set<String> = [
        "sudo", "command", "exec", "time", "nohup", "env", "builtin", "nice",
        "doas", "caffeinate", "stdbuf", "unbuffer", "timeout", "gtimeout",
    ]

    /// The kind of one Claude Code tool call, or nil for a call that is not
    /// an action (a question to the user, a mode switch). Bash commands are
    /// read segment by segment (`cd infra && terraform plan` is terraform; a
    /// pipeline is judged by its first classifiable stage) and are plain
    /// shell otherwise; MCP tools by their server name, generic MCP failing
    /// that.
    static func classify(toolName: String, command: String?) -> AgentToolKind? {
        if toolName.hasPrefix("mcp__") {
            return classifyMCP(server: toolName.dropFirst(5).split(separator: "__").first
                                       .map(String.init) ?? "") ?? .mcp
        }
        // Claude Code's tools by their names; Codex's by the names its hooks
        // and rollouts use for the same things.
        switch toolName {
        case "Bash", "shell", "local_shell", "exec_command", "container.exec", "shell_command":
            return command.flatMap(classify(command:)) ?? .shell
        case "BashOutput", "KillShell", "KillBash", "write_stdin":
            return .shell
        case "Read", "LS", "NotebookRead", "ReadMcpResourceTool", "ListMcpResourcesTool",
             "read_file", "view_image", "list_dir":
            return .read
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch":
            return .edit
        case "Grep", "Glob", "ToolSearch", "grep_files":
            return .search
        case "WebSearch", "web_search", "web_search_call":
            return .webSearch
        case "WebFetch", "web_fetch":
            return .webFetch
        case "Task", "Agent", "Workflow", "spawn_agent", "send_input", "wait_agent",
             "resume_agent", "close_agent":
            return .agent
        case "TodoWrite", "TodoRead", "update_plan":
            return .todo
        case "Skill", "SlashCommand":
            return .skill
        default:
            return nil
        }
    }

    /// The infrastructure family of a shell command, or nil for plain shell.
    static func classify(command: String) -> AgentToolKind? {
        for segment in segments(of: command) {
            if let kind = classify(segment: segment) { return kind }
        }
        return nil
    }

    private static func classifyMCP(server: String) -> AgentToolKind? {
        let s = server.lowercased()
        if s.contains("github") { return .github }
        if s.contains("terraform") || s.contains("tofu") { return .terraform }
        if s.contains("ansible") { return .ansible }
        if s.contains("kube") || s.contains("k8s") { return .kubernetes }
        if s.contains("helm") { return .helm }
        if s.contains("docker") || s.contains("podman") || s.contains("container") {
            return .docker
        }
        if s.contains("ssh") { return .ssh }
        if s.contains("git") { return .git }
        return nil
    }

    /// A command's simple commands, split at the operators that join them.
    /// Quotes are honored so a `"a && b"` argument stays inside its word.
    private static func segments(of command: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in command {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch; current.append(ch)
            case ";", "|", "&", "\n", "(", ")", "`":
                if !current.isEmpty { out.append(current) }
                current = ""
            default: current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func classify(segment: String) -> AgentToolKind? {
        let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for word in words {
            let w = String(word)
            // `FOO=bar cmd`: the assignment is not the command.
            if w.contains("="), !w.hasPrefix("-"),
               w.first.map({ $0.isLetter || $0 == "_" }) == true,
               w.prefix(while: { $0 != "=" }).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                continue
            }
            if wrappers.contains(w) { continue }
            // Options to a wrapper (`sudo -u root kubectl …`, `env -i …`).
            if w.hasPrefix("-") { continue }
            let name = (w as NSString).lastPathComponent
            return executables[name]
        }
        return nil
    }
}

/// One tool call an agent made that belongs to a surfaced family. Born
/// from the PreToolUse hook, closed by PostToolUse (or its failure
/// counterpart), and filled in from the session transcript — the full
/// command, the result text, the verdict — as the transcript catches up.
struct AgentToolRun: Identifiable, Equatable {
    /// Claude's tool_use id; the transcript keys its result on the same.
    let id: String
    let kind: AgentToolKind
    let startedAt: Date
    var endedAt: Date?
    var failed = false
    /// What the call was about: the Bash command line, a file path, a
    /// query, a URL, an MCP tool's name and input. The hook carries a short
    /// excerpt so a bubble can name its call at once; the transcript
    /// replaces it with the whole thing.
    var command: String?
    /// Result text once the transcript records it. Empty for a command
    /// that printed nothing; nil until read.
    var output: String?
    /// The transcript's tool_result has been applied. Distinguishes "no
    /// output" from "not read yet".
    var resultSeen = false

    var isRunning: Bool { endedAt == nil }

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Whether the transcript still has something to add.
    var wantsTranscript: Bool { command == nil || !resultSeen }

    /// One-line form of the command for a tooltip or a row.
    var title: String {
        guard let command, !command.isEmpty else { return kind.displayName }
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}

/// A tool event as the Claude hook reports it over the agent OSC:
///
///     tool:start:<tool_use_id>:<tool_name>:<command excerpt, base64>
///     tool:end:<tool_use_id>:<ok|fail>
///
/// The excerpt is the JSON-escaped text of the input's telling field —
/// the command, a path, a query — cut at a fixed length; decoding
/// unescapes what survived the cut.
enum AgentToolEvent: Equatable {
    case start(id: String, toolName: String, command: String?)
    case end(id: String, failed: Bool)

    /// Parse the text after `tool:`. nil for anything malformed.
    static func parse(_ rest: String) -> AgentToolEvent? {
        let parts = rest.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "start":
            guard parts.count >= 3 else { return nil }
            let encoded = parts.count > 3 ? parts[3] : ""
            return .start(id: parts[1], toolName: parts[2], command: decodeExcerpt(encoded))
        case "end":
            guard parts.count >= 3 else { return nil }
            return .end(id: parts[1], failed: parts[2] == "fail")
        default:
            return nil
        }
    }

    /// Base64 → JSON string body → text. A cut that landed inside an
    /// escape or a multi-byte character loses just that tail.
    static func decodeExcerpt(_ encoded: String) -> String? {
        guard !encoded.isEmpty,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        else { return nil }
        var escaped = String(decoding: data, as: UTF8.self)
        // A trailing lone backslash is half an escape.
        if escaped.hasSuffix("\\"), !escaped.hasSuffix("\\\\") { escaped.removeLast() }
        // Also drop a cut-off \uXXXX.
        if let r = escaped.range(of: #"\\u[0-9A-Fa-f]{0,3}$"#, options: .regularExpression) {
            escaped.removeSubrange(r)
        }
        let quoted = "\"" + escaped + "\""
        if let obj = try? JSONSerialization.jsonObject(with: Data(quoted.utf8),
                                                       options: [.fragmentsAllowed]),
           let s = obj as? String {
            return s.isEmpty ? nil : s
        }
        // Unparseable escapes: show the raw text rather than nothing.
        return escaped.isEmpty ? nil : escaped
    }
}

extension Pane {
    /// Cap on runs kept per session; the panel shows the newest first and
    /// the chrome only its tail.
    static let toolRunCap = 120

    /// Apply a hook-reported tool event. Starts for calls that are not
    /// actions are dropped here.
    func applyToolEvent(_ event: AgentToolEvent) {
        switch event {
        case .start(let id, let toolName, let command):
            guard let kind = AgentToolKind.classify(toolName: toolName, command: command),
                  !toolRuns.contains(where: { $0.id == id }) else { return }
            var run = AgentToolRun(id: id, kind: kind, startedAt: Date())
            if toolName.hasPrefix("mcp__") {
                run.command = command.map { "\(toolName) \($0)" } ?? toolName
            } else {
                run.command = command
            }
            clog("agent tools: hook start \(kind.rawValue) \(id)")
            toolRuns.append(run)
            if toolRuns.count > Self.toolRunCap {
                toolRuns.removeFirst(toolRuns.count - Self.toolRunCap)
            }
        case .end(let id, let failed):
            guard let i = toolRuns.firstIndex(where: { $0.id == id }) else { return }
            if toolRuns[i].endedAt == nil { toolRuns[i].endedAt = Date() }
            toolRuns[i].failed = toolRuns[i].failed || failed
        }
    }

    /// Slack allowed between the transcript's clock and the pane's when
    /// deciding whether a call predates the agent in this pane.
    private static let agentSinceGrace: TimeInterval = 5

    /// Take a transcript feed: calls not seen yet become runs (those of a
    /// surfaced family, made since the agent appeared here), and the rest
    /// get what the transcript recorded for them.
    func applyToolFeed(_ feed: AgentTranscriptStore.ToolFeed) {
        toolFeedPath = feed.path
        toolFeedCursor = feed.cursor
        var runs = toolRuns
        var changed = false
        let since = (agentSince ?? .distantPast).addingTimeInterval(-Self.agentSinceGrace)
        if !feed.new.isEmpty {
            clog("agent tools: feed since \(agentSince.map { "\($0)" } ?? "nil"), first record at \(feed.new[0].record.at)")
        }
        for (id, rec) in feed.new where !runs.contains(where: { $0.id == id }) {
            guard rec.at >= since,
                  let kind = AgentToolKind.classify(toolName: rec.name, command: rec.input)
            else { continue }
            var run = AgentToolRun(id: id, kind: kind, startedAt: rec.at)
            run.command = rec.commandLine
            if let endedAt = rec.endedAt {
                run.endedAt = endedAt
                run.failed = rec.isError ?? false
                run.output = rec.output ?? ""
                run.resultSeen = true
            }
            runs.append(run)
            changed = true
        }
        if runs.count > Self.toolRunCap {
            runs.removeFirst(runs.count - Self.toolRunCap)
            changed = true
        }
        if changed {
            let added = runs.count - toolRuns.count
            clog("agent tools: transcript feed +\(feed.new.count) records → \(added) new runs, cursor \(feed.cursor), \(runs.filter(\.isRunning).count) running")
            toolRuns = runs
        }
        applyToolRecords(feed.known)
    }

    /// Merge what the transcript recorded for these runs. The hook's end
    /// time stands when it has one; the transcript's verdict wins, since
    /// a non-zero exit reaches the hook as a plain completion.
    func applyToolRecords(_ records: [String: ToolRecord]) {
        var runs = toolRuns
        var changed = false
        for i in runs.indices {
            guard let rec = records[runs[i].id] else { continue }
            if let line = rec.commandLine, runs[i].command != line {
                runs[i].command = line; changed = true
            }
            guard let endedAt = rec.endedAt, !runs[i].resultSeen else { continue }
            if runs[i].endedAt == nil { runs[i].endedAt = endedAt }
            if let err = rec.isError { runs[i].failed = err }
            runs[i].output = rec.output ?? ""
            runs[i].resultSeen = true
            changed = true
        }
        if changed { toolRuns = runs }
    }

    /// Close every run still open: called when the turn ends, since no
    /// tool can outlive it. Outcome stays as last known.
    func settleToolRuns() {
        guard toolRuns.contains(where: \.isRunning) else { return }
        let now = Date()
        for i in toolRuns.indices where toolRuns[i].endedAt == nil {
            toolRuns[i].endedAt = now
        }
    }
}
