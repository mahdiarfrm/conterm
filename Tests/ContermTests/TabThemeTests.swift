import Testing
import Foundation
@testable import Conterm

/// Per-tab theme state transitions on AppState. No surfaces are
/// created (ghostty is nil; the setters still update state), so the
/// theme ids are plain strings. Both follow slots are filled with
/// the same id where the on-screen theme must not depend on whether
/// this machine is currently in Light or Dark mode.
@MainActor
struct TabThemeTests {

    private func makeState() -> AppState {
        AppState(prefs: Preferences(),
                 ghostty: nil,
                 notesStore: NotesStore(),
                 showLaunchOverlay: false)
    }

    /// No tab theme, no window theme: the tab renders the global
    /// theme (nil at every level).
    @Test func unsetTabInheritsGlobal() {
        let state = makeState()
        let tab = state.tabs[0]
        #expect(tab.hasOwnTheme == false)
        #expect(state.effectiveThemeID(for: tab) == nil)
    }

    /// An unset tab inherits the window's theme.
    @Test func unsetTabInheritsWindowTheme() {
        let state = makeState()
        state.setWindowTheme("W")
        let tab = state.tabs[0]
        #expect(state.effectiveThemeID(for: tab) == "W")
    }

    /// A tab theme wins over the window's theme.
    @Test func tabThemeOverridesWindowTheme() {
        let state = makeState()
        state.setWindowTheme("W")
        let tab = state.tabs[0]
        state.setTabTheme(tab, "T")
        #expect(tab.themeID == "T")
        #expect(state.effectiveThemeID(for: tab) == "T")
    }

    /// Clearing the tab theme drops the whole override — fixed,
    /// follow, and both slots — back to inheriting the window.
    @Test func clearingTabThemeRestoresInheritance() {
        let state = makeState()
        state.setWindowTheme("W")
        let tab = state.tabs[0]
        state.setTabTheme(tab, "T")
        state.setTabThemeFollowsSystem(tab, true)
        state.setTabTheme(tab, nil)
        #expect(tab.hasOwnTheme == false)
        #expect(tab.themeFollowsSystem == false)
        #expect(state.effectiveThemeID(for: tab) == "W")
    }

    /// Fixed T, Follow on (T seeds a slot), the other slot filled and
    /// shown: Follow off keeps what's on screen, not T.
    @Test func turningFollowOffKeepsOnScreenTheme() {
        let state = makeState()
        let tab = state.tabs[0]
        state.setTabTheme(tab, "T")
        state.setTabThemeFollowsSystem(tab, true)
        state.setTabSlotTheme(tab, "U", dark: true)
        state.setTabSlotTheme(tab, "U", dark: false)
        #expect(state.effectiveThemeID(for: tab) == "U")

        state.setTabThemeFollowsSystem(tab, false)
        #expect(tab.themeFollowsSystem == false)
        #expect(tab.themeID == "U")
        #expect(state.effectiveThemeID(for: tab) == "U")
    }

    /// A second tab's theme never leaks into the first tab.
    @Test func tabThemesAreIndependent() {
        let state = makeState()
        state.addTab()
        let first = state.tabs[0]
        let second = state.tabs[1]
        state.setTabTheme(second, "T2")
        #expect(state.effectiveThemeID(for: first) == nil)
        #expect(state.effectiveThemeID(for: second) == "T2")
    }

    /// Session round-trip: per-tab theme fields survive encode /
    /// decode, and a session file written before per-tab themes
    /// (no theme keys on the tab) still decodes with the tab
    /// inheriting.
    @Test func sessionRoundTripPreservesTabTheme() throws {
        let tab = SessionStore.Tab(
            title: "T", customTitle: false, cwd: nil, indexLabel: "Terminal 1",
            tree: nil, groupID: nil, activePaneIndex: nil,
            themeID: "Tokyo Night", themeFollowsSystem: true,
            lightThemeID: "A", darkThemeID: "B")
        let snap = SessionStore.Snapshot(windows: [
            SessionStore.Window(frame: "", tabs: [tab], selectedIndex: 0)
        ])
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(SessionStore.Snapshot.self, from: data)
        let restored = back.windows[0].tabs[0]
        #expect(restored.themeID == "Tokyo Night")
        #expect(restored.themeFollowsSystem == true)
        #expect(restored.lightThemeID == "A")
        #expect(restored.darkThemeID == "B")

        let legacy = #"{"windows":[{"frame":"","selectedIndex":0,"tabs":[{"title":"T","customTitle":false,"indexLabel":"Terminal 1"}]}]}"#
        let old = try JSONDecoder().decode(
            SessionStore.Snapshot.self, from: Data(legacy.utf8))
        #expect(old.windows[0].tabs[0].themeID == nil)
        #expect(old.windows[0].tabs[0].themeFollowsSystem == nil)
    }
}
