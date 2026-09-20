import AppKit
import SwiftUI

/// First-run setup. Detects whether the user has a Ghostty / Conterm
/// config, copies/normalises config files, and reports what it did so
/// the wizard can show an honest disclaimer.
@MainActor
enum SetupAssistant {
    private static var home: String { NSHomeDirectory() }
    static var contermDir: String { InstanceState.configDir }
    static var contermConfigPath: String { "\(contermDir)/config" }

    /// Every standard place Ghostty might store its config, in
    /// search order. Conterm's macOS app uses an XDG-style path; the
    /// Ghostty.app bundle stores it under Application Support (with
    /// either `config` or `config.ghostty` depending on version).
    /// See https://ghostty.org/docs/config — "Configuration Files".
    static var ghosttyConfigCandidates: [String] {
        [
            "\(home)/.config/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ]
    }

    /// The first existing Ghostty config, or the XDG path as a
    /// placeholder when none exists (so the wizard / settings can
    /// still show *something*).
    static var ghosttyConfigPath: String {
        ghosttyConfigCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) ?? ghosttyConfigCandidates[0]
    }

    static func ghosttyConfigExists() -> Bool {
        ghosttyConfigCandidates.contains(where: {
            FileManager.default.fileExists(atPath: $0)
        })
    }

    /// True only when the Conterm config has real (uncommented) settings
    /// — the auto-seeded template is all comments, so it doesn't count
    /// as "the user already has a config".
    static func hasCustomContermConfig() -> Bool {
        guard let content = try? String(contentsOfFile: contermConfigPath,
                                        encoding: .utf8) else { return false }
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return true
        }
        return false
    }

    /// Copy the current conterm config to a timestamped `.backup.*`
    /// sibling before any destructive operation, so a mis-click in
    /// the wizard or Settings can never silently destroy hand-edited
    /// settings. Returns the backup path for log/UX use.
    @discardableResult
    static func backupContermConfig() -> String? {
        let path = contermConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let backup = "\(path).backup.\(fmt.string(from: Date()))"
        try? FileManager.default.copyItem(atPath: path, toPath: backup)
        return backup
    }

    /// Copy the user's Ghostty config into the Conterm config. When
    /// `resetBlur` is true, force `background-blur = 0` (Conterm drives
    /// blur from its own Desktop blur slider, so we start it at 0 to
    /// avoid doubling up). Returns whether the blur line was changed or
    /// added, for the disclaimer.
    @discardableResult
    static func importGhosttyConfig(resetBlur: Bool) -> (copied: Bool, blurAdjusted: Bool) {
        guard var content = try? String(contentsOfFile: ghosttyConfigPath,
                                        encoding: .utf8) else {
            return (false, false)
        }
        backupContermConfig()
        var blurAdjusted = false
        if resetBlur {
            var lines = content.components(separatedBy: "\n")
            // Strip ALL existing uncommented background-blur lines so we
            // never leave a duplicate (libghostty uses the last one).
            let before = lines.count
            lines.removeAll { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("#")
                    && t.lowercased().hasPrefix("background-blur")
                    && t.contains("=")
            }
            blurAdjusted = lines.count != before
            lines.append("")
            lines.append("# Set by Conterm setup — Conterm manages window blur")
            lines.append("# via its Desktop blur slider, so this starts at 0.")
            lines.append("background-blur = 0")
            content = lines.joined(separator: "\n")
        }
        try? FileManager.default.createDirectory(atPath: contermDir,
                                                 withIntermediateDirectories: true)
        try? content.write(toFile: contermConfigPath,
                           atomically: true, encoding: .utf8)
        return (true, blurAdjusted)
    }

    /// Write a clean Conterm config seeded with the standard `config-file`
    /// reference removed — used by the wizard's "Start fresh".
    static func writeFreshConfig() {
        backupContermConfig()
        let seed = """
        # Conterm config. Ghostty syntax — full reference at
        # https://ghostty.org/docs/config/reference
        #
        # Conterm reads only THIS file (plus its bundled defaults). To
        # also pull in your Ghostty config, uncomment the next line:
        #
        # config-file = \(ghosttyConfigPath)

        # font-family = "JetBrains Mono"
        # font-size = 13
        # theme = "Tokyo Night"
        # background-opacity = 0.85
        # background-blur = 0
        """
        try? FileManager.default.createDirectory(atPath: contermDir,
                                                 withIntermediateDirectories: true)
        try? seed.write(toFile: contermConfigPath,
                        atomically: true, encoding: .utf8)
    }

    /// Write a conterm config that simply *includes* the user's Ghostty
    /// config via libghostty's `config-file` directive. Edits in either
    /// file then flow through to Conterm on reload — one file to know
    /// about, no copying.
    ///
    /// Non-destructive: if the conterm config already exists with
    /// user content, the include line is prepended (after a backup)
    /// instead of replacing the file. Idempotent — a second call
    /// with the same target is a no-op.
    static func linkGhosttyConfig() {
        let path = contermConfigPath
        let target = ghosttyConfigPath
        try? FileManager.default.createDirectory(atPath: contermDir,
                                                 withIntermediateDirectories: true)

        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           !existing.isEmpty {
            // Already linked? Don't double-add.
            if isLinkedToGhostty() { return }
            backupContermConfig()
            let header = """
            # Linked to your Ghostty config — pulls in every line of
            # \(target). Overrides below stay Conterm-only.
            config-file = \(target)


            """
            try? (header + existing).write(toFile: path,
                                           atomically: true, encoding: .utf8)
            return
        }
        let seed = """
        # Conterm config — linked to your Ghostty config.
        #
        # The include below pulls in every line of
        # \(target)
        # so both apps stay in sync. Anything you write under the
        # include OVERRIDES the Ghostty value for Conterm only.

        config-file = \(target)

        # Conterm-only overrides go here. For example:
        # font-size = 14
        # background-blur = 0
        """
        try? seed.write(toFile: path,
                        atomically: true, encoding: .utf8)
    }

    /// Whether the current conterm config delegates to Ghostty via a
    /// `config-file = ...ghostty/config` include line.
    static func isLinkedToGhostty() -> Bool {
        guard let content = try? String(contentsOfFile: contermConfigPath,
                                        encoding: .utf8) else { return false }
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("config-file"),
               line.contains("ghostty/config") {
                return true
            }
        }
        return false
    }

    /// One-time migration: if the user already had things working via
    /// the old "Conterm auto-loads Ghostty config" behaviour, and they
    /// don't yet have an include line, prepend one so the switch to
    /// single-source loading doesn't lose their Ghostty settings.
    static func migrateToSingleSource() {
        guard ghosttyConfigExists(), !isLinkedToGhostty() else { return }
        let header = """
        # Auto-added by Conterm migration: keeps your Ghostty config
        # active under the new single-file model. Delete this line if
        # you don't want to inherit Ghostty's settings.
        config-file = \(ghosttyConfigPath)


        """
        let current = (try? String(contentsOfFile: contermConfigPath,
                                   encoding: .utf8)) ?? ""
        try? FileManager.default.createDirectory(atPath: contermDir,
                                                 withIntermediateDirectories: true)
        try? (header + current).write(toFile: contermConfigPath,
                                       atomically: true, encoding: .utf8)
    }
}

