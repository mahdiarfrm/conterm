import Testing
import Foundation
@testable import Conterm

/// Structural behavior of the pane tree: split, close, focus, snapshot
/// round-trips. Pure model layer — no surfaces are created; sound
/// effects are disabled via their UserDefaults gate so `split`/`close`
/// never start an audio engine in the test runner.
@MainActor
@Suite struct PaneTreeTests {

    init() {
        UserDefaults.standard.set(false, forKey: "conterm.soundEffects")
    }

    // MARK: - Initial state

    @Test func initialTreeIsSingleActiveLeaf() {
        let tree = PaneTree()
        #expect(tree.root.isLeaf)
        #expect(tree.root.leaves().count == 1)
        #expect(tree.activePaneID == tree.root.leaves().first?.id)
        #expect(tree.activePane != nil)
    }

    // MARK: - Split

    @Test func splitActivatesNewPaneAndInheritsCwd() {
        let tree = PaneTree()
        let original = tree.activePane!
        original.cwd = "/tmp/original"

        #expect(tree.split(axis: .horizontal))

        #expect(tree.root.leaves().count == 2)
        #expect(!tree.root.isLeaf)
        let newPane = tree.activePane!
        #expect(newPane.id != original.id)
        #expect(newPane.startingDir == "/tmp/original")
        #expect(tree.revision == 1)
    }

    @Test func splitWithUnknownActivePaneFails() {
        let tree = PaneTree()
        tree.activePaneID = UUID()
        #expect(!tree.split(axis: .vertical))
        #expect(tree.root.leaves().count == 1)
        #expect(tree.revision == 0)
    }

    // MARK: - Close

    @Test func closeLastPaneReportsTabShouldClose() {
        let tree = PaneTree()
        #expect(!tree.closePane(id: tree.activePaneID))
    }

    @Test func closeActivePaneMovesFocusToSibling() {
        let tree = PaneTree()
        let original = tree.activePane!
        tree.split(axis: .horizontal)
        let newPane = tree.activePane!

        #expect(tree.closePane(id: newPane.id))

        #expect(tree.root.isLeaf)
        #expect(tree.root.leaves().count == 1)
        #expect(tree.activePaneID == original.id)
    }

    @Test func closeBackgroundPaneKeepsFocus() {
        let tree = PaneTree()
        let original = tree.activePane!
        tree.split(axis: .horizontal)
        let newPane = tree.activePane!

        #expect(tree.closePane(id: original.id))

        #expect(tree.activePaneID == newPane.id)
        #expect(tree.root.leaves().count == 1)
    }

    @Test func closeMiddlePaneOfNestedSplitPreservesOthers() {
        let tree = PaneTree()
        let a = tree.activePane!
        tree.split(axis: .horizontal)          // [A | B], active B
        let b = tree.activePane!
        tree.split(axis: .vertical)            // [A | [B / C]], active C
        let c = tree.activePane!
        #expect(tree.root.leaves().count == 3)

        #expect(tree.closePane(id: b.id))

        let survivors = tree.root.leaves().map(\.id)
        #expect(survivors.count == 2)
        #expect(survivors.contains(a.id))
        #expect(survivors.contains(c.id))
        #expect(tree.activePaneID == c.id)
    }

    @Test func closeUnknownPaneFails() {
        let tree = PaneTree()
        tree.split(axis: .horizontal)
        #expect(!tree.closePane(id: UUID()))
        #expect(tree.root.leaves().count == 2)
    }

    // MARK: - Snapshot round-trip

    @Test func snapshotRoundTripPreservesStructure() throws {
        let tree = PaneTree()
        tree.activePane!.cwd = "/tmp/left"
        tree.split(axis: .vertical)
        tree.activePane!.cwd = "/tmp/right"
        tree.root.firstFraction = 0.3

        let restored = PaneNode.from(snapshot: tree.root.toSnapshot())

        guard case .split(let axis, _, _) = restored.kind else {
            Issue.record("restored root should be a split")
            return
        }
        #expect(axis == .vertical)
        #expect(abs(restored.firstFraction - 0.3) < 0.0001)
        #expect(restored.leaves().map(\.cwd) == ["/tmp/left", "/tmp/right"])
        // Restored panes spawn their shells in the saved directory.
        #expect(restored.leaves().map(\.startingDir) == ["/tmp/left", "/tmp/right"])
    }

    @Test func restoreClampsDividerFraction() {
        let leaf = SessionStore.PaneTreeSnapshot.leaf(cwd: nil, scrollback: nil, agentSession: nil)
        let squeezed = PaneNode.from(snapshot: .split(axis: "horizontal", fraction: 0.01,
                                                      first: leaf, second: leaf))
        #expect(abs(squeezed.firstFraction - 0.12) < 0.0001)

        let stretched = PaneNode.from(snapshot: .split(axis: "horizontal", fraction: 0.99,
                                                       first: leaf, second: leaf))
        #expect(abs(stretched.firstFraction - 0.88) < 0.0001)
    }

    @Test func restoreFallsBackToHorizontalOnUnknownAxis() {
        let leaf = SessionStore.PaneTreeSnapshot.leaf(cwd: nil, scrollback: nil, agentSession: nil)
        let node = PaneNode.from(snapshot: .split(axis: "diagonal", fraction: 0.5,
                                                  first: leaf, second: leaf))
        guard case .split(let axis, _, _) = node.kind else {
            Issue.record("should restore as a split")
            return
        }
        #expect(axis == .horizontal)
    }

    @Test func restoredLeafCarriesScrollbackAndAgentSession() {
        let node = PaneNode.from(snapshot: .leaf(cwd: "/srv", scrollback: "old output",
                                                 agentSession: "abc-123"))
        let pane = node.leaves().first!
        #expect(pane.cwd == "/srv")
        #expect(pane.pendingScrollback == "old output")
        #expect(pane.pendingAgentResume == "abc-123")
    }

    // MARK: - Agent session id

    @Test func agentSessionIDFromTranscriptPath() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.agentTranscriptPath = "/x/projects/abc-123.jsonl"
        #expect(PaneNode.agentSessionID(for: pane) == "abc-123")
    }

    @Test func agentSessionIDRequiresRunningClaudeWithTranscript() {
        let idle = Pane()
        idle.agentTranscriptPath = "/x/abc.jsonl"
        #expect(PaneNode.agentSessionID(for: idle) == nil)

        let opencode = Pane()
        opencode.agent = AgentStatus(phase: .working, tool: .opencode)
        opencode.agentTranscriptPath = "/x/abc.jsonl"
        #expect(PaneNode.agentSessionID(for: opencode) == nil)

        let noJsonl = Pane()
        noJsonl.agent = AgentStatus(phase: .working, tool: .claude)
        noJsonl.agentTranscriptPath = "/x/abc.txt"
        #expect(PaneNode.agentSessionID(for: noJsonl) == nil)
    }
}
