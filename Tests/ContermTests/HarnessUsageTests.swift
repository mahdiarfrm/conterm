import Foundation
import Testing
@testable import Conterm

/// Cost/token reporting for Muse and Antigravity: the hook script's
/// transcript resolution, the `muse trace` projection, the reported-
/// usage event, and the Antigravity status-line install. All IO is
/// staged in temp dirs; nothing touches the real harness configs.
@MainActor
struct HarnessUsageTests {

    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-usage-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run the shipped hook script with a staged HOME and capture
    /// what it writes to the pane's tty.
    private func runHook(agent: String, event: String, payload: String,
                         home: String) throws -> String {
        let script = "\(home)/agent-hook.sh"
        try AgentHooks.script.write(toFile: script, atomically: true, encoding: .utf8)
        let tty = "\(home)/tty"
        FileManager.default.createFile(atPath: tty, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script, event, agent]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["CONTERM_HOOK_TTY"] = tty
        env.removeValue(forKey: "CONTERM_PANE_ID")
        env.removeValue(forKey: "CONTERM_AGENT_SOCK")
        env.removeValue(forKey: "TMUX")
        p.environment = env
        let stdin = Pipe()
        p.standardInput = stdin
        try p.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return try String(contentsOfFile: tty, encoding: .utf8)
    }

    /// Muse's payload has `transcript_path: null` and a session id;
    /// the script must resolve the durable journal by that id.
    @Test func hookResolvesMuseJournalBySessionID() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let journalDir = "\(home)/.local/share/muse/sessions/2026/01/02/SID-9"
        try FileManager.default.createDirectory(
            atPath: journalDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(journalDir)/session.jsonl", contents: nil)
        let out = try runHook(
            agent: "muse", event: "SessionStart",
            payload: #"{"session_id":"SID-9","transcript_path":null}"#, home: home)
        #expect(out.contains("conterm-agent:muse:start:\(journalDir)/session.jsonl"))
    }

    /// Antigravity names it `transcriptPath`; it must reach the pane
    /// exactly like Claude's snake_case field does.
    @Test func hookResolvesAntigravityCamelCasePath() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let out = try runHook(
            agent: "antigravity", event: "SessionStart",
            payload: #"{"transcriptPath":"/agy/brain/c1/transcript.jsonl","conversationId":"c1"}"#,
            home: home)
        #expect(out.contains("conterm-agent:antigravity:start:/agy/brain/c1/transcript.jsonl"))
    }

    /// The trace projection: usage sums, reasoning folds into
    /// output, turns are run records, and none of it is priced.
    @Test func museTraceParsing() {
        let json = #"""
        {"summary": {"usage": {"input_tokens": 100, "output_tokens": 20,
          "cached_tokens": 40, "reasoning_tokens": 5}, "run_records": 3,
          "task_summaries": [{"latest_status_details": {"facets":
            [{"detail": {"model": "muse-wonder-1.0"}}]}}]}}
        """#
        let u = MuseUsageReader.parseTrace(Data(json.utf8))
        #expect(u?.inputTokens == 100)
        #expect(u?.outputTokens == 25)
        #expect(u?.cacheReadTokens == 40)
        #expect(u?.turns == 3)
        #expect(u?.model == "muse-wonder-1.0")
        #expect(u?.priced == false)
        #expect(u?.hasCost == false)
        #expect(u?.estCost == 0)
    }

    /// A harness-reported USD total wins over the rate table, and
    /// survives the base64 event form the reporter emits.
    @Test func reportedUsageEventDecodes() {
        let json = #"{"m":"Gemini 3.5 Flash","i":1200,"o":300,"cc":10,"cr":40,"usd":0.42}"#
        let b64 = Data(json.utf8).base64EncodedString()
        let u = ReportedUsage.decodeEvent(b64)
        #expect(u?.model == "Gemini 3.5 Flash")
        #expect(u?.totalTokens == 1510)
        #expect(u?.reportedCost == 0.42)
        #expect(u?.estCost == 0.42)
        #expect(u?.hasCost == true)
        #expect(ReportedUsage.decodeEvent("!!!") == nil)
    }

    /// Status-line install merges into the CLI settings without
    /// disturbing other keys; uninstall removes only our block.
    @Test func statusLineMergeKeepsUserSettings() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/settings.json"
        try #"{"model":"m","trustedWorkspaces":[]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        AntigravityIntegration.installStatusLine(at: path)
        var root = try #require(
            (try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any])
        #expect(root["model"] as? String == "m")
        let line = try #require(root["statusLine"] as? [String: Any])
        #expect((line["command"] as? String)?.contains("antigravity-statusline") == true)
        #expect(FileManager.default.fileExists(atPath: path + ".conterm-backup"))

        AntigravityIntegration.uninstallStatusLine(at: path)
        root = try #require(
            (try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any])
        #expect(root["statusLine"] == nil)
        #expect(root["model"] as? String == "m")
    }

    /// A status line the user chose themselves is never replaced.
    @Test func statusLineNeverClobbersUsersOwn() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/settings.json"
        let original = #"{"statusLine":{"type":"command","command":"my-own.sh"}}"#
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        AntigravityIntegration.installStatusLine(at: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
    }

    /// The reporter itself: a status-line payload in, a printed
    /// line out, and a per-pane usage file Conterm can read back.
    @Test func statusLineReporterWritesUsageFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = "\(dir)/reporter.py"
        try AntigravityIntegration.statusScript.write(
            toFile: script, atomically: true, encoding: .utf8)
        let payload = #"{"model":{"id":"gemini","display_name":"Gemini 3.5 Flash"},"conversation_id":"c1","context_window":{"total_input_tokens":1200,"total_output_tokens":300,"current_usage":{"cache_creation_input_tokens":10,"cache_read_input_tokens":40}},"cost":{"total_usd":0.42}}"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir
        env["CONTERM_PANE_ID"] = "PANE-7"
        env.removeValue(forKey: "CONTERM_AGENT_SOCK")
        env.removeValue(forKey: "TMUX")
        p.environment = env
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try p.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let printed = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        #expect(printed.contains("Gemini 3.5 Flash"))
        #expect(printed.contains("$0.42"))

        let file = "\(dir)/.conterm/usage/pane-PANE-7.json"
        let obj = try #require(
            (try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: file)))) as? [String: Any])
        #expect(obj["i"] as? Int == 1200)
        #expect(obj["o"] as? Int == 300)
        #expect(obj["usd"] as? Double == 0.42)
        #expect(ReportedUsage.agentUsage(from: obj)?.estCost == 0.42)
    }
}
