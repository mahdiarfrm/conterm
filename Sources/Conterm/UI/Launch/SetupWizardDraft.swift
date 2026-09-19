import SwiftUI

/// The setup wizard's answers so far. The wizard exists once per interface
/// style, and its Look step switches the style live — which swaps one
/// wizard for the other mid-run. Held here rather than in either view's
/// `@State`, the step and every pick carry across that swap instead of
/// restarting at Welcome with defaults.
@MainActor
final class SetupWizardDraft: ObservableObject {
    static let shared = SetupWizardDraft()

    enum ConfigChoice: Hashable { case importGhostty, useDirectly, fresh }

    /// Index into the wizards' (identical) step order.
    @Published var step = 0
    @Published var configChoice: ConfigChoice = .useDirectly
    // Picks that change nothing visible while the wizard is up; applied on
    // Get Started. Everything else binds straight to `Preferences`.
    /// Classic only.
    @Published var glassPanels = false
    @Published var efficientRendering = true
    @Published var launchAnim = true
    @Published var soundEffects = true
    /// Widget kinds (`WidgetKind` raw values) wanted in the tab bar.
    @Published var widgets: Set<String> = []

    private var seeded = false

    /// Starts the picks from the standing preferences — once per run, so a
    /// wizard mounting after a style swap doesn't overwrite what was picked.
    func seed(from prefs: Preferences, ghosttyPresent: Bool) {
        guard !seeded else { return }
        seeded = true
        // If Ghostty isn't installed, importing isn't an option — default
        // to a clean start.
        if !ghosttyPresent { configChoice = .fresh }
        glassPanels = prefs.liquidGlassPanels
        efficientRendering = prefs.lowPowerRendering
        launchAnim = prefs.launchAnimationEnabled
        soundEffects = prefs.soundEffectsEnabled
        widgets = Set(prefs.enabledWidgets)
    }

    /// Back to a blank run, for the next time the wizard is shown.
    func reset() {
        seeded = false
        step = 0
        configChoice = .useDirectly
    }
}
