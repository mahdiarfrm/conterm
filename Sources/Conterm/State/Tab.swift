import Foundation
import SwiftUI

/// One tab. Owns a PaneTree (single leaf or one split). Title is
/// user-settable (rename), otherwise tracks libghostty.
@MainActor
final class Tab: ObservableObject, Identifiable {
    let id: UUID = UUID()
    @Published var title: String
    @Published var customTitle: Bool = false
    @Published var paneTree: PaneTree = PaneTree()

    /// "Terminal 1", "Terminal 2", etc. — the bare base name set at
    /// creation. Becomes the prefix when we also have a directory.
    @Published var indexLabel: String

    /// Last-known working directory's basename (e.g. "src"). Driven by
    /// libghostty's GHOSTTY_ACTION_PWD callback. Empty until the shell
    /// reports a pwd (most modern shell prompts do via OSC 7).
    @Published var pwdLabel: String = ""

    /// Last-known shell-reported window title (OSC 0/2). Typically
    /// formatted like `user@host: ~/path` for zsh+omz default. Used as
    /// a fallback when no clean pwd is available.
    @Published var shellTitle: String = ""

    /// Which `TabGroup` this tab belongs to (browser-style tab
    /// groups). Nil = ungrouped. The tab pill picks up the group's
    /// color when set. Lives in memory; per-session restore lives on
    /// SessionStore.
    @Published var groupID: UUID? = nil

    /// Most attention-worthy agent phase across this tab's panes, so the
    /// tab pill can show a glanceable dot for an agent running in a
    /// non-visible tab. Pane agents are nested ObservableObjects, so a
    /// pane change doesn't republish the Tab on its own —
    /// `recomputeAgentPhase()` (called from the agent callbacks that
    /// mutate `pane.agent`) keeps this in sync.
    @Published var agentPhase: AgentStatus.Phase = .idle

    /// Collapse all panes' agent phases to the single most important one.
    func recomputeAgentPhase() {
        let phases = paneTree.root.leaves().map { $0.agent.phase }
        let priority: [AgentStatus.Phase] = [.attention, .working, .interrupted, .ready]
        agentPhase = priority.first(where: phases.contains) ?? .idle
    }

    init(indexLabel: String = "Terminal", customTitle: String? = nil) {
        self.indexLabel = indexLabel
        self.title = customTitle ?? indexLabel
        if customTitle != nil { self.customTitle = true }
    }

    /// Tab name is just the index label ("Terminal N"). The directory
    /// chase was producing garbled output more often than not, so we
    /// keep the title minimal and let the user rename manually (or
    /// the shell can override via OSC, which we ignore now).
    func refreshTitleFromMetadata() {
        guard !customTitle else { return }
        title = indexLabel
    }
}
