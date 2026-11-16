import Foundation

/// One-click agent-integration install on an SSH host (a Coder
/// workspace is just such a host once `coder config-ssh` has run).
///
/// Runs ONE `ssh <host> python3 -` whose stdin is a generated
/// installer that mirrors the local installs on the remote home:
///   • `~/.conterm/agent-hook.sh` (the shared hook script)
///   • Claude / Codex / Muse hooks merged into their settings files
///     with the same sentinel, backup-once, preserve-everything-else
///     rules as `AgentHooks.install`
///   • Antigravity's `conterm` group in `~/.gemini/config/hooks.json`
///   • opencode / Pi / OMP plugin + extension files
///
/// Nothing runs without the user naming the host (Settings →
/// Integrations). BatchMode is on: a host that needs a password
/// prompt fails with ssh's own message rather than hanging the app.
/// A remote file that doesn't parse is skipped, never overwritten.
/// Removing the integration remotely is the local uninstall's mirror
/// image minus the travel: delete `~/.conterm` hooks by toggling the
/// same harnesses off on the host, or `rm -rf ~/.conterm` plus the
/// `# conterm` entries — the sentinel marks exactly what is ours.
@MainActor
enum RemoteAgentInstall {

    /// Relative-to-remote-home settings files for the JSON-hook
    /// harnesses, with their event lists (same as the local specs).
    private static var hookSpecs: [[String: Any]] {
        AgentHooks.all.map { spec in
            let rel: String
            switch spec.identity {
            case "claude": rel = ".claude/settings.json"
            case "codex":  rel = ".codex/hooks.json"
            case "muse":   rel = ".config/muse/settings.json"
            default:       rel = ""
            }
            return ["identity": spec.identity, "path": rel,
                    "events": spec.events]
        }
    }

