import AppKit
import SwiftUI

/// One run of the welcome: its steps, where the run is, and every pick.
/// Picks are held until Finish and written in one pass, so Back, Skip and
/// quitting mid-run leave the app as it was. Owned by the window's
/// AppState while the welcome is up; both interface styles show the same
/// stage over it.
@MainActor
final class WelcomeFlow: ObservableObject {
    enum Step: Int, CaseIterable {
        case hero, config, look, layout, keys, finish
    }

    enum ConfigChoice: String, CaseIterable {
        /// Leave the Conterm config as it is.
        case keep
        /// Include the Ghostty config from the Conterm config.
        case link
        /// Copy the Ghostty config into the Conterm config.
        case copy
        /// A commented template; the Ghostty config isn't read.
        case fresh
    }

    /// What the machine already has, read once when the run starts.
    struct Found: Equatable {
        var ghosttyConfig: String?
        var ghostty = SetupAssistant.GhosttySummary()
        /// The Conterm config has uncommented lines of its own.
        var customConterm = false
        /// The Conterm config already includes the Ghostty config.
        var linked = false
    }

    struct Picks: Equatable {
        var config: ConfigChoice = .fresh
        var style: Preferences.InterfaceStyle = .liquidDrop
        var lightGlass = false
        var glassMode: Preferences.GlassMode = .glass
        var opaquePanes = false
        var efficientRendering = true
        /// Classic only.
        var glassPanels = false
        var tabOrientation: Preferences.TabOrientation = .horizontal
        /// `offeredWidgets` kinds (raw values) switched on.
        var widgets: Set<String> = []
        var sounds = true
        var launchAnimation = true
    }

    enum Phase: Equatable {
        case running
        /// Picks are written; the stage plays its hand-over.
        case finishing
        /// Skipped or closed; nothing was written but completion.
        case leaving
    }

    /// The widgets the Layout step offers. The rest keep whatever state
    /// they have and stay in Settings.
    static let offeredWidgets: [WidgetKind] = [
        .systemStats, .clock, .battery, .gitStatus, .kubernetes, .containers,
    ]

    let found: Found
    let configOptions: [ConfigChoice]
    let steps: [Step]
    /// Opened from Settings after setup was completed once.
    let isRerun: Bool

    @Published var picks: Picks
    @Published private(set) var step: Step = .hero
    /// +1 while moving forward, -1 moving back; the stage slides with it.
    @Published private(set) var direction = 1
    @Published private(set) var phase: Phase = .running
    /// Set by the stage once the hero's button has arrived. Return is
    /// ignored before then, so a held key can't skip the introduction.
    @Published var heroSettled = false
    /// Counts presses of the button, by click or Return, so the stage
    /// can answer a key press the way it answers a click.
    @Published private(set) var pressTick = 0

    /// Called once the stage has played its exit; the owner unmounts it.
    var onDone: (() -> Void)?
    private weak var prefs: Preferences?

    init(picks: Picks, found: Found, isRerun: Bool, prefs: Preferences? = nil) {
        self.picks = picks
        self.found = found
        self.isRerun = isRerun
        self.prefs = prefs
        let options = Self.configOptions(for: found)
        configOptions = options
        // A step with a single answer asks nothing, so it isn't shown.
        steps = Step.allCases.filter { $0 != .config || options.count > 1 }
        if let start = Self.requestedStartStep(), steps.contains(start), start != .hero {
            step = start
            heroSettled = true
        }
    }

    convenience init(prefs: Preferences) {
        let found = Self.survey()
        var picks = Picks()
        picks.config = Self.defaultConfig(for: found)
        picks.style = prefs.interfaceStyle
        picks.lightGlass = prefs.lightGlass
        picks.glassMode = prefs.glassMode
        picks.opaquePanes = prefs.opaquePanes
        picks.efficientRendering = prefs.lowPowerRendering
        picks.glassPanels = prefs.liquidGlassPanels
        picks.tabOrientation = prefs.tabOrientation
        picks.widgets = Set(prefs.enabledWidgets)
            .intersection(Self.offeredWidgets.map(\.rawValue))
        picks.sounds = prefs.soundEffectsEnabled
        picks.launchAnimation = prefs.launchAnimationEnabled
        self.init(picks: picks, found: found, isRerun: prefs.hasCompletedSetup,
                  prefs: prefs)
    }

    // MARK: - Navigation

    var index: Int { steps.firstIndex(of: step) ?? 0 }
    var isLast: Bool { step == steps.last }
    /// Steps with a progress dash: every step but the hero.
    var charted: [Step] { steps.filter { $0 != .hero } }
    /// The first step after the hero has nothing behind it to return to.
    var canGoBack: Bool { phase == .running && index > 1 }

    /// The button, or Return: on to the next step, or Finish on the last.
    func primary() {
        guard phase == .running else { return }
        if step == .hero && !heroSettled { return }
        pressTick &+= 1
        if isLast { finish() } else { move(to: steps[index + 1]) }
    }

