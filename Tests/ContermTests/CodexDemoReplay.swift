import Foundation
import Testing
@testable import Conterm

/// Replays a captured hook stream through the pane's own handling and
/// prints what the chrome would show at each step.
@MainActor
struct CodexDemoReplay {

    @Test func replay() async throws {
        guard let path = ProcessInfo.processInfo.environment["CONTERM_DEMO_TTY"],
              let raw = try? String(contentsOfFile: path, encoding: .utf8)
        else { return }

        let messages = raw.components(separatedBy: "\u{07}").compactMap { chunk -> String? in
            guard let r = chunk.range(of: "\u{1b}]9;conterm-agent:") else { return nil }
            return String(chunk[r.upperBound...])
        }

        let pane = Pane()
        let live = LiveToolBubbles()
        print("\n\u{001B}[1m  what the pane does with those bytes\u{001B}[0m")
        print("  " + String(repeating: "─", count: 74))

        for msg in messages {
            let parts = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":", maxSplits: 2).map(String.init)
            let tool = AgentTool(rawValue: parts[0]) ?? .generic
            let state = parts.count > 1 ? parts[1] : ""

            if state == "tool", parts.count > 2, let event = AgentToolEvent.parse(parts[2]) {
                if case .start = event, pane.agent.phase != .working {
                    pane.agent = AgentStatus(phase: .working, tool: tool)
                }
                pane.applyToolEvent(event)
            } else {
                if parts.count > 2, !parts[2].isEmpty { pane.agentTranscriptPath = parts[2] }
                let phase: AgentStatus.Phase
                switch state {
                case "start", "idle", "stop": phase = .ready
                case "prompt", "working":     phase = .working
                case "attention", "notify":   phase = .attention
                case "end", "exit":           phase = .idle
                default: continue
                }
                if phase == .idle { pane.agentTranscriptPath = nil }
                // Settling open runs and clearing them at session end is
                // the pane's own reaction to the phase (see Pane.agent).
                pane.agent = AgentStatus(phase: phase, tool: tool)
            }
            live.sync(pane.toolRuns)

            let wire = msg.count > 62 ? String(msg.prefix(62)) + "…" : msg
            print("  \u{001B}[2m▸ \(wire)\u{001B}[0m")
            let pill = pane.agent.phase == .idle
                ? "— no pill —" : "[ \(pane.agent.label) ]"
            print("      pill     \(pill)")
            let bubbles = live.items.map { item -> String in
                let mark = item.run.isRunning ? "◍" : (item.run.failed ? "✗" : "✓")
                let n = item.count > 1 ? " ×\(item.count)" : ""
                return "( \(mark) \(item.kind.displayName)\(n) · \(item.run.title) )"
            }
            print("      bubbles  \(bubbles.isEmpty ? "—" : bubbles.joined(separator: "  "))")
            // The hook gap the agent really leaves between events, so a
            // bubble's minimum-show hold expires the way it does live.
            try await Task.sleep(nanoseconds: 1_300_000_000)
            live.sync(pane.toolRuns)
        }

        print("  " + String(repeating: "─", count: 74))
        let history = pane.toolRuns.map {
            "\($0.kind.displayName): \($0.title)\($0.failed ? " (failed)" : "")"
        }
        print("  History capsule holds \(pane.toolRuns.count): \(history.joined(separator: ", "))")
        print("  Transcript the pane polls: \(pane.agentTranscriptPath ?? "none — session ended")\n")
    }
}
