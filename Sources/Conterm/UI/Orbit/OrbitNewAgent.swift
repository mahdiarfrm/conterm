import AppKit
import SwiftUI

/// Starting an agent somewhere other than home.
///
/// A new session inherited whichever directory you happened to be in, which for
/// the Mac node means `~` — so every agent started from the map began in the
/// wrong place and had to be `cd`'d. The directories Claude has already been run
/// in are known (it keeps one folder per project), so they are the menu, with a
/// picker for anywhere else.
extension OrbitOverlay {

    /// Open a session running `claude` in `directory`.
    ///
    /// A directory Claude has never seen stops on its trust prompt before
    /// anything runs, so the pane is flagged and the map draws it as wanting a
    /// person rather than as an idle shell. The flag clears itself as soon as
    /// the session shows any sign of life.
    func startAgent(in directory: String) {
        let tab = state.openAgent(command: "claude", in: directory)
        guard let pane = tab.paneTree.activePane else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            OrbitModel.shared.rebuild()
            if let node = OrbitModel.shared.nodes
                .first(where: { $0.id == "pane:\(pane.id.uuidString)" }) {
                withAnimation(Theme.Spring.snappy) { barNode = node }
            }
            sim.wake()
        }
    }

    /// Ask for a directory. Modal on purpose: you are choosing where the next
    /// thing runs, and there is nothing useful to do on the map until you have.
    func chooseAgentDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start here"
        panel.message = "Where should this agent run?"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startAgent(in: url.path)
    }

    /// The recent-project menu, shared by the Mac node's dock and agents mode.
    /// Its content is read from disk, so it is built when the menu is opened
    /// rather than held in view state.
    @ViewBuilder
    func newAgentMenuItems() -> some View {
        Button("Home") { startAgent(in: NSHomeDirectory()) }
        let recents = ClaudeProjects.recent()
        if !recents.isEmpty {
            Divider()
            // The full path is the disambiguator when two projects share a
            // last component, so it goes in the help rather than the label.
            ForEach(recents, id: \.self) { dir in
                Button(ClaudeProjects.shortLabel(dir)) { startAgent(in: dir) }
                    .help(dir)
            }
        }
        Divider()
        Button("Choose a folder…") { chooseAgentDirectory() }
    }
}
