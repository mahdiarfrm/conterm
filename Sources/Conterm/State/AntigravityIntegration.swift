import Foundation

/// Installs / removes Conterm's hooks in Antigravity's
/// `~/.gemini/config/hooks.json`, driving the per-pane status pill
/// with the same `agent-hook.sh` the Claude-family hooks use.
///
/// Antigravity's schema differs from Claude's: the file maps hook
/// GROUP names to event configs. Ours is one group, `conterm`:
///   • SessionStart  → start      → "Antigravity is Ready."
///   • PreInvocation → prompt     → "Antigravity is thinking…"
///   • PreToolUse    → tool:start → thinking, plus a tool bubble
///   • PostToolUse   → tool:end   → the bubble retires
///   • Stop          → idle       → back to Ready
/// Tool events carry a `matcher`; the others take bare handlers.
/// There is no Notification/PermissionRequest event and no
/// SessionEnd — `Stop` plus the pane's command-finished signal
/// cover the end of a session.
///
/// Merge is non-destructive, mirroring `AgentHooks`: other groups
/// and keys are kept, the original file is backed up once to
/// `hooks.json.conterm-backup`, and uninstall removes ONLY the
/// `conterm` group. A file that exists but doesn't parse is left
/// untouched.
@MainActor
enum AntigravityIntegration {
    static let identity = "antigravity"
    static let groupName = "conterm"

    static var settingsPath: String {
        "\(InstanceState.userHome)/.gemini/config/hooks.json"
    }
    private static var backupPath: String { settingsPath + ".conterm-backup" }

    static var isInstalled: Bool { isInstalled(at: settingsPath) }

    static func install() {
        AgentHooks.writeScript()
        install(at: settingsPath)
        installStatusLine()
    }
    static func uninstall() {
        uninstall(at: settingsPath)
        uninstallStatusLine()
        try? FileManager.default.removeItem(atPath: statusScriptPath)
    }

    /// Rewrite our group to the current event set on launch when
    /// already installed, like the other integrations.
    static func refreshIfInstalled() {
        if isInstalled { install() }
    }

    // MARK: - Path-parameterized core (test seam)

    static func isInstalled(at path: String) -> Bool {
        readRoot(at: path)?[groupName] is [String: Any]
    }

