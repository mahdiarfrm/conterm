import AppKit
import SwiftUI

/// First-run setup. Detects whether the user has a Ghostty / Conterm
/// config, copies/normalises config files, and reports what it did so
/// the wizard can show an honest disclaimer.
@MainActor
enum SetupAssistant {
    private static var home: String { NSHomeDirectory() }
    static var contermDir: String { "\(home)/.config/conterm" }
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
/// config is sourced and whether modal overlays use frosted Liquid
/// Glass, then writes the choices through Preferences + a config reload.
struct WelcomeWizard: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var state: AppState

    var onFinish: () -> Void

    private enum ConfigChoice: Hashable { case importGhostty, useDirectly, fresh }

    /// Ordered set of wizard steps the user moves through with Back /
    /// Next. `welcome` and `ready` bookend the substantive choices.
    private enum Step: Int, CaseIterable, Comparable {
        case welcome, config, look, tabs, widgets, sound, ready
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        var headline: String {
            switch self {
            case .welcome: "WELCOME"
            case .config:  "CONFIG"
            case .look:    "LOOK"
            case .tabs:    "TABS"
            case .widgets: "WIDGETS"
            case .sound:   "SOUND"
            case .ready:   "READY"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var navDirection: Int = 1   // +1 forward, -1 back

    @State private var configChoice: ConfigChoice = .useDirectly
    @State private var pickedGlassMode: Preferences.GlassMode = .glass
    @State private var pickedOpaquePanes = true
    @State private var pickedGlassPanels = false
    @State private var pickedEfficientRendering = true
    // Tab orientation + light/dark are now bound directly to prefs
    // for live preview, so they have no local @State mirror. The two
    // remaining picks below are applied only on Get Started.
    @State private var pickedLaunchAnim = true
    @State private var pickedSoundEffects = true
    /// Widget kinds (WidgetKind rawValues) the user wants in the tab bar.
    @State private var pickedWidgets: Set<String> = []
    @State private var appeared = false

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

    var body: some View {
        ZStack {
            // Dim scrim over the app.
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {} // swallow taps; force a choice/skip

            card
                .frame(width: 540)
                // Pin the card to its own content height. Without
                // this SwiftUI hands the card the full ZStack height
                // and the VStack interior stretches to fill (then the
                // backdrop spans top-to-bottom of the window).
                .fixedSize(horizontal: false, vertical: true)
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
                .blur(radius: appeared ? 0 : 12)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                appeared = true
            }
            // If Ghostty isn't installed, importing isn't an option —
            // default to a clean start.
            if !ghosttyPresent { configChoice = .fresh }
            pickedGlassMode = prefs.glassMode
            pickedOpaquePanes = prefs.opaquePanes
            pickedGlassPanels = prefs.liquidGlassPanels
            pickedEfficientRendering = prefs.lowPowerRendering
            pickedLaunchAnim    = prefs.launchAnimationEnabled
            pickedSoundEffects  = prefs.soundEffectsEnabled
            pickedWidgets       = Set(prefs.enabledWidgets)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            stepBody
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            Divider().opacity(0.25)
            footer
        }
        .background(
            OverlayPanelBackground(cornerRadius: 24)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Wet-glass top-edge highlight + an accent glow rim.
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .shadow(color: Theme.accent.opacity(0.18), radius: 40, y: 0)
        .shadow(color: .black.opacity(0.55), radius: 44, y: 20)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: Self.textLogo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 38)
                // `Theme.textPrimary` is dynamic, so the wordmark
                // shows white-on-dark and inverts to black-on-light
                // automatically.
                .foregroundStyle(
                    LinearGradient(colors: [Theme.textPrimary,
                                            Theme.textPrimary.opacity(0.72)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: Theme.accent.opacity(0.35), radius: 18)
                .shadow(color: Theme.textPrimary.opacity(0.15), radius: 24)
            Text("STEP \(step.rawValue + 1) OF \(Step.allCases.count) — \(step.headline)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.numericText())
                .animation(Theme.Spring.snappy, value: step)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .padding(.horizontal, 20)
    }

    // MARK: - Step body + transitions

    /// The current step's content, with a directional slide transition
    /// driven by `navDirection` so Next reads as moving forward and
    /// Back as moving backward.
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
        .transition(.asymmetric(
            insertion: .move(edge: navDirection > 0 ? .trailing : .leading)
                .combined(with: .opacity),
            removal:   .move(edge: navDirection > 0 ? .leading : .trailing)
                .combined(with: .opacity)
        ))
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Welcome", systemImage: "sparkles")
            Text("Conterm is a Ghostty-powered terminal with Liquid Glass chrome, tab groups, and a command palette.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Six short steps: config source, look, tabs, widgets, sound, then you're in.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var configStep: some View {
        VStack(alignment: .leading, spacing: 14) { configSection }
    }

    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 18) {
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
            Text("Sidebar mode puts tabs in a resizable left panel.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)

            sectionTitle("Launch animation", systemImage: "sparkles")
            Toggle(isOn: $pickedLaunchAnim.withSound()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play the wordmark intro at startup")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Off skips it after the first launch.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }

    private var widgetsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Tab-bar widgets", systemImage: "square.grid.2x2.fill")
            Text("Glanceable pills in the tab bar. Reorder and fine-tune them anytime in Settings ▸ Widgets.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(WidgetKind.allCases) { widgetPickRow($0) }
            }
        }
    }

    private func widgetPickRow(_ kind: WidgetKind) -> some View {
        // Full-width row with the switch pushed to a uniform trailing edge,
        // so icons/titles align on the left and toggles align on the right
        // regardless of subtitle length.
        HStack(spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(kind.subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { pickedWidgets.contains(kind.rawValue) },
                set: { on in
                    if on { pickedWidgets.insert(kind.rawValue) }
                    else  { pickedWidgets.remove(kind.rawValue) }
                    SoundEffects.shared.play(.toggle)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var soundStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Sound effects", systemImage: "speaker.wave.2.fill")
            Toggle(isOn: $pickedSoundEffects.withSound()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subtle clicks on panes, tabs, and the palette")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Quick synthesised tones — never speech, never loud.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

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
            .opacity(pickedSoundEffects ? 1 : 0.4)
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
            let was = UserDefaults.standard.object(forKey: "conterm.soundEffects") as? Bool
            UserDefaults.standard.set(true, forKey: "conterm.soundEffects")
            SoundEffects.shared.play(effect)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let was = was {
                    UserDefaults.standard.set(was, forKey: "conterm.soundEffects")
                } else {
                    UserDefaults.standard.removeObject(forKey: "conterm.soundEffects")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Ready", systemImage: "checkmark.seal.fill")
            Text("Conterm-specific shortcuts to know:")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Label("⌘K — command palette", systemImage: "keyboard")
                Label("⌘D split right · ⌘⇧D split down", systemImage: "rectangle.split.2x1")
                Label("⌥1…9 — jump to pane", systemImage: "number")
            }
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Config

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Configuration", systemImage: "doc.text")
            if hasContermConfig {
                Text("A Conterm config already exists. Pick one to overwrite, or Skip.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.accent.opacity(0.9))
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.accentSoft : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.5) : Color.white.opacity(0.06),
                                  lineWidth: 0.5)
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
                Picker("", selection: $pickedGlassMode.withSound()) {
                    Text("Glass").tag(Preferences.GlassMode.glass)
                    Text("Blur").tag(Preferences.GlassMode.blur)
                    Text("Solid").tag(Preferences.GlassMode.solid)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // The caption tracks the selection so each mode explains
                // itself. The three modes cost the same — look only.
                Text(Self.modeCaption(pickedGlassMode))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $pickedOpaquePanes.withSound()) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Solid panes")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text("RECOMMENDED")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.16)))
                    }
                    Text("Each pane rides on solid black, framing the terminal cells against the glass. Turn off for see-through panes if you prefer the glass showing through the cells.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            Toggle(isOn: $pickedGlassPanels.withSound()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glass panels")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Use real Liquid Glass for overlay panels — Command Palette, Search, Settings. Off (default) paints them as solid cards, which is cheaper since they cover the terminal.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            Toggle(isOn: $pickedEfficientRendering.withSound()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Efficient rendering")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Redraw only when the terminal changes, not every screen refresh. Fast scrolling may tear slightly.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
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
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Back on every step except the first.
                if step != .welcome {
                    Button { goBack() } label: {
                        Text("Back")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                } else {
                    // Skip is only meaningful at the very start.
                    Button("Skip") {
                        SoundEffects.shared.play(.click)
                        finish(applyConfig: false)
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                stepDots
                Spacer()
                Button {
                    if step == .ready {
                        // Final commit gets `.click` — distinct
                        // from the per-step `.toggle` so the
                        // "you're done" event reads as heavier.
                        SoundEffects.shared.play(.click)
                        finish(applyConfig: true)
                    } else {
                        goNext()
                    }
                } label: {
                    Text(step == .ready ? "Get Started" : "Next")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        // Use the opposite of `Theme.textPrimary` so the
                        // label always contrasts with `Theme.accent`
                        // (accent + textPrimary are paired inverses).
                        .foregroundStyle(prefs.lightGlass ? Color.white : Color.black)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
            }
            // Disclaimer the header used to carry — now a quiet note
            // at the bottom of every step.
            Text("You can change anything later in Settings.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Step-progress dots in the footer center.
    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Theme.accent
                          : (s < step ? Theme.accent.opacity(0.45)
                                      : Theme.textSecondary.opacity(0.25)))
                    .frame(width: s == step ? 14 : 6, height: 6)
                    .animation(Theme.Spring.snappy, value: step)
            }
        }
    }

    private func goNext() {
        navDirection = 1
        withAnimation(Theme.Spring.soft) {
            if let next = Step(rawValue: step.rawValue + 1) { step = next }
        }
        SoundEffects.shared.play(.toggle)
    }

    private func goBack() {
        navDirection = -1
        withAnimation(Theme.Spring.soft) {
            if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
        }
        SoundEffects.shared.play(.toggle)
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Actions

    private func finish(applyConfig: Bool) {
        if applyConfig {
            prefs.glassMode             = pickedGlassMode
            prefs.opaquePanes           = pickedOpaquePanes
            prefs.liquidGlassPanels     = pickedGlassPanels
            prefs.lowPowerRendering     = pickedEfficientRendering
            // tabOrientation + lightGlass are already current — both
            // pickers write straight to prefs for live preview.
            prefs.launchAnimationEnabled = pickedLaunchAnim
            prefs.soundEffectsEnabled   = pickedSoundEffects
            // Enabled widgets in canonical order; preserve any prior order
            // for kinds that were already enabled.
            let priorOrder = prefs.enabledWidgets.filter { pickedWidgets.contains($0) }
            let added = WidgetKind.allCases
                .map(\.rawValue)
                .filter { pickedWidgets.contains($0) && !priorOrder.contains($0) }
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
        withAnimation(.easeOut(duration: 0.25)) {
            onFinish()
        }
    }
}
