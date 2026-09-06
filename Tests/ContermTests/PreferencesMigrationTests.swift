import Testing
import Foundation
@testable import Conterm

/// Preferences' load-time migrations and repairs: the solidGlass →
/// glassMode migration, the palette-order splice for late-added
/// commands, the widget-rail seed from the legacy stats flag, and the
/// sidebar-width clamp. `.serialized` because every test mutates the
/// process-shared UserDefaults; each cleans up the keys it touches.
@MainActor
@Suite(.serialized) struct PreferencesMigrationTests {

    private static let touchedKeys = [
        "conterm.glassMode",
        "conterm.solidGlass",
        "conterm.opaquePanes",
        "conterm.paletteCommandOrder",
        "conterm.hiddenPaletteCommands",
        "conterm.paletteSeeds",
        "conterm.enabledWidgets",
        "conterm.showSystemStats",
        "conterm.sidebarWidth",
    ]

    /// Run `body` against defaults where the touched keys hold exactly
    /// `values` (all others removed), restoring a clean slate after.
    private func withDefaults(_ values: [String: Any],
                              _ body: (UserDefaults) throws -> Void) rethrows {
        let ud = UserDefaults.standard
        for k in Self.touchedKeys { ud.removeObject(forKey: k) }
        for (k, v) in values { ud.set(v, forKey: k) }
        defer { for k in Self.touchedKeys { ud.removeObject(forKey: k) } }
        try body(ud)
    }

    // MARK: - solidGlass → glassMode

    @Test func legacySolidGlassMigratesToSolidMode() {
        withDefaults(["conterm.solidGlass": true]) { _ in
            #expect(Preferences().glassMode == .solid)
        }
    }

    @Test func glassModeDefaultsToBlur() {
        withDefaults([:]) { _ in
            #expect(Preferences().glassMode == .blur)
        }
    }

    @Test func legacyNonSolidFlagMigratesToGlass() {
        withDefaults(["conterm.solidGlass": false]) { _ in
            #expect(Preferences().glassMode == .glass)
        }
    }

    @Test func solidPanesDefaultOff() {
        withDefaults([:]) { _ in
            #expect(Preferences().opaquePanes == false)
        }
    }

    @Test func explicitGlassModeBeatsLegacyFlag() {
        withDefaults(["conterm.glassMode": "blur",
                      "conterm.solidGlass": true]) { _ in
            #expect(Preferences().glassMode == .blur)
        }
    }

    @Test func unknownGlassModeFallsBackThroughMigration() {
        withDefaults(["conterm.glassMode": "prismatic",
                      "conterm.solidGlass": true]) { _ in
            #expect(Preferences().glassMode == .solid)
        }
    }

    // MARK: - Palette-order splice

