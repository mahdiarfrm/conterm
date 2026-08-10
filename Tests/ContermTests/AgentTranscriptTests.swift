import Testing
import Foundation
@testable import Conterm

/// AgentTranscriptStore's incremental JSONL parsing: per-message token
/// dedupe, the append/offset logic, task + shell-feed extraction, and
/// the pricing table. Each test drives its own store instance against
/// a temp transcript via the `transcriptPath` pin, so nothing under
/// the real ~/.claude is touched.
@Suite struct AgentTranscriptTests {

    // MARK: - Fixtures

    /// Write `lines` (joined with \n + trailing \n) to a fresh temp
    /// transcript; the returned cleanup removes it.
    private func makeTranscript(_ lines: [String]) -> (path: String, cleanup: () -> Void) {
        let path = NSTemporaryDirectory() + "conterm-test-\(UUID().uuidString).jsonl"
        let text = lines.map { $0 + "\n" }.joined()
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return (path, { try? FileManager.default.removeItem(atPath: path) })
    }

    private func append(_ text: String, to path: String) {
        let fh = FileHandle(forWritingAtPath: path)!
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: text.data(using: .utf8)!)
    }

    private func assistant(id: String?, model: String = "claude-opus-4-5",
                           input: Int, output: Int,
                           cacheCreate: Int = 0, cacheRead: Int = 0) -> String {
        let idPart = id.map { "\"id\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"gitBranch\":\"main\",\"message\":{\(idPart)"
            + "\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),"
            + "\"output_tokens\":\(output),\"cache_creation_input_tokens\":\(cacheCreate),"
            + "\"cache_read_input_tokens\":\(cacheRead)}}}"
    }

    private func user(_ content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "{\"type\":\"user\",\"message\":{\"content\":\"\(escaped)\"}}"
    }

    private func usage(of store: AgentTranscriptStore, at path: String) -> AgentUsage? {
        store.usage(forCwd: nil, transcriptPath: path)
    }

    // MARK: - Accumulation + dedupe

    @Test func sumsTokensAcrossDistinctMessages() {
        let (path, cleanup) = makeTranscript([
            assistant(id: "m1", input: 100, output: 10, cacheCreate: 5, cacheRead: 1000),
            assistant(id: "m2", input: 200, output: 20, cacheCreate: 7, cacheRead: 2000),
        ])
        defer { cleanup() }
        let u = usage(of: AgentTranscriptStore(), at: path)
        #expect(u?.inputTokens == 300)
        #expect(u?.outputTokens == 30)
        #expect(u?.cacheCreateTokens == 12)
        #expect(u?.cacheReadTokens == 3000)
        #expect(u?.turns == 2)
        #expect(u?.model == "claude-opus-4-5")
        #expect(u?.branch == "main")
    }

    /// Claude Code re-logs a streaming message several times under the
    /// same id with growing usage — the last write must win, not sum.
    @Test func streamedMessageCountsOnce() {
        let (path, cleanup) = makeTranscript([
            assistant(id: "m1", input: 100, output: 5),
            assistant(id: "m1", input: 100, output: 25),
            assistant(id: "m1", input: 100, output: 60),
        ])
        defer { cleanup() }
        let u = usage(of: AgentTranscriptStore(), at: path)
        #expect(u?.inputTokens == 100)
        #expect(u?.outputTokens == 60)
        #expect(u?.turns == 1)
    }

    @Test func idLessMessagesEachCount() {
        let (path, cleanup) = makeTranscript([
            assistant(id: nil, input: 10, output: 1),
            assistant(id: nil, input: 20, output: 2),
        ])
        defer { cleanup() }
        let u = usage(of: AgentTranscriptStore(), at: path)
        #expect(u?.inputTokens == 30)
        #expect(u?.turns == 2)
    }

    @Test func totalTokensExcludesCacheReads() {
        var u = AgentUsage()
        u.inputTokens = 10
        u.outputTokens = 20
        u.cacheCreateTokens = 30
        u.cacheReadTokens = 1_000_000
        #expect(u.totalTokens == 60)
    }

    // MARK: - Incremental reads

    @Test func appendedLinesAccumulateAcrossCalls() {
        let (path, cleanup) = makeTranscript([assistant(id: "m1", input: 100, output: 10)])
        defer { cleanup() }
        let store = AgentTranscriptStore()
        #expect(usage(of: store, at: path)?.inputTokens == 100)

        append(assistant(id: "m2", input: 50, output: 5) + "\n", to: path)
        let u = usage(of: store, at: path)
        #expect(u?.inputTokens == 150)
        #expect(u?.turns == 2)
    }

    /// A partial line (no trailing newline yet — the agent is mid-write)
    /// is left for the next read, then counted once complete.
    @Test func partialTailWaitsForItsNewline() {
        let (path, cleanup) = makeTranscript([assistant(id: "m1", input: 100, output: 10)])
        defer { cleanup() }
        let store = AgentTranscriptStore()
        _ = usage(of: store, at: path)

        let line = assistant(id: "m2", input: 50, output: 5)
        let cut = line.index(line.startIndex, offsetBy: 25)
        append(String(line[..<cut]), to: path)
        #expect(usage(of: store, at: path)?.turns == 1)

        append(String(line[cut...]) + "\n", to: path)
        let u = usage(of: store, at: path)
        #expect(u?.turns == 2)
        #expect(u?.inputTokens == 150)
    }

    /// A transcript that shrank (rotated / rewritten) resets the
    /// accumulator instead of double-counting or seeking past the end.
    @Test func truncatedFileResetsAccumulator() {
        let (path, cleanup) = makeTranscript([
            assistant(id: "m1", input: 100, output: 10),
            assistant(id: "m2", input: 200, output: 20),
        ])
        defer { cleanup() }
        let store = AgentTranscriptStore()
        #expect(usage(of: store, at: path)?.inputTokens == 300)

        try? (assistant(id: "m9", input: 7, output: 3) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        let u = usage(of: store, at: path)
        #expect(u?.inputTokens == 7)
        #expect(u?.turns == 1)
    }

    @Test func usageNilWithoutAnySource() {
        #expect(AgentTranscriptStore().usage(forCwd: nil, transcriptPath: nil) == nil)
        #expect(AgentTranscriptStore().usage(forCwd: "", transcriptPath: "") == nil)
    }

    // MARK: - Task extraction

    @Test func taskIsFirstMeaningfulPromptLine() {
        let (path, cleanup) = makeTranscript([
            user("<system-reminder>injected</system-reminder>\nCaveat: wrapper\n[Image: pasted]\nfix the login bug\nmore detail"),
            assistant(id: "m1", input: 1, output: 1),
        ])
        defer { cleanup() }
        #expect(usage(of: AgentTranscriptStore(), at: path)?.task == "fix the login bug")
    }

    /// Tool-result user turns carry no text block; the standing task
    /// stays in place instead of blanking.
    @Test func toolResultTurnLeavesTaskInPlace() {
        let toolResult = "{\"type\":\"user\",\"message\":{\"content\":"
            + "[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\"}]}}"
        let (path, cleanup) = makeTranscript([
            user("real task"),
            toolResult,
            assistant(id: "m1", input: 1, output: 1),
        ])
        defer { cleanup() }
        #expect(usage(of: AgentTranscriptStore(), at: path)?.task == "real task")
    }

    @Test func taskFromContentArrayAndCapped() {
        let long = String(repeating: "x", count: 200)
        let arrayUser = "{\"type\":\"user\",\"message\":{\"content\":"
            + "[{\"type\":\"text\",\"text\":\"\(long)\"}]}}"
        let (path, cleanup) = makeTranscript([
            arrayUser,
            assistant(id: "m1", input: 1, output: 1),
        ])
        defer { cleanup() }
        let task = usage(of: AgentTranscriptStore(), at: path)?.task
        #expect(task?.count == 141)   // 140 + ellipsis
        #expect(task?.hasSuffix("…") == true)
    }

    // MARK: - Shell feed

    private func bashTurn(msgID: String, toolID: String, command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        // Near-now timestamp: the shell feed ages commands out after a
        // few minutes, so a fixed fixture date would come back empty.
        let now = ISO8601DateFormatter().string(from: Date())
        return "{\"type\":\"assistant\",\"timestamp\":\"\(now)\","
            + "\"message\":{\"id\":\"\(msgID)\",\"content\":"
            + "[{\"type\":\"tool_use\",\"id\":\"\(toolID)\",\"name\":\"Bash\","
            + "\"input\":{\"command\":\"\(escaped)\"}}],"
            + "\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}"
    }

    @Test func shellCommandsDedupedByToolUseID() {
        let (path, cleanup) = makeTranscript([
            bashTurn(msgID: "m1", toolID: "t1", command: "ls -la"),
            bashTurn(msgID: "m1", toolID: "t1", command: "ls -la"),   // streamed re-log
            bashTurn(msgID: "m2", toolID: "t2", command: "git status"),
        ])
        defer { cleanup() }
        let cmds = usage(of: AgentTranscriptStore(), at: path)?.shellCommands ?? []
        #expect(cmds.map(\.command) == ["ls -la", "git status"])
    }

    @Test func longShellCommandTruncated() {
        let (path, cleanup) = makeTranscript([
            bashTurn(msgID: "m1", toolID: "t1",
                     command: String(repeating: "a", count: 300)),
        ])
        defer { cleanup() }
        let cmd = usage(of: AgentTranscriptStore(), at: path)?.shellCommands.first
        #expect(cmd?.command.count == 201)   // 200 + ellipsis
        #expect(cmd?.command.hasSuffix("…") == true)
    }

    @Test func nonBashToolUseIgnored() {
        let read = "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",\"content\":"
            + "[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Read\","
            + "\"input\":{\"command\":\"not a shell command\"}}],"
            + "\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}"
        let (path, cleanup) = makeTranscript([read])
        defer { cleanup() }
        #expect(usage(of: AgentTranscriptStore(), at: path)?.shellCommands.isEmpty == true)
    }

    // MARK: - Timestamps + path encoding + pricing

    @Test func parsesTimestampsWithAndWithoutFractionalSeconds() {
        #expect(AgentTranscriptStore.parseTimestamp("2026-07-03T10:00:00.123Z") != nil)
        #expect(AgentTranscriptStore.parseTimestamp("2026-07-03T10:00:00Z") != nil)
        #expect(AgentTranscriptStore.parseTimestamp("yesterday-ish") == nil)
        #expect(AgentTranscriptStore.parseTimestamp(nil) == nil)
    }

    @Test func encodesCwdLikeClaudeCode() {
        #expect(AgentTranscriptStore.encode(cwd: "/Users/me/dev.project")
                == "-Users-me-dev-project")
    }

    @Test func pricingTiersByModelSubstring() {
        #expect(AgentPricing.rate(for: "claude-haiku-4-5").input == 1)
        #expect(AgentPricing.rate(for: "claude-sonnet-5").input == 3)
        #expect(AgentPricing.rate(for: "claude-opus-4-8").input == 5)
        #expect(AgentPricing.rate(for: nil).input == 5)          // unknown → opus tier
        #expect(AgentPricing.rate(for: "mystery-model").input == 5)
    }

    @Test func costSumsPerTokenClassRates() {
        var u = AgentUsage(model: "claude-sonnet-5")
        u.inputTokens = 1_000_000
        u.outputTokens = 1_000_000
        u.cacheCreateTokens = 1_000_000
        u.cacheReadTokens = 1_000_000
        #expect(abs(u.estCost - (3 + 15 + 3.75 + 0.30)) < 0.0001)
    }
}
