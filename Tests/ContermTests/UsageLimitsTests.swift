import Foundation
import Testing
@testable import Conterm

/// The two usage-limit sources: the `rate_limits` windows Claude Code hands
/// its status line (saved by `ClaudeUsageTap`), and the `token_count` events
/// Codex writes into its session rollout. Plus the tap's install/uninstall
/// round trip, the one path that rewrites the user's Claude config.
struct UsageLimitsTests {

    @Test func claudeStatusLineWindowParse() throws {
        // What ClaudeUsageTap saves per window from `rate_limits`.
        let w = try #require(ClaudeUsageTap.parseWindow(
            Data(#"{"used_percentage":23.5,"resets_at":1738425600}"#.utf8)))
        #expect(w.usedPercent == 23.5)
        #expect(w.resetsAt == Date(timeIntervalSince1970: 1_738_425_600))
        #expect(try #require(ClaudeUsageTap.parseWindow(Data(#"{"used_percentage":5}"#.utf8))).resetsAt == nil)
        #expect(ClaudeUsageTap.parseWindow(Data("{}".utf8)) == nil)
        #expect(ClaudeUsageTap.parseWindow(Data("not json".utf8)) == nil)
    }

    @Test func codexRolloutTakesTheNewestTokenCount() throws {
        // Shape from codex-rs protocol.rs: TokenCountEvent { info, rate_limits }.
        let text = [
            #"{"timestamp":"2026-10-14T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1791990000},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":1792216800}}}}"#,
            #"{"timestamp":"2026-10-14T10:05:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
            #"{"timestamp":"2026-10-14T10:06:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1791990000},"secondary":{"used_percent":41.0,"window_minutes":10080,"resets_at":1792216800},"credits":null}}}"#,
            #"{"timestamp":"2026-10-14T10:07:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":null}}"#,
            "{truncated partial line",
        ].joined(separator: "\n")
        let l = try #require(UsageLimitsModel.parseCodexRollout(text))
        #expect(l.fiveHour?.usedPercent == 12.5)
        #expect(l.weekly?.usedPercent == 41)
        #expect(l.weekly?.resetsAt == Date(timeIntervalSince1970: 1_792_216_800))
        // The reading is dated by its event, not by when we read it.
        #expect(l.observedAt == UsageLimitsModel.parseISODate("2026-10-14T10:06:00.000Z"))
    }

    @Test func codexWindowMinutesDecideTheSlot() throws {
        // A weekly-only snapshot reported as primary still lands in `weekly`.
        let line = #"{"timestamp":"2026-10-14T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5,"window_minutes":10080,"resets_in_seconds":60}}}}"#
        let l = try #require(UsageLimitsModel.parseCodexRollout(line))
        #expect(l.fiveHour == nil)
        #expect(l.weekly?.usedPercent == 5)
        #expect(l.weekly?.resetsAt == UsageLimitsModel.parseISODate("2026-10-14T10:01:00Z"))
    }

    @Test func passedResetReadsAsFresh() {
        let w = UsageWindow(usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 100))
        #expect(w.used(at: Date(timeIntervalSince1970: 50)) == 80)
        #expect(w.used(at: Date(timeIntervalSince1970: 100)) == 0)
    }
}

/// Install/uninstall against a throwaway home: settings.json survives the
/// round trip, and the installed command runs the user's original.
@MainActor
@Suite(.serialized) struct ClaudeUsageTapInstallTests {
    private func withHome(_ settings: String?, _ body: (String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-tap-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(home)/.claude",
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        if let settings {
            try settings.write(toFile: "\(home)/.claude/settings.json", atomically: true, encoding: .utf8)
        }
        try body(home)
    }

    private func settings(_ home: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude/settings.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Run the installed status line command the way Claude Code does.
    private func runStatusLine(_ home: String, input: String) throws -> String {
        let cmd = try #require((try settings(home)["statusLine"] as? [String: Any])?["command"] as? String)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func roundTripWithAnOriginalStatusLine() throws {
        let original = #"{"model":"opus","statusLine":{"type":"command","command":"echo \"hi $0\"","padding":2},"permissions":{"allow":["Bash(ls)"]}}"#
        try withHome(original) { home in
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            #expect(ClaudeUsageTap.isInstalled(home: home))
            let s = try settings(home)
            let line = try #require(s["statusLine"] as? [String: Any])
            #expect(line["padding"] as? Int == 2)
            #expect(s["model"] as? String == "opus")
            #expect(s["permissions"] != nil)

            // The tap saves each window and still prints the original's output.
            let out = try runStatusLine(home, input: #"{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41,"resets_at":1738857600}}}"#)
            #expect(out == "hi sh\n")
            let read = try #require(ClaudeUsageTap.read(home: home))
            #expect(read.fiveHour?.usedPercent == 23.5)
            #expect(read.weekly?.usedPercent == 41)

            // A window Claude Code drops after a reset keeps its last reading.
            _ = try runStatusLine(home, input: #"{"rate_limits":{"seven_day":{"used_percentage":42}}}"#)
            let after = try #require(ClaudeUsageTap.read(home: home))
            #expect(after.fiveHour?.usedPercent == 23.5)
            #expect(after.weekly?.usedPercent == 42)

            // ~/.conterm lost (cleaned, or settings.json synced to another
            // Mac): settings.json alone still restores the original.
            try FileManager.default.removeItem(atPath: ClaudeUsageTap.dir(home: home))
            #expect(ClaudeUsageTap.uninstall(home: home) == .ok)
            let restored = try settings(home)
            let back = try #require(restored["statusLine"] as? [String: Any])
            #expect(back["command"] as? String == #"echo "hi $0""#)
            #expect(back["padding"] as? Int == 2)
            #expect(restored["model"] as? String == "opus")
            #expect(!ClaudeUsageTap.isInstalled(home: home))
        }
    }

    @Test func roundTripWithoutAStatusLine() throws {
        try withHome(#"{"model":"opus"}"#) { home in
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            #expect(try runStatusLine(home, input: "{}") == "")
            #expect(ClaudeUsageTap.uninstall(home: home) == .ok)
            let s = try settings(home)
            #expect(s["statusLine"] == nil)
            #expect(s["model"] as? String == "opus")
            #expect(!FileManager.default.fileExists(atPath: ClaudeUsageTap.scriptPath(home: home)))
        }
    }

    @Test func unreadableSettingsAreLeftUntouched() throws {
        let broken = #"{"model":"opus","permissions":{"allow"#   // read mid-write
        try withHome(broken) { home in
            #expect(ClaudeUsageTap.install(home: home) == .unreadableSettings)
            let after = try String(contentsOfFile: "\(home)/.claude/settings.json", encoding: .utf8)
            #expect(after == broken)
            #expect(ClaudeUsageTap.uninstall(home: home) == .unreadableSettings)
        }
    }

    @Test func missingOriginalIsNotDropped() throws {
        // An earlier build's install: no original in the command, and its
        // saved copy in ~/.conterm is gone.
        let legacy = #"{"statusLine":{"type":"command","command":"sh \"$HOME/.conterm/claude-statusline.sh\" # conterm"}}"#
        try withHome(legacy) { home in
            #expect(ClaudeUsageTap.uninstall(home: home) == .originalMissing)
            #expect(ClaudeUsageTap.isInstalled(home: home))
        }
    }
}