    /// The generated python installer. File bodies travel base64 in
    /// one JSON payload so no quoting survives contact with ssh.
    static func installerScript() -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
        }
        let antigravityGroup = (try? JSONSerialization.data(
            withJSONObject: AntigravityIntegration.group())) ?? Data()
        let payload: [String: Any] = [
            "hookScript": b64(AgentHooks.script),
            "hookSpecs": hookSpecs,
            "antigravityGroup": b64(
                String(data: antigravityGroup, encoding: .utf8) ?? "{}"),
            "files": [
                [".config/opencode/plugin/conterm-agent.js",
                 b64(OpenCodeIntegration.plugin)],
                [".pi/agent/extensions/conterm-agent.ts",
                 b64(ExtensionIntegration.plugin(identity: "pi"))],
                [".omp/agent/extensions/conterm-agent.ts",
                 b64(ExtensionIntegration.plugin(identity: "omp"))],
                [".conterm/antigravity-statusline.py",
                 b64(AntigravityIntegration.statusScript)],
            ],
        ]
        let payloadJSON = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data()
        let payloadB64 = payloadJSON.base64EncodedString()
        return """
        import base64, json, os, shutil, sys

        P = json.loads(base64.b64decode("\(payloadB64)").decode())
        home = os.path.expanduser("~")
        out = []

        def write(rel, text, mode=None):
            path = os.path.join(home, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".conterm-tmp"
            with open(tmp, "w") as f:
                f.write(text)
            if mode is not None:
                os.chmod(tmp, mode)
            os.replace(tmp, path)
            out.append("wrote " + rel)

        def load_json(rel):
            path = os.path.join(home, rel)
            if not os.path.exists(path):
                return {}, True
            try:
                with open(path) as f:
                    root = json.load(f)
                return (root if isinstance(root, dict) else None), True
            except Exception:
                return None, False

        def backup_once(rel):
            path = os.path.join(home, rel)
            bak = path + ".conterm-backup"
            if os.path.exists(path) and not os.path.exists(bak):
                shutil.copyfile(path, bak)

        # Shared hook script + support dirs.
        os.makedirs(os.path.join(home, ".conterm", "agents"), exist_ok=True)
        os.makedirs(os.path.join(home, ".conterm", "run"), exist_ok=True)
        write(".conterm/agent-hook.sh",
              base64.b64decode(P["hookScript"]).decode(), 0o755)

        # JSON-hook harnesses: sentinel merge, exactly like the local one.
        SENTINEL = "# conterm"
        for spec in P["hookSpecs"]:
            rel = spec["path"]
            if not rel:
                continue
            root, ok = load_json(rel)
            if not ok or root is None:
                out.append("SKIPPED " + rel + " (unreadable JSON, untouched)")
                continue
            backup_once(rel)
            hooks = root.get("hooks")
            if not isinstance(hooks, dict):
                hooks = {}
            for event in spec["events"]:
                groups = hooks.get(event)
                if not isinstance(groups, list):
                    groups = []
                def ours(g):
                    return any(SENTINEL in (h.get("command") or "")
                               for h in (g.get("hooks") or [])
                               if isinstance(h, dict))
                groups = [g for g in groups if not ours(g)]
                cmd = ('sh "$HOME/.conterm/agent-hook.sh" %s %s '
                       '2>/dev/null; exit 0 %s' % (event, spec["identity"], SENTINEL))
                groups.append({"hooks": [{"type": "command", "command": cmd}]})
                hooks[event] = groups
            root["hooks"] = hooks
            write(rel, json.dumps(root, indent=2, sort_keys=True) + "\\n")
            out.append("hooks: " + spec["identity"])

        # Antigravity: replace only our named group.
        rel = ".gemini/config/hooks.json"
        root, ok = load_json(rel)
        if not ok or root is None:
            out.append("SKIPPED " + rel + " (unreadable JSON, untouched)")
        else:
            backup_once(rel)
            root["conterm"] = json.loads(
                base64.b64decode(P["antigravityGroup"]).decode())
            write(rel, json.dumps(root, indent=2, sort_keys=True) + "\\n")
            out.append("hooks: antigravity")

        # Plugin / extension files (ours alone; nothing merged).
        for rel, body in P["files"]:
            write(rel, base64.b64decode(body).decode())
            if rel.endswith("antigravity-statusline.py"):
                os.chmod(os.path.join(home, rel), 0o755)

        # Antigravity status line -> the usage reporter, unless the
        # user configured their own (theirs wins, usage stays off).
        rel = ".gemini/antigravity-cli/settings.json"
        root, ok = load_json(rel)
        if not ok or root is None:
            out.append("SKIPPED " + rel + " (unreadable JSON, untouched)")
        else:
            line = root.get("statusLine")
            if isinstance(line, dict) and \\
                    "antigravity-statusline" not in (line.get("command") or ""):
                out.append("statusline: user-configured, left alone")
            else:
                backup_once(rel)
                root["statusLine"] = {
                    "type": "command",
                    "command": "~/.conterm/antigravity-statusline.py",
                    "stack_with_default": True,
                    "enabled": True,
                }
                write(rel, json.dumps(root, indent=2, sort_keys=True) + "\\n")
                out.append("statusline: antigravity")

        print("\\n".join(out))
        """
    }

    /// Install on `host`. Completion receives ssh's combined output
    /// (the installer's summary, or ssh/python's error text).
    static func install(host: String,
                        completion: @escaping @MainActor (String) -> Void) {
        let script = installerScript()
        Task.detached(priority: .userInitiated) {
            let result = runSSH(host: host, stdin: script)
            await MainActor.run { completion(result) }
        }
    }

    private nonisolated static func runSSH(host: String, stdin: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = InstanceState.sshArguments + [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            host, "python3", "-",
        ]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        do {
            try p.run()
        } catch {
            return "couldn't run ssh: \(error.localizedDescription)"
        }
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus == 0 {
            return text.isEmpty ? "installed (no output)" : text
        }
        return "exit \(p.terminationStatus): \(text)"
    }
}
