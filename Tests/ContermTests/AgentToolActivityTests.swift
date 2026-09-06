import Foundation
import Testing
@testable import Conterm

/// Tool-call classification, the hook's wire format, and the pane's run
/// list — the pieces between a Claude hook firing and a bubble appearing.
@MainActor
struct AgentToolActivityTests {

    // MARK: Classification

    @Test func bashCommandsMapToTheirFamily() {
        let cases: [(String, AgentToolKind?)] = [
            ("terraform plan", .terraform),
            ("cd infra && terraform apply -auto-approve", .terraform),
            ("tofu init", .terraform),
            ("ansible-playbook site.yml -i hosts", .ansible),
            ("sudo -E kubectl get pods -A", .kubernetes),
            ("KUBECONFIG=/tmp/k kubectl apply -f x.yaml", .kubernetes),
            ("/usr/local/bin/helm upgrade --install app ./chart", .helm),
            ("docker compose up -d", .docker),
            ("podman ps", .docker),
            ("ssh prod-1 'kubectl get pods'", .ssh),
            ("scp ./a.txt host:/tmp/", .ssh),
            ("git status --short", .git),
            ("gh pr create --fill", .github),
            ("ls -la && git diff | head", .git),
            ("echo \"terraform plan\" > notes.txt", nil),
            ("ls -la", nil),
            ("cat ansible/hosts", nil),
            ("swift build 2>&1 | tail -20", nil),
        ]
        for (command, expected) in cases {
            #expect(AgentToolKind.classify(command: command) == expected, "\(command)")
            // Through the tool: plain shell is still an action.
            #expect(AgentToolKind.classify(toolName: "Bash", command: command) == (expected ?? .shell),
                    "\(command)")
        }
    }

    @Test func everyActionToolHasAKind() {
        let cases: [(String, AgentToolKind?)] = [
            ("Read", .read), ("LS", .read), ("Edit", .edit), ("Write", .edit),
            ("MultiEdit", .edit), ("Grep", .search), ("Glob", .search),
            ("WebSearch", .webSearch), ("WebFetch", .webFetch), ("Task", .agent),
            ("TodoWrite", .todo), ("Skill", .skill), ("BashOutput", .shell),
            ("mcp__kubernetes__list_pods", .kubernetes),
            ("mcp__github__create_pull_request", .github),
            ("mcp__docker-mcp__run", .docker),
            ("mcp__notion__search", .mcp),
            ("AskUserQuestion", nil), ("ExitPlanMode", nil),
        ]
        for (tool, expected) in cases {
            #expect(AgentToolKind.classify(toolName: tool, command: nil) == expected, "\(tool)")
        }
        // A file tool's input never makes it infrastructure.
        #expect(AgentToolKind.classify(toolName: "Edit", command: "kubectl") == .edit)
    }

    // MARK: Wire format

    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    @Test func startEventDecodesTheEscapedExcerpt() {
        // The hook forwards the command as the JSON text it saw, escapes and all.
        let payload = "start:toolu_01A:Bash:" + b64(#"terraform plan -var \"env=prod\" \\\n  -out=x"#)
        let event = AgentToolEvent.parse(payload)
        #expect(event == .start(id: "toolu_01A", toolName: "Bash",
                                command: "terraform plan -var \"env=prod\" \\\n  -out=x"))
    }

    @Test func startEventWithoutCommandCarriesTheToolName() {
        #expect(AgentToolEvent.parse("start:toolu_01B:mcp__kubernetes__list_pods:")
                == .start(id: "toolu_01B", toolName: "mcp__kubernetes__list_pods", command: nil))
    }

    @Test func excerptCutInsideAnEscapeStillDecodes() {
        // Cut after the backslash of an escape: the half-escape is dropped.
        #expect(AgentToolEvent.decodeExcerpt(b64(#"kubectl get pods \"#)) == "kubectl get pods ")
        #expect(AgentToolEvent.decodeExcerpt(b64(#"echo \u00"#)) == "echo ")
    }

    @Test func endEventCarriesTheVerdict() {
        #expect(AgentToolEvent.parse("end:toolu_01C:ok") == .end(id: "toolu_01C", failed: false))
        #expect(AgentToolEvent.parse("end:toolu_01C:fail") == .end(id: "toolu_01C", failed: true))
        #expect(AgentToolEvent.parse("end:") == nil)
        #expect(AgentToolEvent.parse("bogus:x:y") == nil)
    }

    // MARK: Pane run list

    @Test func paneKeepsActionsAndDropsTheRest() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.applyToolEvent(.start(id: "t1", toolName: "Bash", command: "kubectl get pods"))
        pane.applyToolEvent(.start(id: "t2", toolName: "Read", command: "/a/b.swift"))
        pane.applyToolEvent(.start(id: "t3", toolName: "AskUserQuestion", command: nil))
        pane.applyToolEvent(.start(id: "t4", toolName: "mcp__notion__search", command: "q"))
        #expect(pane.toolRuns.map(\.id) == ["t1", "t2", "t4"])
        #expect(pane.toolRuns[0].kind == .kubernetes)
        #expect(pane.toolRuns[1].kind == .read)
        #expect(pane.toolRuns[1].command == "/a/b.swift")
        #expect(pane.toolRuns[2].command == "mcp__notion__search q")
        #expect(pane.toolRuns[0].isRunning)
        #expect(pane.toolRuns[0].command == "kubectl get pods")

        pane.applyToolEvent(.end(id: "t1", failed: true))
        #expect(!pane.toolRuns[0].isRunning)
        #expect(pane.toolRuns[0].failed)
        // A repeat start for a known id is a streaming re-log, not a new call.
        pane.applyToolEvent(.start(id: "t1", toolName: "Bash", command: "kubectl get pods"))
        #expect(pane.toolRuns.count == 3)
    }

    @Test func transcriptFillsCommandOutputAndVerdict() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.applyToolEvent(.start(id: "t1", toolName: "Bash", command: "terraform plan -v"))
        pane.applyToolEvent(.end(id: "t1", failed: false))
        let end = Date()
        pane.applyToolRecords(["t1": ToolRecord(seq: 1, name: "Bash", input: "terraform plan -var x=1",
                                                at: Date(), endedAt: end, isError: true,
                                                output: "Error: boom")])
        let run = pane.toolRuns[0]
        #expect(run.command == "terraform plan -var x=1")
        #expect(run.output == "Error: boom")
        #expect(run.failed)
        #expect(run.resultSeen)
        #expect(!run.wantsTranscript)
    }

    @Test func turnEndSettlesOpenRunsAndSessionEndClearsThem() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.applyToolEvent(.start(id: "t1", toolName: "Bash", command: "docker ps"))
        pane.agent = AgentStatus(phase: .ready, tool: .claude)
        #expect(pane.toolRuns.count == 1)
        #expect(!pane.toolRuns[0].isRunning)
        pane.agent = AgentStatus(phase: .idle, tool: .claude)
        #expect(pane.toolRuns.isEmpty)
    }

    @Test func attentionTimeoutLeavesAPendingCallOpen() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.applyToolEvent(.start(id: "t1", toolName: "Bash", command: "terraform apply"))
        pane.agent = AgentStatus(phase: .attention, tool: .claude)
        pane.agent = AgentStatus(phase: .ready, tool: .claude)
        #expect(pane.toolRuns[0].isRunning)
    }

    // MARK: Transcript feed

    private func record(_ seq: Int, _ name: String, _ input: String?, at: Date,
                        endedAt: Date? = nil, isError: Bool? = nil,
                        output: String? = nil) -> ToolRecord {
        ToolRecord(seq: seq, name: name, input: input, at: at,
                   endedAt: endedAt, isError: isError, output: output)
    }

    @Test func feedDiscoversCallsTheHookNeverReported() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        let now = Date()
        let feed = AgentTranscriptStore.ToolFeed(
            path: "/t.jsonl", cursor: 4,
            new: [("t1", record(1, "Bash", "kubectl get pods", at: now,
                                endedAt: now.addingTimeInterval(1), isError: false, output: "ok")),
                  ("t2", record(2, "Read", "/a/b.swift", at: now)),
                  ("t3", record(3, "Bash", "docker compose up -d", at: now)),
                  ("t4", record(4, "mcp__github__list_prs", "{\"state\":\"open\"}", at: now))],
            known: [:])
        pane.applyToolFeed(feed)
        #expect(pane.toolRuns.map(\.id) == ["t1", "t2", "t3", "t4"])
        #expect(pane.toolRuns[0].kind == .kubernetes)
        #expect(!pane.toolRuns[0].isRunning)
        #expect(pane.toolRuns[0].output == "ok")
        #expect(pane.toolRuns[1].kind == .read)
        #expect(pane.toolRuns[2].kind == .docker)
        #expect(pane.toolRuns[2].isRunning)
        #expect(pane.toolRuns[3].kind == .github)
        #expect(pane.toolRuns[3].command == "mcp__github__list_prs {\"state\":\"open\"}")
        #expect(pane.toolFeedPath == "/t.jsonl")
        #expect(pane.toolFeedCursor == 4)
    }

    @Test func feedSkipsCallsFromBeforeTheAgentAppearedHere() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        let old = Date().addingTimeInterval(-3600)
        let feed = AgentTranscriptStore.ToolFeed(
            path: "/t.jsonl", cursor: 2,
            new: [("old", record(1, "Bash", "terraform apply", at: old)),
                  ("fresh", record(2, "Bash", "terraform plan", at: Date()))],
            known: [:])
        pane.applyToolFeed(feed)
        #expect(pane.toolRuns.map(\.id) == ["fresh"])
    }

    @Test func feedUpdatesARunTheHookStarted() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.applyToolEvent(.start(id: "t1", toolName: "Bash", command: "helm ls"))
        let now = Date()
        let feed = AgentTranscriptStore.ToolFeed(
            path: "/t.jsonl", cursor: 1,
            new: [("t1", record(1, "Bash", "helm ls -A", at: now))],
            known: ["t1": record(1, "Bash", "helm ls -A", at: now,
                                 endedAt: now.addingTimeInterval(2), isError: false,
                                 output: "NAME  NAMESPACE")])
        pane.applyToolFeed(feed)
        #expect(pane.toolRuns.count == 1)
        #expect(pane.toolRuns[0].command == "helm ls -A")
        #expect(pane.toolRuns[0].output == "NAME  NAMESPACE")
        #expect(!pane.toolRuns[0].isRunning)
    }

    @Test func storeFeedPagesByCursorAndStartsOverOnANewFile() throws {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("conterm-feed-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let use = { (id: String, cmd: String) in
            "{\"type\":\"assistant\",\"timestamp\":\"2026-09-06T20:00:00.000Z\",\"message\":{\"id\":\"m-\(id)\",\"content\":[{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"Bash\",\"input\":{\"command\":\"\(cmd)\"}}]}}\n"
        }
        let result = { (id: String, out: String, err: Bool) in
            "{\"type\":\"user\",\"timestamp\":\"2026-09-06T20:00:01.000Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\",\"is_error\":\(err),\"content\":\"\(out)\"}]}}\n"
        }
        try (use("a", "kubectl get ns") + use("b", "ls")).write(toFile: path, atomically: true, encoding: .utf8)
        let store = AgentTranscriptStore()

        let first = store.toolFeed(after: 0, from: nil, ids: [], forCwd: nil, transcriptPath: path)
        #expect(first?.new.map(\.id) == ["a", "b"])
        #expect(first?.cursor == 2)

        let fh = FileHandle(forWritingAtPath: path)!
        _ = try fh.seekToEnd()
        try fh.write(contentsOf: Data((result("a", "default", false) + use("c", "docker ps")).utf8))
        try fh.close()

        let second = store.toolFeed(after: 2, from: path, ids: ["a"], forCwd: nil, transcriptPath: path)
        #expect(second?.new.map(\.id) == ["c"])
        #expect(second?.known["a"]?.output == "default")
        #expect(second?.known["a"]?.isError == false)
        #expect(second?.cursor == 3)

        // A cursor from another file means nothing here.
        let other = store.toolFeed(after: 2, from: "/elsewhere.jsonl", ids: [], forCwd: nil, transcriptPath: path)
        #expect(other?.new.map(\.id) == ["a", "b", "c"])
    }

    @Test func codexToolNamesClassifyLikeClaudes() {
        #expect(AgentToolKind.classify(toolName: "shell", command: "kubectl get pods") == .kubernetes)
        #expect(AgentToolKind.classify(toolName: "shell", command: "ls") == .shell)
        #expect(AgentToolKind.classify(toolName: "apply_patch", command: nil) == .edit)
        #expect(AgentToolKind.classify(toolName: "web_search", command: nil) == .webSearch)
        #expect(AgentToolKind.classify(toolName: "update_plan", command: nil) == .todo)
        #expect(AgentToolKind.classify(toolName: "spawn_agent", command: nil) == .agent)
    }

    @Test func storeReadsCodexRollouts() throws {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("rollout-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = [
            #"{"timestamp":"2026-09-07T00:10:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/w"}}"#,
            #"{"timestamp":"2026-09-07T00:10:01.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"docker compose up -d\"]}","call_id":"call_a"}}"#,
            #"{"timestamp":"2026-09-07T00:10:02.000Z","type":"response_item","payload":{"type":"local_shell_call","call_id":"call_b","status":"completed","action":{"type":"exec","command":["kubectl","get","pods"]}}}"#,
            #"{"timestamp":"2026-09-07T00:10:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_c","input":"*** Begin Patch\n*** Update File: src/App.swift\n@@\n-a\n+b\n*** End Patch"}}"#,
            #"{"timestamp":"2026-09-07T00:10:04.000Z","type":"response_item","payload":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"terraform show json"}}}"#,
            #"{"timestamp":"2026-09-07T00:10:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_a","output":"{\"output\":\"ERROR: boom\",\"metadata\":{\"exit_code\":1,\"duration_seconds\":0.3}}"}}"#,
            #"{"timestamp":"2026-09-07T00:10:06.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_b","output":[{"type":"input_text","text":"NAME READY"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let store = AgentTranscriptStore()
        let feed = try #require(store.toolFeed(after: 0, from: nil, ids: [], forCwd: nil,
                                               transcriptPath: path, claudeFallback: false))
        #expect(feed.new.map(\.id) == ["call_a", "call_b", "call_c", "ws_1"])
        let a = feed.new[0].record
        #expect(a.name == "shell")
        #expect(a.input == "docker compose up -d")
        #expect(a.isError == true)
        #expect(a.output?.contains("ERROR: boom") == true)
        let b = feed.new[1].record
        #expect(b.input == "kubectl get pods")
        #expect(b.isError == false)
        #expect(b.output == "NAME READY")
        #expect(feed.new[2].record.input == "src/App.swift")
        #expect(feed.new[2].record.endedAt == nil)
        let ws = feed.new[3].record
        #expect(ws.name == "web_search")
        #expect(ws.input == "terraform show json")
        #expect(ws.endedAt != nil)
        // No Claude project-dir guessing for a Codex pane without a path.
        #expect(store.toolFeed(after: 0, from: nil, ids: [], forCwd: "/w",
                               transcriptPath: nil, claudeFallback: false) == nil)
    }

    @Test func hookSpeaksForCodexToo() throws {
        let json = #"{"session_id":"s","transcript_path":"/r.jsonl","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"turn_id":"t1"}"#
        #expect(try runHook("PermissionRequest", json, agent: "codex") == ["attention:/r.jsonl"])
        let pre = #"{"transcript_path":"/r.jsonl","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"file_path":"src/App.swift"},"tool_use_id":"call_9","turn_id":"t1"}"#
        let emitted = try runHook("PreToolUse", pre, agent: "codex")
        #expect(emitted.count == 1)
        #expect(AgentToolEvent.parse(String((emitted.first ?? "").dropFirst(5)))
                == .start(id: "call_9", toolName: "apply_patch", command: "src/App.swift"))
    }

    // MARK: Hook script

    /// Run the installed script as Claude Code would, with the tty
    /// redirected to a file, and read back what it emitted.
    private func runHook(_ event: String, _ json: String, agent: String = "claude") throws -> [String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("hook.sh")
        let out = dir.appendingPathComponent("tty")
        try ClaudeIntegration.script.write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, event, agent]
        p.environment = ["PATH": "/usr/bin:/bin", "CONTERM_HOOK_TTY": out.path]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data(json.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        // OSC 9 ; payload BEL, one per emission.
        return text.components(separatedBy: "\u{07}")
            .compactMap { chunk in
                guard let r = chunk.range(of: "\u{1b}]9;conterm-agent:\(agent):") else { return nil }
                return String(chunk[r.upperBound...])
            }
    }

    @Test func hookReportsAToolStartWithItsCommand() throws {
        let json = #"{"session_id":"s","transcript_path":"/t/abc.jsonl","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cd infra && terraform plan -var \"env=prod\"","description":"Plan the \"command\""},"tool_use_id":"toolu_01ABC"}"#
        let emitted = try runHook("PreToolUse", json)
        // One event only: a second notification inside a second is dropped.
        #expect(emitted.count == 1)
        let tool = emitted.first ?? ""
        #expect(tool.hasPrefix("tool:"))
        let event = AgentToolEvent.parse(String(tool.dropFirst(5)))
        #expect(event == .start(id: "toolu_01ABC", toolName: "Bash",
                                command: "cd infra && terraform plan -var \"env=prod\""))
    }

    @Test func hookNamesAFileToolByItsPath() throws {
        let json = #"{"transcript_path":"/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/src/App.swift","old_string":"\"command\": \"x\"","new_string":"y"},"tool_use_id":"toolu_01EDT"}"#
        let emitted = try runHook("PreToolUse", json)
        let event = AgentToolEvent.parse(String((emitted.first ?? "").dropFirst(5)))
        #expect(event == .start(id: "toolu_01EDT", toolName: "Edit", command: "/src/App.swift"))
    }

    @Test func liveBubblesGroupByKindAndHoldQuickCalls() async throws {
        let live = LiveToolBubbles()
        let t0 = Date()
        var a = AgentToolRun(id: "a", kind: .read, startedAt: t0)
        var b = AgentToolRun(id: "b", kind: .read, startedAt: t0.addingTimeInterval(0.1))
        let c = AgentToolRun(id: "c", kind: .webSearch, startedAt: t0.addingTimeInterval(0.2))
        live.sync([a, b, c])
        #expect(live.items.map(\.id) == ["read", "webSearch"])
        #expect(live.items[0].count == 2)
        // Both reads return at once: the bubble is held, showing the end.
        a.endedAt = Date(); b.endedAt = Date()
        live.sync([a, b, c])
        #expect(live.items.map(\.id) == ["read", "webSearch"])
        #expect(live.items[0].count == 1)
        #expect(!live.items[0].run.isRunning)
        // The hold releases on its own timer; give a busy main actor room.
        for _ in 0..<40 where live.items.count > 1 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(live.items.map(\.id) == ["webSearch"])
    }

    @Test func hookTakesTheOuterToolUseIdOverOneInTheResponse() throws {
        let json = #"{"transcript_path":"/t.jsonl","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cat x"},"tool_response":{"stdout":"{\"tool_use_id\":\"toolu_FAKE\"}","stderr":""},"tool_use_id":"toolu_01DEF","duration_ms":12}"#
        #expect(try runHook("PostToolUse", json) == ["tool:end:toolu_01DEF:ok"])
        let fail = #"{"hook_event_name":"PostToolUseFailure","tool_name":"mcp__kubernetes__list_pods","tool_input":{"ns":"x"},"tool_use_id":"toolu_01GHI","error":"boom"}"#
        #expect(try runHook("PostToolUseFailure", fail) == ["tool:end:toolu_01GHI:fail"])
    }

    @Test func hookPhaseEventsAreUnchanged() throws {
        #expect(try runHook("SessionStart", #"{"transcript_path":"/t.jsonl"}"#) == ["start:/t.jsonl"])
        #expect(try runHook("Stop", #"{"transcript_path":"/t.jsonl"}"#) == ["idle:/t.jsonl"])
        #expect(try runHook("Notification", #"{"transcript_path":"/t.jsonl"}"#) == ["attention:/t.jsonl"])
        #expect(try runHook("SessionEnd", "{}") == ["end:"])
    }
}
