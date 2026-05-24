import Foundation

/// Installs / removes Claude Code hooks in ~/.claude/settings.json so a
/// running Claude session drives Conterm's per-pane status pill.
///
/// Mechanism: the hooks `printf` a tiny private OSC 9 escape to the
/// controlling tty —  `OSC 9 ; conterm-agent:claude:<state> BEL` — which
/// libghostty hands Conterm as a desktop-notification action. Conterm
/// only reacts to that exact `conterm-agent:` prefix, so it never
/// hijacks real notifications. States:
///   • SessionStart    → start     → pill: "Claude is Ready."
///   • UserPromptSubmit → prompt   → pill: "Claude is thinking…" (neon)
///   • Stop             → idle     → back to "Claude is Ready."
///   • Notification     → attention → "Claude needs you"
///   • SessionEnd       → end      → pill disappears
///
/// Merge is non-destructive: the user's existing hooks/keys are kept,
/// our entries carry a `# conterm` sentinel so uninstall removes ONLY
/// ours, and the original file is backed up once.
@MainActor
enum ClaudeIntegration {
    private static var dir: String { "\(NSHomeDirectory())/.claude" }
    private static var path: String { "\(dir)/settings.json" }
    private static var backup: String { "\(dir)/settings.json.conterm-backup" }
    private static let sentinel = "# conterm"

    /// One command per event. `> /dev/tty` targets the terminal that
    /// owns the Claude process (the pane), not Claude's stdout.
    private static func emit(_ state: String) -> String {
        // A Claude hook is a detached subprocess with NO controlling
        // terminal — `> /dev/tty` fails with "Device not configured",
        // and that shell error leaks to Claude Code as a hook error.
        // So: NEVER touch /dev/tty. Walk the parent chain up to the
        // `claude` process (which keeps the pane's pts as its tty),
        // write the escape to that real device only if it's writable,
        // and ALWAYS `exit 0` with no stderr so Claude never reports
        // an error even when no tty is found. `\033`/`\a` are octal
        // ESC + BEL that POSIX `printf` expands.
        let seq = "\\033]9;conterm-agent:claude:\(state)\\a"
        return "p=$PPID; n=0; while [ \"$n\" -lt 15 ]; do "
             + "case \"$p\" in ''|*[!0-9]*|0|1) break;; esac; "
             + "t=$(ps -o tty= -p \"$p\" 2>/dev/null | tr -d ' '); "
             + "if [ -n \"$t\" ] && [ \"$t\" != '??' ] && [ -w \"/dev/$t\" ]; then "
             + "printf '\(seq)' > \"/dev/$t\" 2>/dev/null; break; fi; "
             + "p=$(ps -o ppid= -p \"$p\" 2>/dev/null | tr -d ' '); "
             + "n=$((n+1)); done; exit 0 \(sentinel)"
    }
    private static let commands: [String: String] = [
        "SessionStart":     emit("start"),
        "UserPromptSubmit": emit("prompt"),
        // PreToolUse fires before each tool call, so the pill
        // refreshes to "thinking" while Claude is actively working
        // (e.g. after responding to a Notification).
        "PreToolUse":       emit("prompt"),
        "Stop":             emit("idle"),
        "Notification":     emit("attention"),
        "SessionEnd":       emit("end"),
    ]

    static var isInstalled: Bool {
        guard let root = readJSON(),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (event, _) in commands {
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

    static func install() {
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        // Back up the user's original once.
        if FileManager.default.fileExists(atPath: path),
           !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }
        var root = readJSON() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, cmd) in commands {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Drop any prior conterm entry first (idempotent re-install).
            groups = stripOurs(groups)
            groups.append([
                "hooks": [["type": "command", "command": cmd]]
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        writeJSON(root)
    }

    static func uninstall() {
        guard var root = readJSON(),
              var hooks = root["hooks"] as? [String: Any] else { return }
        for event in commands.keys {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = stripOurs(groups)
            if groups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }
        writeJSON(root)
    }

    /// Called at app launch. If any of our hooks are present in
    /// `~/.claude/settings.json`, rewrites them to match the current
    /// command set. This keeps the on-disk install in sync when
    /// Conterm adds or changes a hook between releases, so users
    /// never have to manually toggle the integration off and on.
    static func refreshIfInstalled() {
        if hasAnyHook { install() }
    }

    /// True if any hook event in the user's settings still carries
    /// our sentinel command — used by `refreshIfInstalled` to catch
    /// partial installs (e.g. an older release missing a hook event).
    private static var hasAnyHook: Bool {
        guard let root = readJSON(),
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

    private static func readJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    private static func writeJSON(_ root: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
