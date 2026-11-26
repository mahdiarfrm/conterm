import Combine
import Foundation
import os
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

    @Test func codexWindowsOnTheSameSideKeepTheirOwnSlots() throws {
        for (a, b) in [(60, 300), (1440, 10080)] {
            let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5,"window_minutes":\#(a)},"secondary":{"used_percent":9,"window_minutes":\#(b)}}}}"#
            let l = try #require(UsageLimitsModel.parseCodexRollout(line))
            #expect(l.fiveHour?.usedPercent == 5)
            #expect(l.weekly?.usedPercent == 9)
        }
        // Swapped but unambiguous: minutes still win.
        let swapped = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5,"window_minutes":10080},"secondary":{"used_percent":9,"window_minutes":300}}}}"#
        let l = try #require(UsageLimitsModel.parseCodexRollout(swapped))
        #expect(l.fiveHour?.usedPercent == 9)
        #expect(l.weekly?.usedPercent == 5)
    }

    /// Write a rollout whose newest reading is `used` at `at`, or with no
    /// reading, last touched at `mtime`.
    private func rollout(_ path: String, used: Int? = nil, at: String = "", mtime: String) throws {
        let limits = used.map { #"{"primary":{"used_percent":\#($0),"window_minutes":300}}"# } ?? "null"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","rate_limits":\#(limits)}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let date = try #require(UsageLimitsModel.parseISODate(mtime))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func withCodexHome(_ body: (String, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home.path, home.appendingPathComponent("sessions"))
    }

    @Test func newestCodexReadingWinsAcrossSessionsAndDisk() throws {
        try withCodexHome { home, root in
            let idle = "\(home)/idle.jsonl", active = "\(home)/active.jsonl"
            let disk = "\(root.path)/2026/10/14/rollout-a.jsonl"
            func used(_ live: [String]) -> Double? {
                var cache = UsageLimitsModel.RolloutCache()
                return UsageLimitsModel.readCodex(live, root: root, cache: &cache)?.fiveHour?.usedPercent
            }
            // The idle file was touched last; its reading is still the older.
            try rollout(idle, used: 20, at: "2026-10-14T10:00:00Z", mtime: "2026-10-14T12:30:00Z")
            try rollout(active, used: 55, at: "2026-10-14T12:00:00Z", mtime: "2026-10-14T12:00:00Z")
            try rollout(disk, used: 30, at: "2026-10-14T11:00:00Z", mtime: "2026-10-14T13:00:00Z")
            #expect(used([idle, active]) == 55)
            #expect(used([active, idle]) == 55)
            #expect(used([]) == 30)
            // A reading on disk newer than every live one.
            try rollout(disk, used: 60, at: "2026-10-14T12:45:00Z", mtime: "2026-10-14T12:45:00Z")
            #expect(used([idle, active]) == 60)
        }
    }

    @Test func codexRolloutsAreReadAgainOnlyWhenTheirMtimeMoves() throws {
        try withCodexHome { _, root in
            let path = "\(root.path)/2026/10/14/rollout-a.jsonl"
            var cache = UsageLimitsModel.RolloutCache()
            try rollout(path, mtime: "2026-10-14T10:00:00Z")
            #expect(UsageLimitsModel.readCodex([], root: root, cache: &cache) == nil)
            // Same mtime: the no-reading result stands, the file isn't opened.
            try rollout(path, used: 7, at: "2026-10-14T10:00:00Z", mtime: "2026-10-14T10:00:00Z")
            #expect(UsageLimitsModel.readCodex([], root: root, cache: &cache) == nil)
            try rollout(path, used: 7, at: "2026-10-14T10:01:00Z", mtime: "2026-10-14T10:01:00Z")
            #expect(UsageLimitsModel.readCodex([], root: root, cache: &cache)?.fiveHour?.usedPercent == 7)
            // A rollout that's gone leaves the cache.
            try FileManager.default.removeItem(atPath: path)
            #expect(UsageLimitsModel.readCodex([], root: root, cache: &cache) == nil)
            #expect(cache.isEmpty)
        }
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

    private func command(_ home: String) throws -> String {
        try #require((try settings(home)["statusLine"] as? [String: Any])?["command"] as? String)
    }

    /// Replace the installed command, as a hand edit would.
    private func setCommand(_ cmd: String, _ home: String) throws {
        var s = try settings(home)
        s["statusLine"] = ["type": "command", "command": cmd]
        try JSONSerialization.data(withJSONObject: s)
            .write(to: URL(fileURLWithPath: "\(home)/.claude/settings.json"))
    }

    /// Run the installed status line command the way Claude Code does; it
    /// must stay quiet on stderr.
    private func runStatusLine(_ home: String, input: String, path: String? = nil,
                               status: Int32 = 0) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", try command(home)]
        if let path { p.environment = ["PATH": path] }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == status)
        #expect(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty)
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
            // Script gone and nothing to fall back to: still blank, exit 0.
            try FileManager.default.removeItem(atPath: ClaudeUsageTap.scriptPath(home: home))
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

    @Test func originalGetsItsLastLine() throws {
        // `in=$(cat)` drops the trailing newline; a `read` loop still needs it.
        let original = #"{"statusLine":{"type":"command","command":"while read -r l; do echo \"got $l\"; done"}}"#
        try withHome(original) { home in
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            let out = try runStatusLine(home, input: "a\nlast")
            #expect(out == "got a\ngot last\n")
        }
    }

    @Test func missingScriptFallsBackToTheOriginal() throws {
        // settings.json synced to a Mac without Conterm: no ~/.conterm.
        let original = #"{"statusLine":{"type":"command","command":"cat; echo \" $0\""}}"#
        try withHome(original) { home in
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            try FileManager.default.removeItem(atPath: ClaudeUsageTap.dir(home: home))
            #expect(try runStatusLine(home, input: "a\nlast") == "a\nlast sh\n")
        }
    }

    @Test func fallbackDecodesWithGNUOrBSDBase64() throws {
        // settings.json synced to Linux: GNU base64 takes only -d; an old
        // macOS takes only -D. Neither path may need plutil.
        for flag in ["-d", "-D"] {
            try withHome(#"{"statusLine":{"type":"command","command":"cat; echo ok"}}"#) { home in
                #expect(ClaudeUsageTap.install(home: home) == .ok)
                let cmd = try command(home)
                #expect(!cmd.contains("plutil"))
                try FileManager.default.removeItem(atPath: ClaudeUsageTap.dir(home: home))
                let bin = "\(home)/bin"
                try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
                let shim = "#!/bin/sh\n[ \"$1\" = \(flag) ] || { echo bad flag >&2; exit 1; }\nexec /usr/bin/base64 -D\n"
                try shim.write(toFile: "\(bin)/base64", atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(bin)/base64")
                #expect(try runStatusLine(home, input: "in ", path: "\(bin):/bin") == "in ok\n")
            }
        }
    }

    @Test func launchRewritesTheScriptAndKeepsTheCommand() throws {
        try withHome(#"{"statusLine":{"type":"command","command":"echo hi"}}"#) { home in
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            let installed = try command(home)
            try "stale".write(toFile: ClaudeUsageTap.scriptPath(home: home), atomically: true, encoding: .utf8)
            ClaudeUsageTap.refreshIfInstalled(home: home)
            let script = try String(contentsOfFile: ClaudeUsageTap.scriptPath(home: home), encoding: .utf8)
            #expect(script == ClaudeUsageTap.script)
            // Installing over an install doesn't wrap the wrapper.
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            #expect(try command(home) == installed)
        }
    }

    @Test func aHandEditedCommandIsLeftInPlace() throws {
        for edited in ["sh \"$HOME/.conterm/claude-statusline.sh\" %%% # conterm", "echo test # conterm"] {
            try withHome("{}") { home in
                try setCommand(edited, home)
                ClaudeUsageTap.refreshIfInstalled(home: home)
                #expect(ClaudeUsageTap.uninstall(home: home) == .unrecognizedCommand)
                #expect(try command(home) == edited)
                // What the kept command may run stays too.
                #expect(FileManager.default.fileExists(atPath: ClaudeUsageTap.scriptPath(home: home)))
            }
        }
    }

    @Test func theOriginalsExitStatusComesThrough() throws {
        try withHome(#"{"statusLine":{"type":"command","command":"exit 3"}}"#) { home in
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            let out = try runStatusLine(home, input: "{}", status: 3)
            #expect(out == "")
        }
    }

    @Test func aNullPercentageKeepsTheLastReading() throws {
        try withHome("{}") { home in
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            _ = try runStatusLine(home, input: #"{"rate_limits":{"five_hour":{"used_percentage":23}}}"#)
            for bad in ["null", #""31""#] {
                _ = try runStatusLine(home, input: #"{"rate_limits":{"five_hour":{"used_percentage":\#(bad),"resets_at":1}}}"#)
                #expect(ClaudeUsageTap.read(home: home)?.fiveHour?.usedPercent == 23)
            }
        }
    }

    @Test func aHomePathWithShellCharactersWorks() throws {
        try withHome(nil) { base in
            let home = "\(base)/a $x \"b\" 'c' `d`"
            try FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
            try #"{"statusLine":{"type":"command","command":"echo hi"}}"#
                .write(toFile: "\(home)/.claude/settings.json", atomically: true, encoding: .utf8)
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            #expect(try runStatusLine(home, input: #"{"rate_limits":{"five_hour":{"used_percentage":7}}}"#) == "hi\n")
            #expect(ClaudeUsageTap.read(home: home)?.fiveHour?.usedPercent == 7)
            #expect(ClaudeUsageTap.uninstall(home: home) == .ok)
            #expect(try command(home) == "echo hi")
        }
    }

    @Test func aLateWriteAfterUninstallIsNotRead() throws {
        try withHome("{}") { home in
            #expect(ClaudeUsageTap.install(home: home) == .ok)
            #expect(ClaudeUsageTap.uninstall(home: home) == .ok)
            try #"{"used_percentage":9}"#.write(toFile: ClaudeUsageTap.dataPath("five_hour", home: home),
                                                atomically: true, encoding: .utf8)
            #expect(ClaudeUsageTap.read(home: home) == nil)
        }
    }
}

/// The model follows the open sessions itself: the pill has no view mounted
/// to notice the first one.
@MainActor
struct UsageLimitsModelTests {
    @Test func firstSessionRefreshesWithoutAView() async throws {
        let tools = CurrentValueSubject<Set<AgentTool>, Never>([])
        let model = UsageLimitsModel(openTools: tools.eraseToAnyPublisher(), isEnabled: { true }) { _, _ in
            .init(limits: UsageLimits(fiveHour: UsageWindow(usedPercent: 12)), tapInstalled: true)
        }
        tools.send([.claude])
        for _ in 0..<100 where model.limits[.claude] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.openTools == [.claude])
        #expect(model.limits[.claude]?.fiveHour?.usedPercent == 12)
        #expect(model.claudeTapInstalled)
    }

    @Test func turningTheTapOffClearsTheClaudeReading() async throws {
        let tools = CurrentValueSubject<Set<AgentTool>, Never>([])
        let on = OSAllocatedUnfairLock(initialState: true)
        let model = UsageLimitsModel(openTools: tools.eraseToAnyPublisher(), isEnabled: { true }) { _, _ in
            on.withLock { $0 }
                ? .init(limits: UsageLimits(fiveHour: UsageWindow(usedPercent: 12)), tapInstalled: true)
                : .init(limits: nil, tapInstalled: false)
        }
        tools.send([.claude])
        for _ in 0..<100 where model.limits[.claude] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.limits[.claude] != nil)
        on.withLock { $0 = false }
        for _ in 0..<100 where model.claudeTapInstalled {
            model.refresh()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.claudeTapInstalled)
        #expect(model.limits[.claude] == nil)
        #expect(model.updatedAt[.claude] == nil)
    }
}