    @Test func agentsSplicedAfterShellHistory() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["sessions", "shell_history", "notes"]]) { ud in
            #expect(Preferences().paletteCommandOrder
                    == expectedAfterShellHistory)
            // The repaired order is persisted, not just in-memory.
            #expect(ud.stringArray(forKey: "conterm.paletteCommandOrder")
                    == expectedAfterShellHistory)
        }
    }

    private var expectedAfterShellHistory: [String] {
        ["sessions", "shell_history", "clipboard_history", "agents",
         "agent_next", "agent_changes", "briefing", "notes", "open_vscode",
         "fleet_run", "terraform_plan"]
    }

    @Test func agentsSplicedAfterSessionsWhenNoShellHistory() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["sessions", "notes"]]) { _ in
            #expect(Preferences().paletteCommandOrder
                    == ["sessions", "agents", "agent_next", "agent_changes",
                        "briefing", "notes", "open_vscode", "fleet_run",
                        "terraform_plan", "clipboard_history"])
        }
    }

    @Test func agentsAppendedWhenNoAnchorExists() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["notes", "themes"]]) { _ in
            #expect(Preferences().paletteCommandOrder
                    == ["notes", "themes", "agents", "agent_next",
                        "agent_changes", "briefing", "open_vscode",
                        "fleet_run", "terraform_plan", "clipboard_history"])
        }
    }

    @Test func orderContainingAgentsUntouched() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["agents", "sessions", "shell_history"]]) { _ in
            #expect(Preferences().paletteCommandOrder
                    == ["agents", "agent_next", "agent_changes", "briefing",
                        "sessions", "shell_history", "clipboard_history",
                        "open_vscode", "fleet_run", "terraform_plan"])
        }
    }

    @Test func vscodeSplicedDirectlyAfterCursor() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["reveal_finder", "open_cursor", "agents", "notes"]]) { _ in
            #expect(Preferences().paletteCommandOrder
                    == ["reveal_finder", "open_cursor", "open_vscode",
                        "agents", "agent_next", "agent_changes", "briefing",
                        "notes", "fleet_run", "terraform_plan",
                        "clipboard_history"])
        }
    }

    @Test func fleetRunSplicedDirectlyAfterSSH() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["sessions", "agents", "ssh_hosts", "notes",
                        "open_vscode"]]) { _ in
            #expect(Preferences().paletteCommandOrder
                    == ["sessions", "agents", "agent_next", "agent_changes",
                        "briefing", "ssh_hosts", "fleet_run",
                        "terraform_plan", "notes", "open_vscode",
                        "clipboard_history"])
        }
    }

    @Test func clipboardSplicedDirectlyAfterShellHistory() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["agents", "shell_history", "ssh_hosts", "fleet_run",
                        "open_vscode"]]) { _ in
            #expect(Preferences().paletteCommandOrder
                    == ["agents", "agent_next", "agent_changes", "briefing",
                        "shell_history", "clipboard_history", "ssh_hosts",
                        "fleet_run", "terraform_plan", "open_vscode"])
        }
    }

    @Test func agentChangesAndBriefingRideAgentNext() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["agents", "agent_next", "notes"]]) { _ in
            #expect(Preferences().paletteCommandOrder
                    == ["agents", "agent_next", "agent_changes", "briefing",
                        "notes", "open_vscode", "fleet_run",
                        "terraform_plan", "clipboard_history"])
        }
    }

    @Test func terraformSplicedDirectlyAfterFleetRun() {
        withDefaults(["conterm.paletteCommandOrder":
                        ["ssh_hosts", "fleet_run", "agents", "agent_next",
                        "agent_changes", "briefing", "notes"]]) { _ in
            #expect(Preferences().paletteCommandOrder
                    == ["ssh_hosts", "fleet_run", "terraform_plan", "agents",
                        "agent_next", "agent_changes", "briefing", "notes",
                        "open_vscode", "clipboard_history"])
        }
    }

    @Test func vscodeSeededHiddenIntoExistingSets() {
        withDefaults([:]) { _ in
            #expect(Preferences().hiddenPaletteCommands == ["open_vscode"])
        }
        withDefaults(["conterm.hiddenPaletteCommands": ["notes"]]) { ud in
            #expect(Preferences().hiddenPaletteCommands
                    == Set(["notes", "open_vscode"]))
            // Unhiding after the one-time seed sticks across launches.
            ud.set(["notes"], forKey: "conterm.hiddenPaletteCommands")
            #expect(Preferences().hiddenPaletteCommands == ["notes"])
        }
    }

    /// An empty stored order means "never customised" — nothing to
    /// splice into, or the default order would turn into a custom one.
    @Test func emptyOrderStaysEmpty() {
        withDefaults([:]) { _ in
            #expect(Preferences().paletteCommandOrder == [])
        }
    }

    // MARK: - Widget-rail seed

    @Test func widgetsSeedFromLegacyStatsFlag() {
        withDefaults([:]) { _ in
            #expect(Preferences().enabledWidgets == ["systemStats"])
        }
        withDefaults(["conterm.showSystemStats": false]) { _ in
            #expect(Preferences().enabledWidgets == [])
        }
    }

    @Test func storedWidgetListBeatsLegacyFlag() {
        withDefaults(["conterm.enabledWidgets": ["clock"],
                      "conterm.showSystemStats": true]) { _ in
            #expect(Preferences().enabledWidgets == ["clock"])
        }
    }

    @Test func retiredAgentStatusWidgetStripped() {
        withDefaults(["conterm.enabledWidgets": ["agentStatus", "clock"]]) { ud in
            #expect(Preferences().enabledWidgets == ["clock"])
            #expect(ud.stringArray(forKey: "conterm.enabledWidgets") == ["clock"])
        }
    }

    // MARK: - Sidebar clamp

    @Test func staleSidebarWidthClampedIntoRange() {
        withDefaults(["conterm.sidebarWidth": 100.0]) { _ in
            #expect(Preferences().sidebarWidth == 260)
        }
        withDefaults(["conterm.sidebarWidth": 500.0]) { _ in
            #expect(Preferences().sidebarWidth == 360)
        }
        withDefaults(["conterm.sidebarWidth": 300.0]) { _ in
            #expect(Preferences().sidebarWidth == 300)
        }
    }
}

/// The chrome scale multiplies hundreds of hardcoded point sizes, so its
/// clamping and rounding are the two things that decide whether the result is
/// usable or blurry.
/// Serialized: these share one process-wide cache and one defaults key, so
/// running them alongside each other has them clearing the scale out from under
/// one another.
@Suite(.serialized) struct ChromeScaleTests {
    private func withScale(_ v: Double?, _ body: () -> Void) {
        let key = "conterm.uiScale"
        let old = UserDefaults.standard.object(forKey: key)
        if let v { UserDefaults.standard.set(v, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        Theme.reloadUIScale()
        body()
        if let old { UserDefaults.standard.set(old, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        Theme.reloadUIScale()
    }

    @Test func unsetMeansUnchanged() {
        withScale(nil) {
            #expect(Theme.uiScale == 1)
            #expect(Theme.ui(11.5) == 11.5)
        }
    }

    @Test func clampsBeyondTheTunedRange() {
        // Chrome is tuned against fixed hit targets and bar heights; a wild
        // scale doesn't shrink the UI, it breaks it.
        withScale(0.2) { #expect(Theme.uiScale == 0.85) }
        withScale(4) { #expect(Theme.uiScale == 1.25) }
    }

    @Test func roundsToAHalfPoint() {
        // A fractional baseline is how a naive UI scale ends up looking cheap.
        withScale(0.9) {
            #expect(Theme.ui(11) == 10.0)      // 9.9 → 10.0
            #expect(Theme.ui(13.5) == 12.0)    // 12.15 → 12.0
        }
    }

    @Test func sharedChromeMetricsFollowTheScale() {
        // The bar height and the pill corner are read by layout code that never
        // sees a font size, so they have to scale at their source or the chrome
        // shrinks around bars that don't.
        withScale(nil) {
            #expect(Theme.tabBarHeight == 42)
            #expect(Theme.pillCorner == 18)
        }
        withScale(1.25) {
            #expect(Theme.tabBarHeight == 52.5)
            #expect(Theme.pillCorner == 22.5)
        }
    }

    @Test func scalesUpAndDownFromTheSameSource() {
        withScale(1.25) { #expect(Theme.ui(12) == 15) }
        withScale(0.85) { #expect(Theme.ui(20) == 17) }
    }
}
