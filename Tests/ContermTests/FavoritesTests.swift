import Testing
import Foundation
@testable import Conterm

/// The Favorites list and the Run in All Terminals rules. Each store test
/// uses its own UserDefaults suite, so nothing touches the app's defaults.
@MainActor
struct FavoritesTests {

    private func makeStore() -> (FavoritesStore, UserDefaults) {
        let suite = "conterm.tests.favorites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (FavoritesStore(defaults: defaults), defaults)
    }

    @Test func addTrimsAndKeepsOrder() {
        let (store, _) = makeStore()
        #expect(store.add("  git status \n") == .added)
        #expect(store.add("ls -la") == .added)
        #expect(store.commands == ["git status", "ls -la"])
    }

    @Test func addRefusesDuplicatesAndBlanks() {
        let (store, _) = makeStore()
        store.add("clear")
        #expect(store.add("clear ") == .duplicate)
        #expect(store.add("   ") == .empty)
        #expect(store.commands == ["clear"])
    }

    @Test func addStopsAtTheLimit() {
        let (store, _) = makeStore()
        for i in 0..<FavoritesStore.limit { store.add("echo \(i)") }
        #expect(store.add("one more") == .full)
        #expect(store.commands.count == FavoritesStore.limit)
        store.remove("echo 0")
        #expect(store.add("one more") == .added)
        #expect(store.commands.last == "one more")
    }

    @Test func listPersistsAcrossStores() {
        let (store, defaults) = makeStore()
        store.add("make test")
        store.add("make lint")
        store.remove("make test")
        #expect(FavoritesStore(defaults: defaults).commands == ["make lint"])
    }

    @Test func filterIsCaseInsensitiveSubstring() {
        let (store, _) = makeStore()
        store.add("kubectl get pods")
        store.add("Git Log")
        store.add("htop")
        #expect(store.filtered("GET") == ["kubectl get pods"])
        #expect(store.filtered("g") == ["kubectl get pods", "Git Log"])
        #expect(store.filtered(" ") == store.commands)
    }

    // MARK: - Run in All Terminals

    @Test func shellsAndSSHTakeTheCommand() {
        for name in ["zsh", "-zsh", "bash", "fish", "ssh", "mosh-client"] {
            #expect(RunAllTerminals.disposition(live: true, foreground: name, agent: nil) == .run)
        }
    }

    @Test func otherProgramsAndAgentsAreSkipped() {
        #expect(RunAllTerminals.disposition(live: true, foreground: "vim", agent: nil)
                == .busy("vim"))
        // An agent counts even while its shell is momentarily in front.
        #expect(RunAllTerminals.disposition(live: true, foreground: "zsh", agent: "Claude")
                == .busy("Claude"))
        #expect(RunAllTerminals.disposition(live: true, foreground: nil, agent: nil)
                == .busy("an unknown program"))
        #expect(RunAllTerminals.disposition(live: false, foreground: "zsh", agent: nil)
                == .noShell)
    }

    @Test func scopeLineCountsTabsAndWindows() {
        func target(tab: UUID, window: Int) -> RunAllTerminals.Target {
            RunAllTerminals.Target(id: UUID(), pane: nil, label: "t",
                                   windowIndex: window, tabID: tab, disposition: .run)
        }
        let a = UUID(), b = UUID()
        #expect(CommandPalette.runAllScope([]) == "No terminal is at a prompt.")
        #expect(CommandPalette.runAllScope([target(tab: a, window: 0)])
                == "1 terminal in 1 tab.")
        #expect(CommandPalette.runAllScope([target(tab: a, window: 0),
                                            target(tab: a, window: 0),
                                            target(tab: b, window: 1)])
                == "3 terminals in 2 tabs, 2 windows.")
    }
}
