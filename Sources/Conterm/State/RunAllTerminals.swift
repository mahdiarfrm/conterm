import AppKit

/// "Run in All Terminals": one command typed into every pane of every tab,
/// grouped or not, in every window. Only panes whose shell is at its
/// prompt, or that hold an ssh session, take it. Any other foreground
/// program (an agent, an editor, a pager) would read the text as its own
/// input, so those panes are skipped and named in the preview.
enum RunAllTerminals {
    enum Disposition: Equatable {
        case run
        /// This program holds the terminal.
        case busy(String)
        /// No live shell: the tab hasn't been shown yet, or its process exited.
        case noShell
    }

    nonisolated static let shells: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh",
        "nu", "xonsh", "elvish", "pwsh",
    ]
    /// Remote sessions, whose far end is taken to be at its prompt.
    nonisolated static let remoteClients: Set<String> = ["ssh", "mosh-client", "et"]

    /// `live`: the pane has a running process. `foreground` is the
    /// terminal's foreground process name, `agent` the agent Conterm sees
    /// running in the pane. A pane whose foreground can't be read is
    /// skipped rather than guessed at.
    nonisolated static func disposition(live: Bool, foreground: String?,
                                        agent: String?) -> Disposition {
        guard live else { return .noShell }
        if let agent { return .busy(agent) }
        guard var name = foreground else { return .busy("an unknown program") }
        // A login shell's name can carry argv[0]'s leading dash.
        if name.hasPrefix("-") { name.removeFirst() }
        if shells.contains(name) || remoteClients.contains(name) { return .run }
        return .busy(name)
    }

    struct Target: Identifiable {
        let id: UUID
        weak var pane: Pane?
        /// Tab title, with the pane's number when the tab is split.
        let label: String
        let windowIndex: Int
        let tabID: UUID
        let disposition: Disposition
    }

    /// Every pane in every window, in window → tab → pane order.
    @MainActor
    static func survey() -> [Target] {
        guard let app = NSApp.delegate as? AppDelegate else { return [] }
        var targets: [Target] = []
        for (wi, wc) in app.windows.enumerated() {
            for tab in wc.state.tabs {
                let leaves = tab.paneTree.root.leaves()
                for (pi, pane) in leaves.enumerated() {
                    let ctrl = pane.controller
                    let agent = pane.agent.phase == .idle
                        ? nil : pane.agent.tool.displayName
                    targets.append(Target(
                        id: pane.id, pane: pane,
                        label: leaves.count > 1 ? "\(tab.title) · pane \(pi + 1)" : tab.title,
                        windowIndex: wi, tabID: tab.id,
                        disposition: disposition(live: ctrl?.hasLiveProcess == true,
                                                 foreground: ctrl?.foregroundProcessName,
                                                 agent: agent)))
                }
            }
        }
        return targets
    }

    /// Types `command` and Return into each pane that takes it, surveyed
    /// afresh so a program started since the preview is left alone.
    /// Returns how many panes it reached.
    @MainActor @discardableResult
    static func run(_ command: String) -> Int {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return 0 }
        var sent = 0
        for target in survey() where target.disposition == .run {
            guard let ctrl = target.pane?.controller else { continue }
            ctrl.typeText(line)
            ctrl.sendReturn()
            sent += 1
        }
        return sent
    }
}
