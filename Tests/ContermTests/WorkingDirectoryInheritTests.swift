import Testing
import Foundation
import GhosttyKit
@testable import Conterm

/// The `*-inherit-working-directory` keys. Conterm reads them out of the
/// resolved config to decide whether to hand a new surface a cwd of its
/// own; when it doesn't, libghostty resolves `working-directory` itself
/// off the surface's context.
@MainActor
struct WorkingDirectoryInheritTests {

    /// Build a finalized config from one config-file text.
    private func loadConfig(_ text: String) -> ghostty_config_t? {
        Ghostty.initializeOnce()
        guard let cfg = ghostty_config_new() else { return nil }
        let path = NSTemporaryDirectory() + "conterm-test-\(UUID().uuidString).conf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        return cfg
    }

    @Test func defaultsInheritEverywhere() throws {
        let cfg = try #require(loadConfig(""))
        defer { ghostty_config_free(cfg) }
        let inherit = Ghostty.App.readInheritWorkingDirectory(cfg)
        #expect(inherit.window)
        #expect(inherit.tab)
        #expect(inherit.split)
    }

    @Test func configTurnsEachKeyOffIndependently() throws {
        let cfg = try #require(loadConfig("""
        window-inherit-working-directory = false
        tab-inherit-working-directory = false
        split-inherit-working-directory = true
        working-directory = home
        """))
        defer { ghostty_config_free(cfg) }
        let inherit = Ghostty.App.readInheritWorkingDirectory(cfg)
        #expect(!inherit.window)
        #expect(!inherit.tab)
        #expect(inherit.split)
    }

    @Test func eachContextReadsItsOwnKey() {
        let inherit = Ghostty.App.InheritWorkingDirectory(
            window: true, tab: false, split: true)
        #expect(inherit.applies(to: .window))
        #expect(!inherit.applies(to: .tab))
        #expect(inherit.applies(to: .split))
    }

    /// The pane's context is what libghostty picks the key from, so a
    /// pane born as a tab must not report itself as a window.
    @Test func newTabPaneCarriesTheTabContext() throws {
        let state = AppState(prefs: Preferences(),
                             ghostty: nil,
                             notesStore: NotesStore(),
                             showLaunchOverlay: false)
        let tab = state.addTab()
        let pane = try #require(tab.paneTree.root.leaves().first)
        #expect(pane.surfaceContext == .tab)
    }

    @Test func splitPaneCarriesTheSplitContext() {
        let tree = PaneTree()
        #expect(tree.split(axis: .horizontal))
        let panes = tree.root.leaves()
        #expect(panes.count == 2)
        #expect(panes.first?.surfaceContext == .window)
        #expect(panes.last?.surfaceContext == .split)
    }
}
