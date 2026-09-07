import Foundation

/// Where one agent CLI keeps its lifecycle hooks, which events it raises,
/// and the identity the hook script reports under.
struct AgentHookSpec {
    /// The `<tool>` in `conterm-agent:<tool>:…` — also `AgentTool.rawValue`.
    let identity: String
    /// JSON file holding a top-level `hooks` object keyed by event.
    let settingsPath: String
    let events: [String]

    var backupPath: String { settingsPath + ".conterm-backup" }
}

/// Installs / removes lifecycle hooks for the agent CLIs that speak the
/// same hook protocol — Claude Code (`~/.claude/settings.json`) and Codex
/// (`~/.codex/hooks.json`) — so a running session drives Conterm's
/// per-pane status pill and the tool bubbles beside it.
///
/// Mechanism: every hook event runs one bundled script
/// (`~/.conterm/agent-hook.sh`, written here) that `printf`s a private
/// OSC 9 escape to the controlling tty — `OSC 9 ; conterm-agent:<tool>:…
/// BEL` — which libghostty hands Conterm as a desktop-notification
/// action. Conterm only reacts to that exact `conterm-agent:` prefix, so
/// it never hijacks real notifications. Events:
///   • SessionStart          → start      → pill: "<Agent> is Ready."
///   • UserPromptSubmit      → prompt     → pill: "<Agent> is thinking…" (neon)
///   • PreToolUse            → tool:start → thinking, plus a bubble for the tool
///   • PostToolUse           → tool:end:ok   → the bubble retires to History
///   • PostToolUseFailure    → tool:end:fail   (Claude only)
///   • Stop                  → idle       → back to "<Agent> is Ready."
///   • Notification /
///     PermissionRequest     → attention  → "<Agent> needs you"
///   • SessionEnd            → end        → pill disappears
///
/// libghostty passes on at most one desktop notification per second for
/// the whole app, so the tool events are an accelerator: the session
/// transcript, polled while the agent works, is the record they speed up.
///
/// Merge is non-destructive: the user's existing hooks/keys are kept,
/// our entries carry a `# conterm` sentinel so uninstall removes ONLY
/// ours, and the original file is backed up once. The script is rewritten
/// at every launch (see `refreshIfInstalled`), so a release that changes
/// it needs no toggle from the user.
@MainActor
enum AgentHooks {
    static let claude = AgentHookSpec(
        identity: "claude",
        settingsPath: "\(NSHomeDirectory())/.claude/settings.json",
        events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                 "PostToolUseFailure", "Stop", "Notification", "SessionEnd"])

    /// Codex raises the same events under the same payload field names,
    /// with two differences: a prompt for approval is PermissionRequest,
    /// and there is no PostToolUseFailure — PostToolUse fires only after a
    /// tool succeeds, so a failed call's bubble is retired by the rollout
    /// poll or by `settleToolRuns` when the turn ends.
    static let codex = AgentHookSpec(
        identity: "codex",
        settingsPath: "\(NSHomeDirectory())/.codex/hooks.json",
        events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                 "PermissionRequest", "Stop", "SessionEnd"])

    static let all = [claude, codex]

    private static let sentinel = "# conterm"

    /// The hook script's home. `$HOME` rather than the expanded path in the
    /// settings entry, so a synced settings file still points somewhere
    /// sensible on another machine (and does nothing there until Conterm
    /// writes the script).
    nonisolated static var scriptPath: String { "\(NSHomeDirectory())/.conterm/agent-hook.sh" }
    private static let scriptRef = "\"$HOME/.conterm/agent-hook.sh\""
    /// The script's name in earlier releases; removed when the current one
    /// is written.
    nonisolated private static var legacyScriptPath: String {
        "\(NSHomeDirectory())/.conterm/claude-hook.sh"
    }

    /// One command per event. The script never writes to stdout/stderr and
    /// exits 0, and the trailing `exit 0` covers the script being absent —
    /// a hook that fails surfaces as an error inside the agent.
    private static func command(for event: String, spec: AgentHookSpec) -> String {
        "sh \(scriptRef) \(event) \(spec.identity) 2>/dev/null; exit 0 \(sentinel)"
    }

    /// The hook script. POSIX sh plus awk, ps, base64: nothing that isn't on
    /// a stock macOS. See `AgentToolEvent` for the tool payload it emits.
    nonisolated static let script = #"""
    #!/bin/sh
    # Conterm's agent hook. Written by Conterm (Settings → Claude Code /
    # Codex integration) and rewritten at every launch; edits here do not
    # survive.
    #
    # The agent runs this once per hook event with the event's JSON on
    # stdin: `agent-hook.sh <Event> <agent>`, where <agent> is `claude` or
    # `codex`. It writes a private OSC 9 escape to the terminal that owns
    # the agent process, which is how the pane learns what the agent is
    # doing:
    #
    #   conterm-agent:<agent>:<start|prompt|idle|attention|end>:<transcript_path>
    #   conterm-agent:<agent>:tool:start:<tool_use_id>:<tool_name>:<excerpt, base64>
    #   conterm-agent:<agent>:tool:end:<tool_use_id>:<ok|fail>
    #
    # A hook is a detached subprocess with no controlling terminal, so
    # /dev/tty is never opened: the parent chain is walked up to the agent
    # process, whose tty is the pane's. Nothing is written to stdout or
    # stderr, and the exit status is always 0 — a failing hook is reported
    # as an error inside the agent.
    PATH=/usr/bin:/bin:$PATH
    event=$1
    agent=${2:-claude}
    input=$(cat 2>/dev/null)
    case $agent in codex) idpos=first ;; *) idpos=last ;; esac

    # jfield <key> <first|last>: the string value of a JSON key, by its
    # first or last occurrence in the input. The value keeps its JSON
    # escapes. Keys nested inside tool_input / tool_response can repeat a
    # top-level name, so the caller picks the occurrence that is the real
    # key. tool_name precedes both. tool_use_id sits after both for Claude
    # and before them for Codex, so $idpos carries the side it is on.
    jfield() {
        printf '%s' "$input" | awk -v k="$1" -v which="$2" '
        {
            key = "\"" k "\""
            pos = 0
            if (which == "last") {
                s = $0; base = 0
                while ((i = index(s, key)) > 0) { pos = base + i; base += i; s = substr(s, i + 1) }
            } else {
                pos = index($0, key)
            }
            if (!pos) next
            s = substr($0, pos + length(key))
            if (s !~ /^[[:space:]]*:[[:space:]]*"/) next
            sub(/^[[:space:]]*:[[:space:]]*"/, "", s)
            out = ""; n = length(s)
            for (j = 1; j <= n; j++) {
                c = substr(s, j, 1)
                if (c == "\\") { out = out c substr(s, j + 1, 1); j++; continue }
                if (c == "\"") break
                out = out c
            }
            print out
            exit
        }'
    }

    # The pane's tty: the first ancestor with a real terminal. CONTERM_HOOK_TTY
    # overrides it (a file works), which is how the script is tested.
    find_tty() {
        if [ -n "$CONTERM_HOOK_TTY" ]; then printf '%s' "$CONTERM_HOOK_TTY"; return; fi
        p=$PPID; n=0
        while [ "$n" -lt 15 ]; do
            case "$p" in ''|*[!0-9]*|0|1) return;; esac
            t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
            if [ -n "$t" ] && [ "$t" != '??' ] && [ -w "/dev/$t" ]; then
                printf '/dev/%s' "$t"; return
            fi
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
            n=$((n+1))
        done
    }

    tty=$(find_tty)
    [ -n "$tty" ] || exit 0
    send() { printf '\033]9;conterm-agent:%s:%s\a' "$agent" "$1" >> "$tty" 2>/dev/null; }

    case "$event" in
        SessionStart)     send "start:$(jfield transcript_path first)" ;;
        UserPromptSubmit) send "prompt:$(jfield transcript_path first)" ;;
        PreToolUse)
            # One event, not a phase plus a tool: libghostty admits one
            # desktop notification per second app-wide, and the second of a
            # pair is the one that is lost. A tool starting is the agent
            # working; the app reads it that way.
            tid=$(jfield tool_use_id "$idpos")
            [ -n "$tid" ] || { send "prompt:$(jfield transcript_path first)"; exit 0; }
            tn=$(jfield tool_name first)
            # What the call is about, in the input's own words: the command
            # for Bash, else the first of the fields the other tools carry.
            cmd=
            for k in command file_path query url pattern skill description; do
                cmd=$(jfield "$k" first | cut -c1-200 | tr -d '\n')
                [ -n "$cmd" ] && break
            done
            cmd=$(printf '%s' "$cmd" | base64 | tr -d '\n')
            send "tool:start:$tid:$tn:$cmd"
            ;;
        PostToolUse)
            tid=$(jfield tool_use_id "$idpos")
            [ -n "$tid" ] && send "tool:end:$tid:ok"
            ;;
        PostToolUseFailure)
            tid=$(jfield tool_use_id "$idpos")
            [ -n "$tid" ] && send "tool:end:$tid:fail"
            ;;
        Stop)             send "idle:$(jfield transcript_path first)" ;;
        Notification|PermissionRequest)
                          send "attention:$(jfield transcript_path first)" ;;
        SessionEnd)       send "end:" ;;
    esac
    exit 0
    """#

    static func isInstalled(_ spec: AgentHookSpec) -> Bool {
        guard let root = readJSON(spec),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for event in spec.events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let has = groups.contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains(sentinel) == true
                }
            }
            if !has { return false }
        }
        return true
    }

    static func install(_ spec: AgentHookSpec) {
        writeScript()
        let dir = (spec.settingsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Back up the user's original once.
        if FileManager.default.fileExists(atPath: spec.settingsPath),
           !FileManager.default.fileExists(atPath: spec.backupPath) {
            try? FileManager.default.copyItem(atPath: spec.settingsPath, toPath: spec.backupPath)
        }
        var root = readJSON(spec) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in spec.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Drop any prior conterm entry first (idempotent re-install).
            groups = stripOurs(groups)
            groups.append([
                "hooks": [["type": "command", "command": command(for: event, spec: spec)]]
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        writeJSON(root, spec)
    }

    static func uninstall(_ spec: AgentHookSpec) {
        if let root = readJSON(spec), var hooks = root["hooks"] as? [String: Any] {
            var root = root
            // Strip by sentinel across every event, so a hook a past release
            // registered under an event this one no longer uses goes too.
            for (event, value) in hooks {
                guard var groups = value as? [[String: Any]] else { continue }
                groups = stripOurs(groups)
                if groups.isEmpty { hooks.removeValue(forKey: event) }
                else { hooks[event] = groups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") }
            else { root["hooks"] = hooks }
            writeJSON(root, spec)
        }
        // The script serves every agent; it goes only with the last of them.
        if !all.contains(where: { $0.identity != spec.identity && hasAnyHook($0) }) {
            try? FileManager.default.removeItem(atPath: scriptPath)
        }
    }

    /// Called at app launch. If any of our hooks are present in an agent's
    /// settings, rewrites them (and the script) to match the current
    /// command set. This keeps the on-disk install in sync when Conterm
    /// adds or changes a hook between releases, so users never have to
    /// manually toggle the integration off and on.
    static func refreshIfInstalled() {
        for spec in all where hasAnyHook(spec) { install(spec) }
    }

    /// Write the hook script, executable. Skipped when the file already
    /// holds this exact text, so a launch touches nothing.
    static func writeScript() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: legacyScriptPath)
        let url = URL(fileURLWithPath: scriptPath)
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == script {
            return
        }
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    /// True if any hook event in the agent's settings still carries our
    /// sentinel command — used by `refreshIfInstalled` to catch partial
    /// installs (e.g. an older release missing a hook event).
    private static func hasAnyHook(_ spec: AgentHookSpec) -> Bool {
        guard let root = readJSON(spec),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let has = groups.contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains(sentinel) == true
                }
            }
            if has { return true }
        }
        return false
    }

    // MARK: - JSON helpers (preserve unknown keys)

    private static func stripOurs(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { g -> [String: Any]? in
            guard var inner = g["hooks"] as? [[String: Any]] else { return g }
            inner.removeAll {
                ($0["command"] as? String)?.contains(sentinel) == true
            }
            if inner.isEmpty { return nil }
            var ng = g
            ng["hooks"] = inner
            return ng
        }
    }

    private static func readJSON(_ spec: AgentHookSpec) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: spec.settingsPath)),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    private static func writeJSON(_ root: [String: Any], _ spec: AgentHookSpec) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: spec.settingsPath), options: .atomic)
    }
}

/// Claude Code's hooks in `~/.claude/settings.json`.
@MainActor
enum ClaudeIntegration {
    static var isInstalled: Bool { AgentHooks.isInstalled(AgentHooks.claude) }
    static func install() { AgentHooks.install(AgentHooks.claude) }
    static func uninstall() { AgentHooks.uninstall(AgentHooks.claude) }
    static func refreshIfInstalled() { AgentHooks.refreshIfInstalled() }
    nonisolated static var script: String { AgentHooks.script }
}

/// Codex's hooks in `~/.codex/hooks.json` (lifecycle hooks are on by
/// default in Codex; `features.hooks = false` would silence these).
@MainActor
enum CodexIntegration {
    static var isInstalled: Bool { AgentHooks.isInstalled(AgentHooks.codex) }
    static func install() { AgentHooks.install(AgentHooks.codex) }
    static func uninstall() { AgentHooks.uninstall(AgentHooks.codex) }
}
