import AppKit
import SwiftUI

/// Classic interface style. First-run welcome + setup wizard. Shown once
/// (after the launch animation) until completed or skipped. Lets the user pick how their
/// config is sourced and whether modal overlays use frosted Liquid
/// Glass, then writes the choices through Preferences + a config reload.
struct ClassicWelcomeWizard: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var state: AppState

    var onFinish: () -> Void

    private typealias ConfigChoice = SetupWizardDraft.ConfigChoice

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

    @State private var navDirection: Int = 1   // +1 forward, -1 back

    // Window mode, solid panes, tab orientation, light/dark and the
    // interface style bind straight to prefs: the window repaints beneath
    // the wizard, so each pick previews itself. Skip is offered only on the
    // welcome step, before any live-bound control is reachable, so none of
    // them needs a restore path. The step and the deferred picks live in
    // the shared draft: picking Liquid Drop swaps this wizard for
    // `WelcomeWizard` on the spot, and the run carries across.
    @ObservedObject private var draft = SetupWizardDraft.shared

    private var step: Step {
        get { Step(rawValue: draft.step) ?? .welcome }
        nonmutating set { draft.step = newValue.rawValue }
    }

    private var configChoice: ConfigChoice {
        get { draft.configChoice }
        nonmutating set { draft.configChoice = newValue }
    }

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
    private static let cardMargin: CGFloat = 56
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
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {} // swallow taps; force a choice/skip
                .background(GeometryReader { g in
                    Color.clear.preference(key: WizardHeightKey.self, value: g.size.height)
                })
                .onPreferenceChange(WizardHeightKey.self) { h in
                    if h > 0, abs(h - availableHeight) > 1 { availableHeight = h }
                }

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
            draft.seed(from: prefs, ghosttyPresent: ghosttyPresent)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.25)
            }
            .measuringHeight(WizardChromeKey.self)
            // Every step scrolls, not just the long ones: the card is
            // pinned to its content height, so anything that doesn't fit
            // the viewport would otherwise render past the window.
            ScrollView(.vertical) {
                stepBody
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .measuringHeight(WizardBodyHeightKey.self)
            }
            .frame(height: stepViewportHeight)
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 0) {
                Divider().opacity(0.25)
                footer
            }
            .measuringHeight(WizardChromeKey.self)
        }
        .onPreferenceChange(WizardChromeKey.self) { h in
            if h > 0, abs(h - chromeHeight) > 1 { chromeHeight = h }
        }
        .onPreferenceChange(WizardBodyHeightKey.self) { h in
            if h > 0, abs(h - bodyHeight) > 1 { bodyHeight = h }
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
            Text("Config source, look, tabs, widgets, sound — then you're in.")
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
            interfaceSection

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
            Toggle(isOn: $draft.launchAnim.withSound()) {
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(kind.subtitle)
                    .font(.system(size: 11, design: .rounded))
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
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var soundStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Sound effects", systemImage: "speaker.wave.2.fill")
            Toggle(isOn: $draft.soundEffects.withSound()) {
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

    // MARK: - Interface style

    /// Liquid Drop or Classic, live: picking Liquid Drop hands the rest of
    /// the run to `WelcomeWizard` (see `SetupWizardDraft`).
    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Interface", systemImage: "drop.fill")
            HStack(alignment: .top, spacing: 8) {
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text(subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                Picker("", selection: $prefs.glassMode.withSound()) {
                    Text("Glass").tag(Preferences.GlassMode.glass)
                    Text("Blur").tag(Preferences.GlassMode.blur)
                    Text("Solid").tag(Preferences.GlassMode.solid)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // The caption tracks the selection so each mode explains
                // itself; Glass also carries its cost note.
                Text(Self.modeCaption(prefs.glassMode))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if prefs.glassMode == .glass { GlassCostNote() }
            }

            Toggle(isOn: $prefs.opaquePanes.withSound()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Solid panes")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(prefs.glassMode == .solid
                            ? "The Solid window is fully opaque, so panes always ride on it — pick Glass or Blur for see-through panes."
                            : "Each pane rides on solid black, framing the terminal cells against the window. Turn off for see-through panes that let the window material show through the cells.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .disabled(prefs.glassMode == .solid)

            Toggle(isOn: $draft.glassPanels.withSound()) {
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

            Toggle(isOn: $draft.efficientRendering.withSound()) {
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
            prefs.liquidGlassPanels     = draft.glassPanels
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
        withAnimation(.easeOut(duration: 0.25)) {
            onFinish()
        }
        // Once the card has faded, so the step doesn't visibly rewind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { draft.reset() }
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
