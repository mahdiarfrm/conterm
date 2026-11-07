import Testing
import Foundation
@testable import Conterm

/// Per-window theme state transitions on AppState. No surfaces are
/// created (ghostty is nil; the setters still update state), so the
/// theme ids are plain strings. Both follow slots are filled with
/// the same id where the on-screen theme must not depend on whether
/// this machine is currently in Light or Dark mode.
@MainActor
struct WindowThemeTests {

    private func makeState() -> AppState {
        AppState(prefs: Preferences(),
                 ghostty: nil,
                 notesStore: NotesStore(),
                 showLaunchOverlay: false)
    }

    /// Review case: fixed A, Follow on (A seeds a slot), other slot
    /// filled and shown, Follow off must keep what's on screen —
    /// not resurrect A.
    @Test func turningFollowOffKeepsOnScreenTheme() {
        let state = makeState()
        state.setWindowTheme("A")
        state.setWindowThemeFollowsSystem(true)
        state.setWindowSlotTheme("B", dark: true)
        state.setWindowSlotTheme("B", dark: false)
        #expect(state.effectiveWindowThemeID == "B")

        state.setWindowThemeFollowsSystem(false)
        #expect(state.windowThemeFollowsSystem == false)
        #expect(state.windowThemeID == "B")
        #expect(state.effectiveWindowThemeID == "B")
    }

    @Test func turningFollowOffWithoutPairKeepsFixedTheme() {
        let state = makeState()
        state.setWindowTheme("A")
        state.setWindowThemeFollowsSystem(true)
        state.setWindowThemeFollowsSystem(false)
        #expect(state.windowThemeID == "A")
        #expect(state.effectiveWindowThemeID == "A")
    }
}