/// First-run welcome + setup wizard. Shown once (after the launch
/// animation) until completed or skipped. Lets the user pick how their
/// config is sourced and how the app looks and sounds, then writes the
/// choices through Preferences + a config reload.
///
/// An arrival, so it gets the full `LiquidDrop` (via `BriefingCard`) and
/// sequences the drop itself: mount closed, open, reveal the content once
/// the body has formed; on finish hide the content, let the drop collapse,
/// then hand back to the owner.
struct WelcomeWizard: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var state: AppState

    var onFinish: () -> Void

    private typealias ConfigChoice = SetupWizardDraft.ConfigChoice

    /// Ordered set of wizard steps the user moves through with Back /
    /// Next. `welcome` and `ready` bookend the substantive choices.
    private enum Step: Int, CaseIterable, Comparable {
        case welcome, config, look, tabs, widgets, sound, ready
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .config:  "Configuration"
            case .look:    "Look"
            case .tabs:    "Tabs"
            case .widgets: "Widgets"
            case .sound:   "Sound"
            case .ready:   "Ready"
            }
        }
    }

    // Window mode, solid panes, tab orientation, light/dark and the
    // interface style bind straight to prefs: the window repaints beneath
    // the wizard, so each pick previews itself. Skip is offered only on the
    // welcome step, before any live-bound control is reachable, so none of
    // them needs a restore path. The step and the deferred picks live in
    // the shared draft: picking Classic swaps this wizard for
    // `ClassicWelcomeWizard` on the spot, and the run carries across.
    @ObservedObject private var draft = SetupWizardDraft.shared

    private var step: Step {
        get { Step(rawValue: draft.step) ?? .welcome }
        nonmutating set { draft.step = newValue.rawValue }
    }

    private var configChoice: ConfigChoice {
        get { draft.configChoice }
        nonmutating set { draft.configChoice = newValue }
    }
    /// Drop phases (see `BriefingPresenter`, which this mirrors).
    @State private var dropOpen = false
    @State private var revealed = false
    /// `onAppear` can fire more than once for an overlay slot; the open
    /// sequence and the prefs read must run once.
    @State private var started = false

    /// White-on-transparent wordmark loaded as a template so the
    /// foreground gradient tints it (the same way the previous
    /// Text("Conterm") was styled).
    private static let textLogo: NSImage = {
        if let url = Bundle.main.url(forResource: "text-logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        return NSImage(size: .zero)
    }()

    private var ghosttyPresent: Bool { SetupAssistant.ghosttyConfigExists() }
    private var hasContermConfig: Bool { SetupAssistant.hasCustomContermConfig() }

    /// The window's height, so a step with a long list can scroll inside
    /// the card instead of pushing it past the edges of a short window.
    @State private var availableHeight: CGFloat = 800
    /// Height of the card's fixed chrome — masthead and footer, dividers
    /// included — measured rather than assumed, so a step's scroll
    /// viewport keeps matching the card after either one changes.
    @State private var chromeHeight: CGFloat = 200
    /// The current step's own content height, measured inside the scroll
    /// view (scroll content is laid out at its ideal height, so this is
    /// independent of the viewport it feeds).
    @State private var bodyHeight: CGFloat = 260

    /// Room left around the card so it never runs into the window edges
    /// or under the title bar.
    private static let cardMargin: CGFloat = 72
    /// Matches the dim `BriefingCard`'s drop assumes under it, so the
    /// refracted terminal is as bright as the terminal around the card.
    private static let sceneDim: Double = 0.25
    /// Floor for the step viewport: below this the card is unusable, so a
    /// very short window scrolls rather than shrinking further.
    private static let minStepHeight: CGFloat = 140

    /// Height of the step's scroll viewport: the step's own content,
    /// capped by what the window leaves once the chrome and margins are
    /// out. A step that fits shows whole and doesn't scroll.
    private var stepViewportHeight: CGFloat {
        let room = availableHeight - chromeHeight - Self.cardMargin
        return max(Self.minStepHeight, min(bodyHeight, room))
    }

    var body: some View {
        ZStack {
            // Dim scrim over the app.
            Color.black.opacity(Self.sceneDim)
                .ignoresSafeArea()
                .opacity(dropOpen ? 1 : 0)
                .animation(.easeOut(duration: 0.30), value: dropOpen)
                .onTapGesture {} // swallow taps; force a choice/skip
                .background(GeometryReader { g in
                    Color.clear.preference(key: WizardHeightKey.self, value: g.size.height)
                })
                .onPreferenceChange(WizardHeightKey.self) { h in
                    if h > 0, abs(h - availableHeight) > 1 { availableHeight = h }
                }

            BriefingCard(width: 620) { card }
                // Pin the card to its own content height. Without
                // this SwiftUI hands the card the full ZStack height
                // and the VStack interior stretches to fill (then the
                // drop spans top-to-bottom of the window).
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.liquidDropOpen, dropOpen)
                .environment(\.liquidRevealed, revealed)
        }
        .onAppear {
            guard !started else { return }
            started = true
            // Mounted closed for one pass so the drop has a state to grow
            // from; content follows once the body has formed.
            DispatchQueue.main.async { dropOpen = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { revealed = true }
            draft.seed(from: prefs, ghosttyPresent: ghosttyPresent)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .measuringHeight(WizardChromeKey.self)
            // Every step scrolls, not just the long ones: the card is
            // pinned to its content height, so anything that doesn't fit
            // the viewport would otherwise render past the window.
            ScrollView(.vertical) {
                stepBody
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                    .padding(.horizontal, Drop.inset)
                    .padding(.vertical, 6)
                    .measuringHeight(WizardBodyHeightKey.self)
            }
            .frame(height: stepViewportHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            footer
                .measuringHeight(WizardChromeKey.self)
        }
        .toggleStyle(.drop)
        .onPreferenceChange(WizardChromeKey.self) { h in
            if h > 0, abs(h - chromeHeight) > 1 { chromeHeight = h }
        }
        .onPreferenceChange(WizardBodyHeightKey.self) { h in
            if h > 0, abs(h - bodyHeight) > 1 { bodyHeight = h }
        }
    }

    /// Masthead: where you are, the step's name set large and rolled in on
    /// every step change, and the wordmark as a quiet signature.
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                DropEyebrow("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .contentTransition(.numericText())
                    .animation(Theme.Spring.snappy, value: step)
                    .rollUp(delay: 0)
                RollUpText(step.title, font: Drop.title(), color: Theme.textPrimary,
                           startDelay: 0.05, step: 0.028)
                    .id(step)
            }
            Spacer(minLength: 12)
            Image(nsImage: Self.textLogo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 20)
                // `Theme.textSecondary` is dynamic, so the wordmark reads
                // on the dark and the light tint alike.
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
                .rollUp(delay: 0.10)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Drop.inset)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }

    // MARK: - Step body + transitions

    /// The current step's content. A step change is a swap inside the
    /// drop: the new step rises in as the old one dissolves.
    @ViewBuilder
    private var stepBody: some View {
        Group {
            switch step {
            case .welcome: welcomeStep
            case .config:  configStep
            case .look:    lookStep
            case .tabs:    tabsStep
            case .widgets: widgetsStep
            case .sound:   soundStep
            case .ready:   readyStep
            }
        }
        .id(step)
        .transition(.liquidSwap)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conterm is a Ghostty-powered terminal with Liquid Glass chrome, tab groups, and a command palette.")
                .font(Drop.display(15, .regular))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .rollUp(delay: 0.12, blurs: false)
            Text("Config source, look, tabs, widgets, sound — then you're in.")
                .font(Drop.display(12.5, .regular))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .rollUp(delay: 0.20, blurs: false)
        }
    }

    private var configStep: some View {
        VStack(alignment: .leading, spacing: 14) { configSection }
    }

    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            interfaceSection
                .padding(.bottom, 6)

            sectionTitle("Tint", systemImage: "paintpalette.fill")
            // Bound directly to prefs so the whole window flips
            // light/dark live as the user clicks — they can see
            // what they're picking instead of guessing.
            Picker("", selection: $prefs.lightGlass.withSound()) {
                Text("Dark").tag(false)
                Text("Light").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            glassSection
        }
    }

    private var tabsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Tab bar", systemImage: "rectangle.lefthalf.inset.filled")
            // Live: switching previews the tab bar immediately.
            Picker("", selection: $prefs.tabOrientation.withSound()) {
                Text("Top").tag(Preferences.TabOrientation.horizontal)
                Text("Sidebar").tag(Preferences.TabOrientation.vertical)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            caption("Sidebar mode puts tabs in a resizable left panel.")

            sectionTitle("Launch animation", systemImage: "sparkles")
                .padding(.top, 6)
            DropWell(padding: 14) {
                settingToggle("Play the wordmark intro at startup",
                              "Off skips it after the first launch.",
                              isOn: $draft.launchAnim.withSound())
            }
        }
    }

    private var widgetsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Tab-bar widgets", systemImage: "square.grid.2x2.fill")
            caption("Glanceable pills in the tab bar. Reorder and fine-tune them anytime in Settings ▸ Widgets.")
            DropWell {
                ForEach(Array(WidgetKind.allCases.enumerated()), id: \.element.id) { i, kind in
                    DropRow(index: i) { widgetPickRow(kind) }
                }
            }
        }
    }

    private func widgetPickRow(_ kind: WidgetKind) -> some View {
        // Full-width row with the switch pushed to a uniform trailing edge,
        // so icons/titles align on the left and toggles align on the right
        // regardless of subtitle length.
        HStack(spacing: 12) {
            Group {
                if kind.icon == TerraformMark.iconName {
                    TerraformGlyph(color: Theme.textSecondary, size: 13)
                } else {
                    Image(systemName: kind.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(Drop.display(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(kind.subtitle)
                    .font(Drop.display(11, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { draft.widgets.contains(kind.rawValue) },
                set: { on in
                    if on { draft.widgets.insert(kind.rawValue) }
                    else  { draft.widgets.remove(kind.rawValue) }
                    SoundEffects.shared.play(.toggle)
                }
            ))
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var soundStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Sound effects", systemImage: "speaker.wave.2.fill")
            DropWell(padding: 14) {
                settingToggle("Subtle clicks on panes, tabs, and the palette",
                              "Quick synthesised tones — never speech, never loud.",
                              isOn: $draft.soundEffects.withSound())
            }

            // Preview chips — one per sound family. Each fires
            // through the engine with the preference gate
            // temporarily forced on so the demo is audible
            // regardless of the toggle's current state.
            HStack(spacing: 8) {
                soundPreviewButton("Palette", systemImage: "command",
                                   effect: .paletteOpen)
                soundPreviewButton("Confirm", systemImage: "return",
                                   effect: .paletteConfirm)
                soundPreviewButton("Pane",    systemImage: "rectangle.split.2x1",
                                   effect: .paneAdd)
                soundPreviewButton("Tab",     systemImage: "rectangle.stack",
                                   effect: .tabAdd)
            }
            .opacity(draft.soundEffects ? 1 : 0.4)
        }
    }

    /// Renders one preview chip in `soundStep`. Plays the chosen
    /// effect once with the SFX preference forced on for the
    /// duration of the playback, so the demo works even while the
    /// step's main toggle sits in the off position.
    private func soundPreviewButton(
        _ title: String,
        systemImage: String,
        effect: SoundEffects.Effect
    ) -> some View {
        Button {
            // Temporarily override the SFX preference, play, then
            // restore the prior value. Avoids threading a "force"
            // parameter through the engine just for this preview.
            let was = InstanceState.defaults.object(forKey: "conterm.soundEffects") as? Bool
            InstanceState.defaults.set(true, forKey: "conterm.soundEffects")
            SoundEffects.shared.play(effect)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let was = was {
                    InstanceState.defaults.set(was, forKey: "conterm.soundEffects")
                } else {
                    InstanceState.defaults.removeObject(forKey: "conterm.soundEffects")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
            }
        }
        .buttonStyle(.drop)
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Shortcuts to know", systemImage: "keyboard")
            DropWell {
                DropRow(index: 0) { shortcutRow("⌘K", "Command palette") }
                DropRow(index: 1) { shortcutRow("⌘D · ⌘⇧D", "Split right · split down") }
                DropRow(index: 2) { shortcutRow("⌥1…9", "Jump to pane") }
            }
        }
    }

    private func shortcutRow(_ keys: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(Drop.mono(12, .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 120, alignment: .leading)
            Text(what)
                .font(Drop.display(12.5, .regular))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Config

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Config source", systemImage: "doc.text")
            if hasContermConfig {
                DropChip(text: "A Conterm config already exists — pick one to overwrite, or go back and Skip.",
                         symbol: "exclamationmark", tint: Drop.warn)
            }
            if ghosttyPresent {
                choiceRow(.useDirectly,
                          title: "Use my Ghostty config",
                          badge: "Recommended",
                          subtitle: "Conterm's config includes ~/.config/ghostty/config. Edits in either file apply.")
                choiceRow(.importGhostty,
                          title: "Copy my Ghostty config",
                          badge: nil,
                          subtitle: "Make an editable copy in Conterm. Ghostty changes won't apply after.")
            }
            choiceRow(.fresh,
                      title: "Start fresh",
                      badge: nil,
                      subtitle: ghosttyPresent
                        ? "Empty Conterm config. Ghostty config is not read."
                        : "No Ghostty config found. Conterm boots on its clean built-in defaults.")
        }
    }

    private func choiceRow(_ choice: ConfigChoice, title: String,
                           badge: String?, subtitle: String) -> some View {
        let selected = configChoice == choice
        return Button {
            withAnimation(Theme.Spring.snappy) { configChoice = choice }
            if !selected { SoundEffects.shared.play(.toggle) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(Drop.display(13, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let badge {
                            DropChip(text: badge, tint: Theme.textPrimary)
                        }
                    }
                    Text(subtitle)
                        .font(Drop.display(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                    .fill(Theme.selectionFill.opacity(selected ? 1 : 0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Drop.sheen) : AnyShapeStyle(Theme.stroke),
                                  lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Interface style

    /// Liquid Drop or Classic, live: picking Classic hands the rest of the
    /// run to `ClassicWelcomeWizard` (see `SetupWizardDraft`).
    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Interface", systemImage: "drop.fill")
            HStack(alignment: .top, spacing: 10) {
                styleChoice(.liquidDrop, title: "Liquid Drop",
                            subtitle: "Glass that bends the terminal behind it; panels arrive as drops.")
                styleChoice(.classic, title: "Classic",
                            subtitle: "Flat cards and system materials.")
            }
        }
    }

    private func styleChoice(_ style: Preferences.InterfaceStyle, title: String,
                             subtitle: String) -> some View {
        let selected = prefs.interfaceStyle == style
        return Button {
            guard !selected else { return }
            SoundEffects.shared.play(.toggle)
            prefs.interfaceStyle = style
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    Text(title)
                        .font(Drop.display(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text(subtitle)
                    .font(Drop.display(11, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                    .fill(Theme.selectionFill.opacity(selected ? 1 : 0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Drop.sheen) : AnyShapeStyle(Theme.stroke),
                                  lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Glass

    private var glassSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Window", systemImage: "macwindow")

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $prefs.glassMode.withSound()) {
                    Text("Glass").tag(Preferences.GlassMode.glass)
                    Text("Blur").tag(Preferences.GlassMode.blur)
                    Text("Solid").tag(Preferences.GlassMode.solid)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // The caption tracks the selection so each mode explains
                // itself; Glass also carries its cost note.
                caption(Self.modeCaption(prefs.glassMode))
                if prefs.glassMode == .glass { GlassCostNote() }
            }

            DropWell(padding: 14) {
                VStack(alignment: .leading, spacing: 16) {
                    settingToggle("Solid panes",
                                  prefs.glassMode == .solid
                                    ? "The Solid window is fully opaque, so panes always ride on it — pick Glass or Blur for see-through panes."
                                    : "Each pane rides on solid black, framing the terminal cells against the window. Turn off for see-through panes that let the window material show through the cells.",
                                  isOn: $prefs.opaquePanes.withSound())
                        .disabled(prefs.glassMode == .solid)
                    settingToggle("Efficient rendering",
                                  "Redraw only when the terminal changes, not every screen refresh. Fast scrolling may tear slightly.",
                                  isOn: $draft.efficientRendering.withSound())
                }
            }
        }
    }

    /// Title and explanation on the left, switch pinned to the trailing
    /// edge, so a column of them aligns whatever the text lengths.
    private func settingToggle(_ title: String, _ subtitle: String,
                               isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Drop.display(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Drop.display(11, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Drop.display(11.5, .regular))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func modeCaption(_ mode: Preferences.GlassMode) -> String {
        switch mode {
        case .glass:
            return "One sheet of Liquid Glass over the desktop; the panes sit on it as opaque tiles. Depth comes from the real backdrop refracting through."
        case .blur:
            return "The classic frosted material — the desktop diffused into a soft, even wash behind the window."
        case .solid:
            return "A fully opaque window. Maximum contrast, nothing showing through."
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Back on every step except the first.
                if step != .welcome {
                    DropButton(title: "Back", symbol: "chevron.left") { goBack() }
                } else {
                    // Skip is only meaningful at the very start.
                    DropButton(title: "Skip") {
                        SoundEffects.shared.play(.click)
                        finish(applyConfig: false)
                    }
                }
                Spacer()
                stepDots
                Spacer()
                DropButton(title: step == .ready ? "Get Started" : "Next",
                           symbol: step == .ready ? "checkmark" : nil,
                           prominent: true) {
                    if step == .ready {
                        // Final commit gets `.click` — distinct
                        // from the per-step `.toggle` so the
                        // "you're done" event reads as heavier.
                        SoundEffects.shared.play(.click)
                        finish(applyConfig: true)
                    } else {
                        goNext()
                    }
                }
            }
            Text("You can change anything later in Settings.")
                .font(Drop.mono(9.5))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, Drop.inset)
        .padding(.top, 18)
        .padding(.bottom, 30)
        .rollUp(delay: 0.22, blurs: false)
    }

    /// Step-progress dots in the footer center.
    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Theme.textPrimary
                          : (s < step ? Theme.textPrimary.opacity(0.45)
                                      : Theme.strokeStrong))
                    .frame(width: s == step ? 16 : 6, height: 6)
                    .animation(Theme.Spring.snappy, value: step)
            }
        }
    }

    private func goNext() {
        withAnimation(Theme.Spring.soft) {
            if let next = Step(rawValue: step.rawValue + 1) { step = next }
        }
        SoundEffects.shared.play(.toggle)
    }

    private func goBack() {
        withAnimation(Theme.Spring.soft) {
            if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
        }
        SoundEffects.shared.play(.toggle)
    }

    /// Sub-heading inside a step. The step's own name is in the masthead,
    /// so these only label the groups beneath it.
    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            DropEyebrow(text)
        }
    }

    // MARK: - Actions

    private func finish(applyConfig: Bool) {
        if applyConfig {
            prefs.lowPowerRendering     = draft.efficientRendering
            // glassMode, opaquePanes, tabOrientation, and lightGlass are
            // already current — those controls write straight to prefs
            // for live preview.
            prefs.launchAnimationEnabled = draft.launchAnim
            prefs.soundEffectsEnabled   = draft.soundEffects
            // Enabled widgets in canonical order; preserve any prior order
            // for kinds that were already enabled.
            let priorOrder = prefs.enabledWidgets.filter { draft.widgets.contains($0) }
            let added = WidgetKind.allCases
                .map(\.rawValue)
                .filter { draft.widgets.contains($0) && !priorOrder.contains($0) }
            prefs.enabledWidgets = priorOrder + added
            prefs.useDefaultConfig = false

            // Only touch the config file when the user doesn't already
            // have hand-edited content. The `link` action is the one
            // exception — it's non-destructive (just prepends the
            // `config-file` include line). `copy` and `fresh` both
            // overwrite, so they're skipped to protect the user's edits.
            let hasCustom = SetupAssistant.hasCustomContermConfig()
            switch configChoice {
            case .importGhostty:
                if !hasCustom { SetupAssistant.importGhosttyConfig(resetBlur: true) }
            case .useDirectly:
                SetupAssistant.linkGhosttyConfig()
            case .fresh:
                if !hasCustom { SetupAssistant.writeFreshConfig() }
            }
            Ghostty.App.shared?.reloadConfig()
            prefs.refreshPaneBlurFromConfig()
        }
        prefs.hasCompletedSetup = true
        // Content out, drop collapses, then the owner unmounts.
        revealed = false
        dropOpen = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            withAnimation(.easeOut(duration: 0.15)) { onFinish() }
            // Once the card is gone, so the step doesn't visibly rewind.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { draft.reset() }
        }
    }
}

/// The wizard overlay's height, read so long steps can size their scroll
/// area to the window.
private struct WizardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The card's fixed chrome. Two contributors — masthead and footer — so
/// this one sums rather than taking the larger.
private struct WizardChromeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// The current step's content height. Two steps overlap for the length of
/// a step transition; the taller one sizes the card through it.
private struct WizardBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Reports this view's laid-out height through `key`.
    func measuringHeight<K: PreferenceKey>(_ key: K.Type) -> some View
    where K.Value == CGFloat {
        background(GeometryReader { g in
            Color.clear.preference(key: key, value: g.size.height)
        })
    }
}
