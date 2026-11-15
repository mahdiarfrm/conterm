import Testing
import Foundation
@testable import Conterm

/// The pieces session restore leans on: the hook's per-pane agent record,
/// the restore handoff a shell and the app race to claim, and the write
/// that skips an unchanged snapshot.
@MainActor
struct SessionRestoreTests {

    // MARK: Agent record

    @Test func recordParsesAgentPidAndSession() {
        let r = AgentSessionRecord.parse("claude\n4242\n/Users/u/.claude/projects/-w/abc-123.jsonl\n")
        #expect(r?.agent == "claude")
        #expect(r?.pid == 4242)
        #expect(r?.sessionID == "abc-123")
    }

    @Test func recordWithoutPidOrTranscriptName() {
        let r = AgentSessionRecord.parse("claude\n\n/t/abc.jsonl\n")
        #expect(r?.pid == nil)
        #expect(r?.isAlive == true)
        #expect(AgentSessionRecord.parse("claude\n1\n/t/notes.txt\n")?.sessionID == nil)
        #expect(AgentSessionRecord.parse("claude\n") == nil)
        #expect(AgentSessionRecord.parse("") == nil)
    }

    @Test func recordAliveFollowsTheProcess() throws {
        let me = AgentSessionRecord(agent: "claude", pid: getpid(), transcriptPath: "/t/a.jsonl")
        #expect(me.isAlive)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        let gone = AgentSessionRecord(agent: "claude", pid: p.processIdentifier,
                                      transcriptPath: "/t/a.jsonl")
        #expect(!gone.isAlive)
    }

    /// Run the hook script with a scratch HOME and pane id; return the
    /// record it left, if any.
    private func runHook(_ event: String, _ json: String, home: URL,
                         pane: String) throws -> String? {
        let script = home.appendingPathComponent("hook.sh")
        try ClaudeIntegration.script.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, event, "claude"]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path,
                         "CONTERM_PANE_ID": pane,
                         "CONTERM_HOOK_TTY": home.appendingPathComponent("tty").path]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data(json.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let rec = home.appendingPathComponent(".conterm/agents/pane-\(pane)")
        return try? String(contentsOf: rec, encoding: .utf8)
    }

    @Test func hookWritesTheRecordAndSessionEndRemovesIt() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let pane = UUID().uuidString

        let start = #"{"session_id":"s1","transcript_path":"/p/-w/s1.jsonl","hook_event_name":"SessionStart","source":"startup"}"#
        let written = try #require(try runHook("SessionStart", start, home: home, pane: pane))
        let record = try #require(AgentSessionRecord.parse(written))
        #expect(record.agent == "claude")
        #expect(record.sessionID == "s1")
        // The hook's ancestors are this test's shell and process, which
        // are alive; the pid found must be one of them.
        #expect(record.isAlive)

        // A cleared conversation starts a new session in the same pane.
        let cleared = #"{"session_id":"s2","transcript_path":"/p/-w/s2.jsonl","hook_event_name":"SessionStart","source":"clear"}"#
        let rewritten = try #require(try runHook("SessionStart", cleared, home: home, pane: pane))
        #expect(AgentSessionRecord.parse(rewritten)?.sessionID == "s2")

        let end = #"{"session_id":"s2","hook_event_name":"SessionEnd"}"#
        #expect(try runHook("SessionEnd", end, home: home, pane: pane) == nil)
    }

    @Test func hookWithoutAPaneWritesNoRecord() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let start = #"{"session_id":"s1","transcript_path":"/p/-w/s1.jsonl"}"#
        _ = try runHook("SessionStart", start, home: home, pane: "")
        let agents = home.appendingPathComponent(".conterm/agents").path
        #expect(!FileManager.default.fileExists(atPath: agents))
    }

    // MARK: Restore handoff

    @Test func scrollbackHandoffIsTypedOnceWhenTheShellLeavesIt() throws {
        let h = try #require(RestoreHandoff.make(resumeSession: nil,
                                                  scrollback: "line 1\nline 2", cwd: nil))
        #expect(h.environment.0 == "CONTERM_RESTORE_SCROLLBACK")
        #expect(try String(contentsOfFile: h.path, encoding: .utf8) == "line 1\nline 2\n")
        let line = try #require(h.claimLine())
        #expect(line.hasPrefix("cat "))
        #expect(line.contains(".typed"))
        #expect(!FileManager.default.fileExists(atPath: h.path))
        #expect(h.claimLine() == nil)
        try? FileManager.default.removeItem(atPath: h.path + ".typed")
    }

    @Test func handoffTheShellTookIsNotTyped() throws {
        let h = try #require(RestoreHandoff.make(resumeSession: nil, scrollback: "x", cwd: nil))
        // What conterm-integration.zsh does: rename it to claim it.
        #expect(rename(h.path, h.path + ".zsh") == 0)
        defer { try? FileManager.default.removeItem(atPath: h.path + ".zsh") }
        #expect(h.claimLine() == nil)
    }

    @Test func resumeHandoffCarriesTheCommand() throws {
        let id = "no-such-session-\(UUID().uuidString)"
        let h = try #require(RestoreHandoff.make(resumeSession: id, scrollback: "ignored",
                                                  cwd: "/tmp/w"))
        #expect(h.environment.0 == "CONTERM_RESTORE_COMMAND")
        let line = try #require(h.claimLine())
        #expect(line == "cd '/tmp/w' && claude --resume '\(id)'")
        #expect(!FileManager.default.fileExists(atPath: h.path + ".typed"))
    }

    @Test func plainPaneHasNoHandoff() {
        #expect(RestoreHandoff.make(resumeSession: nil, scrollback: nil, cwd: "/tmp") == nil)
        #expect(RestoreHandoff.make(resumeSession: "", scrollback: "", cwd: "/tmp") == nil)
    }

    // MARK: Snapshot write

    @Test func unchangedSnapshotIsNotRewritten() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-sess-\(UUID().uuidString)")
        defer {
            SessionStore.pathOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let path = dir.appendingPathComponent("sessions.json").path
        SessionStore.pathOverride = path
        let snap = SessionStore.Snapshot(windows: [
            SessionStore.Window(frame: "{{0, 0}, {800, 600}}", tabs: [], selectedIndex: 0)
        ], stateHome: nil)

        SessionStore.write(snap)
        let first = try String(contentsOfFile: path, encoding: .utf8)
        #expect(first.contains("800"))
        // A stand-in edit: an identical snapshot leaves the file alone.
        try "edited".write(toFile: path, atomically: true, encoding: .utf8)
        SessionStore.write(snap)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "edited")
        // A missing file is written again even when nothing changed.
        try FileManager.default.removeItem(atPath: path)
        SessionStore.write(snap)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == first)
    }
}