    func back() {
        guard canGoBack else { return }
        move(to: steps[index - 1])
    }

    /// Back to a step already passed. Forward moves go through `primary`,
    /// so no step is passed unseen.
    func jump(to target: Step) {
        guard phase == .running, target != .hero,
              let i = steps.firstIndex(of: target), i < index else { return }
        move(to: target)
    }

    private func move(to target: Step) {
        direction = (steps.firstIndex(of: target) ?? 0) >= index ? 1 : -1
        withAnimation(WelcomeMotion.glide) { step = target }
        if picks.sounds { SoundEffects.shared.play(.toggle) }
    }

    // MARK: - Ending

    /// Writes every pick, then hands the exit to the stage.
    func finish() {
        guard phase == .running else { return }
        if let prefs { Self.apply(picks, isRerun: isRerun, to: prefs) }
        if picks.sounds { SoundEffects.shared.play(.click) }
        phase = .finishing
    }

    /// Leaves without writing a pick. A first run is still marked done, so
    /// the welcome doesn't come back at every launch.
    func skip() {
        guard phase == .running else { return }
        prefs?.hasLaunched = true
        prefs?.hasCompletedSetup = true
        phase = .leaving
    }

    /// The stage has finished its exit.
    func complete() {
        let done = onDone
        onDone = nil
        done?()
    }

    // MARK: - Rules

    static func survey() -> Found {
        var found = Found()
        if SetupAssistant.ghosttyConfigExists() {
            let path = SetupAssistant.ghosttyConfigPath
            found.ghosttyConfig = path
            found.ghostty = SetupAssistant.ghosttySummary(at: path)
        }
        found.customConterm = SetupAssistant.hasCustomContermConfig()
        found.linked = SetupAssistant.isLinkedToGhostty()
        return found
    }

    /// The config answers that fit what's on disk. A Conterm config with
    /// lines of its own is never replaced, so Copy and Start fresh aren't
    /// offered over one; linking only adds an include above it.
    static func configOptions(for found: Found) -> [ConfigChoice] {
        let ghostty = found.ghosttyConfig != nil
        var options: [ConfigChoice] = []
        if found.customConterm || found.linked { options.append(.keep) }
        if ghostty && !found.linked { options.append(.link) }
        if ghostty && !found.customConterm { options.append(.copy) }
        if !found.customConterm { options.append(.fresh) }
        return options
    }

    static func defaultConfig(for found: Found) -> ConfigChoice {
        if found.customConterm || found.linked { return .keep }
        return found.ghosttyConfig != nil ? .link : .fresh
    }

    /// The enabled widgets after a run: kinds outside the offered list keep
    /// their state and place, offered kinds follow the picks, and a newly
    /// picked kind joins at the end in the catalog's order.
    static func mergedWidgets(current: [String], picked: Set<String>) -> [String] {
        let offered = Set(offeredWidgets.map(\.rawValue))
        let kept = current.filter { !offered.contains($0) || picked.contains($0) }
        let added = WidgetKind.allCases.map(\.rawValue)
            .filter { picked.contains($0) && !kept.contains($0) }
        return kept + added
    }

    static func apply(_ p: Picks, isRerun: Bool, to prefs: Preferences) {
        prefs.interfaceStyle = p.style
        prefs.lightGlass = p.lightGlass
        prefs.glassMode = p.glassMode
        prefs.opaquePanes = p.opaquePanes
        prefs.lowPowerRendering = p.efficientRendering
        if p.style == .classic { prefs.liquidGlassPanels = p.glassPanels }
        prefs.tabOrientation = p.tabOrientation
        prefs.enabledWidgets = mergedWidgets(current: prefs.enabledWidgets, picked: p.widgets)
        prefs.soundEffectsEnabled = p.sounds
        prefs.launchAnimationEnabled = p.launchAnimation
        // A first run leaves safe mode; a later run leaves it alone unless
        // it rewrites the config.
        if !isRerun || p.config != .keep { prefs.useDefaultConfig = false }
        prefs.hasLaunched = true
        prefs.hasCompletedSetup = true

        guard p.config != .keep else { return }
        switch p.config {
        case .keep:  break
        case .link:  SetupAssistant.linkGhosttyConfig()
        case .copy:  SetupAssistant.importGhosttyConfig(resetBlur: true)
        case .fresh: SetupAssistant.writeFreshConfig()
        }
        (NSApp.delegate as? AppDelegate)?.reloadConfigAndReapplyBlur()
        prefs.refreshPaneBlurFromConfig()
    }

    /// `CONTERM_WELCOME_STEP=<step>` opens a run straight on that step, for
    /// working on one step without clicking through the others.
    private static func requestedStartStep() -> Step? {
        guard let raw = ProcessInfo.processInfo.environment["CONTERM_WELCOME_STEP"]
        else { return nil }
        return Step.allCases.first { "\($0)" == raw.lowercased() }
    }
}
