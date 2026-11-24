import Foundation
import Testing
@testable import Conterm

/// The newer harness integrations: Muse's hook spec, Antigravity's
/// named-group hooks file, and the Pi/OMP extension template. All IO
/// happens at per-test temp paths; nothing touches the real home.
@MainActor
struct AgentIntegrationTests {

    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-agents-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Muse speaks the Claude hook protocol: the spec must carry the
    /// identity the OSC parser expects and land in Muse's settings.
    @Test func museSpecShape() {
        #expect(AgentHooks.muse.identity == "muse")
        #expect(AgentHooks.muse.settingsPath.hasSuffix("/.config/muse/settings.json"))
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse",
                      "PostToolUse", "Stop", "SessionEnd"] {
            #expect(AgentHooks.muse.events.contains(event))
        }
        #expect(AgentHooks.all.contains { $0.identity == "muse" })
        #expect(AgentTool(rawValue: "muse") == .muse)
    }

    /// Every harness identity the hook script can emit resolves to a
    /// named, non-generic AgentTool (a typo here shows "Agent").
    @Test func agentToolIdentities() {
        for (raw, name) in [("claude", "Claude"), ("codex", "Codex"),
                            ("opencode", "opencode"), ("muse", "Muse"),
                            ("antigravity", "Antigravity"), ("pi", "Pi"),
                            ("omp", "OMP")] {
            let tool = AgentTool(rawValue: raw)
            #expect(tool != nil && tool != .generic)
            #expect(tool?.displayName == name)
            #expect(tool?.hasTranscript == (raw == "claude" || raw == "codex"))
        }
    }

    /// Antigravity install adds ONLY our group, preserves the user's
    /// groups, backs the file up once, and uninstall removes only us.
    @Test func antigravityInstallPreservesOtherGroups() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/hooks.json"
        try #"{"mine":{"Stop":[{"type":"command","command":"echo hi"}]}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        AntigravityIntegration.install(at: path)
        #expect(AntigravityIntegration.isInstalled(at: path))
        #expect(FileManager.default.fileExists(atPath: path + ".conterm-backup"))

        let root = try #require(
            (try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any])
        #expect(root["mine"] != nil)
        let group = try #require(root["conterm"] as? [String: Any])
        // Tool events carry a matcher + hooks array; the rest are bare.
        let pre = try #require(group["PreToolUse"] as? [[String: Any]])
        #expect(pre.first?["matcher"] as? String == "*")
        let preCmd = (pre.first?["hooks"] as? [[String: Any]])?
            .first?["command"] as? String ?? ""
        #expect(preCmd.contains("antigravity"))
        let start = try #require(group["SessionStart"] as? [[String: Any]])
        let startCmd = start.first?["command"] as? String ?? ""
        #expect(startCmd.contains("agent-hook.sh"))

        AntigravityIntegration.uninstall(at: path)
        #expect(!AntigravityIntegration.isInstalled(at: path))
        let after = try #require(
            (try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any])
        #expect(after["mine"] != nil)
        #expect(after["conterm"] == nil)
    }

    /// An unparsable existing hooks file is left byte-for-byte alone.
    @Test func antigravityInstallLeavesBrokenFileAlone() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/hooks.json"
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        AntigravityIntegration.install(at: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "not json")
        #expect(!AntigravityIntegration.isInstalled(at: path))
    }

    /// Remote channel events: one JSON object per line, strict
    /// enough that tty noise can never become an agent state.
    @Test func remoteEventParsing() {
        let event = RemoteAgentChannel.parse(
            line: #"{"agent":"claude","pane":"P1","state":"start:/t.jsonl"}"#)
        #expect(event == RemoteAgentChannel.Event(
            agent: "claude", pane: "P1", state: "start:/t.jsonl"))
        #expect(RemoteAgentChannel.parse(line: "not json") == nil)
        #expect(RemoteAgentChannel.parse(
            line: #"{"agent":"","pane":"P1","state":"start:"}"#) == nil)
        #expect(RemoteAgentChannel.parse(
            line: #"{"agent":"pi","pane":"P1"}"#) == nil)
    }

    /// The generated remote installer carries every harness: the
    /// payload decodes to the hook script, the three JSON-hook specs,
    /// the Antigravity group, and the plugin/extension files.
    @Test func remoteInstallerPayload() throws {
        let script = RemoteAgentInstall.installerScript()
        #expect(script.hasPrefix("import base64"))
        #expect(script.contains("SKIPPED"))
        let start = try #require(script.range(of: "b64decode(\""))
        let rest = script[start.upperBound...]
        let end = try #require(rest.firstIndex(of: "\""))
        let payloadData = try #require(
            Data(base64Encoded: String(rest[..<end])))
        let payload = try #require(
            (try JSONSerialization.jsonObject(with: payloadData)) as? [String: Any])
        #expect((payload["hookScript"] as? String)?.isEmpty == false)
        let specs = try #require(payload["hookSpecs"] as? [[String: Any]])
        #expect(Set(specs.compactMap { $0["identity"] as? String })
                    == ["claude", "codex", "muse"])
        let files = try #require(payload["files"] as? [[String]])
        #expect(files.count == 4)
        #expect(files[0][0].contains("opencode"))
        #expect(files[3][0].contains("antigravity-statusline"))
    }

    /// The remote installer, executed with python3 against a fake
    /// home, lands every harness's files and merges hooks without
    /// disturbing a pre-existing user hook. This is the exact script
    /// `ssh <host> python3 -` runs.
    @Test func remoteInstallerExecutesAgainstFakeHome() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = "\(dir)/home"
        try FileManager.default.createDirectory(
            atPath: "\(home)/.claude", withIntermediateDirectories: true)
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
            .write(toFile: "\(home)/.claude/settings.json",
                   atomically: true, encoding: .utf8)

        let scriptPath = "\(dir)/installer.py"
        try RemoteAgentInstall.installerScript().write(
            toFile: scriptPath, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [scriptPath]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        p.environment = env
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0, "installer failed: \(out)")
        #expect(out.contains("hooks: claude"))

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: "\(home)/.conterm/agent-hook.sh"))
        #expect(fm.fileExists(atPath: "\(home)/.config/opencode/plugin/conterm-agent.js"))
        #expect(fm.fileExists(atPath: "\(home)/.pi/agent/extensions/conterm-agent.ts"))
        #expect(fm.fileExists(atPath: "\(home)/.omp/agent/extensions/conterm-agent.ts"))
        #expect(fm.fileExists(atPath: "\(home)/.claude/settings.json.conterm-backup"))

        let claude = try String(contentsOfFile: "\(home)/.claude/settings.json",
                                encoding: .utf8)
        #expect(claude.contains("echo mine"))          // user's hook kept
        #expect(claude.contains("# conterm"))          // ours merged in
        let antigravity = try String(
            contentsOfFile: "\(home)/.gemini/config/hooks.json", encoding: .utf8)
        #expect(antigravity.contains("\"conterm\""))
        #expect(antigravity.contains("PreInvocation"))
    }

    /// The Pi-family template carries the harness identity, the OSC
    /// prefix, and the remote-socket env hook; install/uninstall
    /// round-trips at the given path.
    @Test func piFamilyExtensionRoundTrip() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for identity in ["pi", "omp"] {
            let plugin = ExtensionIntegration.plugin(identity: identity)
            #expect(plugin.contains("conterm-agent:" + "\" + AGENT"))
            #expect(plugin.contains("CONTERM_AGENT_SOCK"))
            #expect(plugin.contains("tool_execution_start"))
            // `end` on process exit is delivered synchronously; an
            // async socket write in an exit handler never flushes.
            #expect(plugin.contains("sendSync(\"end\")"))
            #expect(plugin.contains("execFileSync"))

            let path = "\(dir)/\(identity)/conterm-agent.ts"
            ExtensionIntegration.install(identity: identity, at: path)
            #expect(ExtensionIntegration.isInstalled(at: path))
            let written = try String(contentsOfFile: path, encoding: .utf8)
            #expect(written.contains("const AGENT = \"\(identity)\""))
            ExtensionIntegration.uninstall(at: path)
            #expect(!ExtensionIntegration.isInstalled(at: path))
        }
    }
}