    static func install(at path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: path)
        let existing = readRoot(at: path)
        if exists && existing == nil {
            NSLog("conterm: \(path) isn't a readable JSON object; hooks not installed")
            return
        }
        if exists, !FileManager.default.fileExists(atPath: path + ".conterm-backup") {
            try? FileManager.default.copyItem(
                atPath: AgentHooks.linkTarget(of: path),
                toPath: path + ".conterm-backup")
        }
        var root = existing ?? [:]
        root[groupName] = group()
        writeRoot(root, at: path)
    }

    static func uninstall(at path: String) {
        guard var root = readRoot(at: path) else { return }
        root.removeValue(forKey: groupName)
        writeRoot(root, at: path)
        // The shared script goes only with the last JSON-hook agent.
        if !AgentHooks.all.contains(where: { AgentHooks.isInstalled($0) }) {
            try? FileManager.default.removeItem(atPath: AgentHooks.scriptPath)
        }
    }

    /// Our hook group in Antigravity's schema. Commands run the
    /// shared script exactly like the Claude-family entries.
    static func group() -> [String: Any] {
        func cmd(_ event: String) -> String {
            "sh \"$HOME/.conterm/agent-hook.sh\" \(event) \(identity) 2>/dev/null; exit 0 # conterm"
        }
        func bare(_ event: String) -> [[String: Any]] {
            [["type": "command", "command": cmd(event)]]
        }
        func tool(_ event: String) -> [[String: Any]] {
            [["matcher": "*",
              "hooks": [["type": "command", "command": cmd(event)]]]]
        }
        return [
            "SessionStart": bare("SessionStart"),
            "PreInvocation": bare("PreInvocation"),
            "PreToolUse": tool("PreToolUse"),
            "PostToolUse": tool("PostToolUse"),
            "Stop": bare("Stop"),
        ]
    }

    // MARK: - Status line (usage reporting)

    /// The CLI's own settings, where the `statusLine` block lives
    /// (distinct from the hooks file above).
    static var cliSettingsPath: String {
        "\(InstanceState.userHome)/.gemini/antigravity-cli/settings.json"
    }
    static var statusScriptPath: String {
        "\(InstanceState.userHome)/.conterm/antigravity-statusline.py"
    }
    private static let statusCommand = "~/.conterm/antigravity-statusline.py"

    /// The reporter: reads the status-line JSON on stdin, prints a
    /// compact line for the TUI (stacked under the built-in one),
    /// and reports the harness's own token/cost totals to Conterm —
    /// per-pane file locally, usage event over the forwarded socket
    /// (or the tty) remotely. Always exits 0 and prints something:
    /// a status line that fails is worse than a plain one.
    nonisolated static let statusScript = #"""
    #!/usr/bin/env python3
    # Conterm's Antigravity status line. Written by Conterm (Settings
    # → Antigravity integration); reports token/cost usage back.
    import base64, json, os, socket, sys

    def compact(n):
        if n >= 1_000_000: return f"{n / 1e6:.1f}M"
        if n >= 10_000: return f"{n / 1e3:.0f}k"
        if n >= 1_000: return f"{n / 1e3:.1f}k"
        return str(n)

    try:
        payload = json.load(sys.stdin)
    except Exception:
        print("")
        sys.exit(0)

    model = payload.get("model") or {}
    name = model.get("display_name") or model.get("id") or ""
    cw = payload.get("context_window") or {}
    cu = cw.get("current_usage") or {}
    usage = {
        "m": name,
        "i": cw.get("total_input_tokens") or 0,
        "o": cw.get("total_output_tokens") or 0,
        "cc": cu.get("cache_creation_input_tokens") or 0,
        "cr": cu.get("cache_read_input_tokens") or 0,
    }
    cost = (payload.get("cost") or {}).get("total_usd")
    if isinstance(cost, (int, float)):
        usage["usd"] = cost

    parts = []
    if name: parts.append(name)
    total = usage["i"] + usage["o"]
    if total: parts.append(compact(total) + " tok")
    if "usd" in usage: parts.append("$%.2f" % usage["usd"])
    print(" · ".join(parts))

    pane = os.environ.get("CONTERM_PANE_ID", "")
    if pane:
        try:
            d = os.path.expanduser("~/.conterm/usage")
            os.makedirs(d, exist_ok=True)
            path = os.path.join(d, "pane-" + pane + ".json")
            prev = None
            try:
                with open(path) as f: prev = json.load(f)
            except Exception:
                pass
            record = dict(usage)
            record["agent"] = "antigravity"
            record["conversation"] = payload.get("conversation_id", "")
            if prev != record:
                tmp = path + ".tmp"
                with open(tmp, "w") as f: json.dump(record, f)
                os.replace(tmp, path)
                state = "usage:" + base64.b64encode(
                    json.dumps(usage).encode()).decode()
                # Socket only (a remote pane's forwarded socket). A local
                # pane has no socket and its usage file above is already
                # read by Conterm; a usage OSC here would compete with
                # idle/attention for the one-notification-per-second
                # budget and can leave the pill stuck on thinking.
                sock = os.environ.get("CONTERM_AGENT_SOCK", "")
                if sock:
                    try:
                        s = socket.socket(socket.AF_UNIX)
                        s.settimeout(2)
                        s.connect(sock)
                        s.sendall((json.dumps({
                            "agent": "antigravity", "pane": pane,
                            "state": state}) + "\n").encode())
                        s.close()
                    except Exception:
                        pass
        except Exception:
            pass
    """#

    /// Write the reporter script (executable), skipping the write
    /// when it already holds this exact text.
    private static func writeStatusScript() {
        let url = URL(fileURLWithPath: statusScriptPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing == statusScript { return }
        try? statusScript.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: statusScriptPath)
    }

    /// Point the CLI's status line at the reporter, stacked under
    /// the built-in one. A status line the user configured
    /// themselves is never replaced — usage then stays unreported.
    static func installStatusLine() {
        writeStatusScript()
        installStatusLine(at: cliSettingsPath)
    }

    static func installStatusLine(at path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: path)
        let existing = readRoot(at: path)
        if exists && existing == nil {
            NSLog("conterm: \(path) isn't a readable JSON object; status line not installed")
            return
        }
        var root = existing ?? [:]
        if let line = root["statusLine"] as? [String: Any],
           let cmd = line["command"] as? String,
           !cmd.contains("antigravity-statusline") {
            NSLog("conterm: Antigravity status line is user-configured; usage reporting off")
            return
        }
        if exists, !FileManager.default.fileExists(atPath: path + ".conterm-backup") {
            try? FileManager.default.copyItem(
                atPath: AgentHooks.linkTarget(of: path),
                toPath: path + ".conterm-backup")
        }
        root["statusLine"] = [
            "type": "command",
            "command": statusCommand,
            "stack_with_default": true,
            "enabled": true,
        ]
        writeRoot(root, at: path)
    }

    static func uninstallStatusLine() { uninstallStatusLine(at: cliSettingsPath) }

    static func uninstallStatusLine(at path: String) {
        guard var root = readRoot(at: path),
              let line = root["statusLine"] as? [String: Any],
              let cmd = line["command"] as? String,
              cmd.contains("antigravity-statusline") else { return }
        root.removeValue(forKey: "statusLine")
        writeRoot(root, at: path)
    }

    /// The reporter's latest usage for a pane (local file). Freshness
    /// rides on the roster tick: the file updates every status-line
    /// render while the agent runs.
    static func usage(forPane id: UUID) -> AgentUsage? {
        let path = "\(InstanceState.userHome)/.conterm/usage/pane-\(id.uuidString).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              var usage = ReportedUsage.agentUsage(from: obj) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        usage.lastActivity = attrs?[.modificationDate] as? Date
        usage.firstActivity = attrs?[.creationDate] as? Date
        return usage
    }

    // MARK: - JSON helpers (preserve unknown keys)

    private static func readRoot(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return nil }
        return root
    }

    private static func writeRoot(_ root: [String: Any], at path: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: AgentHooks.linkTarget(of: path)),
                        options: .atomic)
    }
}
