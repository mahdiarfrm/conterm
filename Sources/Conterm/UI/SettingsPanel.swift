import SwiftUI

/// Settings: one `LiquidDrop` holding the section list on the left and the
/// selected section's scrolling content on the right, in the `Drop` kit's
/// language. Presented by `BriefingPresenter` like the briefing cards.
/// Reachable via ⌘, or via the command palette ("Open settings").
struct SettingsPanel: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var state: AppState
    @EnvironmentObject var themes: ThemeCatalog
    @EnvironmentObject var fonts: FontCatalog

    @State private var section: Section = .appearance
    // Integration state is read from disk lazily in `.onAppear`, not here:
    // a `@State` initializer re-runs on every struct init (each parent
    // re-render while the panel is open), so reading `isInstalled` here
    // would repeat a settings.json read + parse on the main thread. Config
    // isn't the default section, so the initial `false` is never shown.
    @State private var claudeIntegrationOn = false
    @State private var codexIntegrationOn = false
    @State private var codexAwaitsTrust = false
    @State private var openCodeIntegrationOn = false
    @State private var themeFilter: String = ""

    enum Section: String, CaseIterable, Identifiable {
        case appearance, tabs, widgets, panes, window, integrations, launch, palette, shortcuts, config, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance: return "Appearance"
            case .tabs:       return "Tabs"
            case .widgets:    return "Widgets"
            case .panes:      return "Panes"
            case .window:     return "Window"
            case .integrations: return "Integrations"
            case .launch:     return "Launch"
            case .palette:    return "Palette"
            case .shortcuts:  return "Shortcuts"
            case .config:     return "Config"
            case .about:      return "About"
            }
        }
        var icon: String {
            switch self {
            case .appearance: return "paintpalette.fill"
            case .tabs:       return "rectangle.lefthalf.inset.filled"
            case .widgets:    return "square.grid.2x2.fill"
            case .panes:      return "rectangle.split.2x1.fill"
            case .window:     return "macwindow"
            case .integrations: return "puzzlepiece.extension"
            case .launch:     return "sparkles"
            case .palette:    return "command.circle"
            case .shortcuts:  return "keyboard"
            case .config:     return "doc.text"
            case .about:      return "info.circle.fill"
            }
        }
    }

    var body: some View {
        BriefingCard(width: 960) {
            HStack(spacing: 0) {
                sidebar
                content
            }
            // Full height when the window allows it; a short window gets a
            // shorter panel rather than one that runs off the bottom.
            .frame(maxHeight: 620)
        }
        // Keyboard nav: ↑/↓/Tab in sidebar. AppState.settingsNavDelta
        // is bumped by Main.swift's event monitor whenever those keys
        // fire while the panel is open (we can't use .onKeyPress alone
        // because focus may still be on the terminal underneath).
        .onChange(of: state.settingsNavDelta) { old, new in
            moveSelection(by: new - old)
        }
        .onAppear {
            // One disk read per panel-open for the integration toggles
            // (see the @State declarations above).
            claudeIntegrationOn = ClaudeIntegration.isInstalled
            codexIntegrationOn = CodexIntegration.isInstalled
            codexAwaitsTrust = CodexIntegration.awaitsTrust
            openCodeIntegrationOn = OpenCodeIntegration.isInstalled
            // Jump to the section a palette settings result asked for.
            applyRequestedSection()
        }
        .onChange(of: state.requestedSettingsSection) { _, _ in
            applyRequestedSection()
        }
        .onExitCommand { state.toggleSettings() }
    }

    /// Honor a section requested by the palette's settings search, then
    /// clear it so a later re-open doesn't snap back to it.
    private func applyRequestedSection() {
        guard let raw = state.requestedSettingsSection,
              let target = Section(rawValue: raw) else { return }
        section = target
        state.requestedSettingsSection = nil
    }

    private func moveSelection(by step: Int) {
        let all = Section.allCases
        guard let i = all.firstIndex(of: section) else { return }
        let next = (i + step + all.count) % all.count
        section = all[next]
        // Same tick as the palette arrow-key navigation — short
        // and quiet so holding the arrow doesn't machine-gun.
        SoundEffects.shared.play(.paletteMove)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        SettingsSidebar(selection: section) { item in
            section = item
        }
    }

    // MARK: - Content

    /// Coordinate space of the scrolling section content; `DropCascade`
    /// reads each card's offset in it.
    private static let scrollSpace = "settings.scroll"

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .topTrailing) {
            // Keyed on the section, so a switch replaces the page. The swap
            // itself is not animated: a section is full of AppKit-backed
            // controls, and every frame of an animation over them is a
            // main-thread pass across all of them. The arrival motion is the
            // title rolling in and the cards cascading.
            sectionPage(section)
                .id(section)

            DropIconButton(symbol: "xmark", help: "Close (esc)") { state.toggleSettings() }
                .padding(.top, 34)
                .padding(.trailing, Drop.inset)
                .rollUp(delay: 0.10)
        }
    }

    /// One section as a scrolling page.
    private func sectionPage(_ item: Section) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionBody(item)
            }
            .toggleStyle(.drop)
            .padding(.leading, 28)
            .padding(.trailing, Drop.inset)
            .padding(.top, 40)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(name: Self.scrollSpace)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func sectionBody(_ item: Section) -> some View {
        switch item {
        case .appearance: appearance
        case .tabs:       tabs
        case .widgets:    widgets
        case .panes:      panes
        case .window:     window
        case .integrations: integrations
        case .launch:     launch
        case .palette:    palette
        case .shortcuts:  shortcuts
        case .config:     config
        case .about:      about
        }
    }

    // MARK: - Sections

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Appearance", subtitle: "Theme, font, and glass.")

            // Interface style
            card {
                SettingsRow(title: "Interface",
                            subtitle: "Liquid Drop is glass that refracts the terminal behind it, with motion. Classic is flat cards and system materials.") {
                    // Chips, not a segmented Picker: that one is an AppKit
                    // control, and this choice swaps the panel it sits in.
                    HStack(spacing: 6) {
                        ForEach(Preferences.InterfaceStyle.allCases, id: \.self) { style in
                            DropFilterChip(title: style == .liquidDrop ? "Liquid Drop" : "Classic",
                                           selected: prefs.interfaceStyle == style) {
                                guard prefs.interfaceStyle != style else { return }
                                SoundEffects.shared.play(.toggle)
                                prefs.interfaceStyle = style
                            }
                        }
                    }
                }
            }

            // Theme
            card {
                ThemePicker(filter: $themeFilter)
            }

            // Font
            card {
                FontEditor()
            }

            // Glass
            card {
                SettingsRow(title: "Window",
                            subtitle: "Glass is one sheet of Liquid Glass over the desktop; the panes are opaque tiles on top. Blur is the classic frosted material; Solid is a fully opaque window.") {
                    Picker("", selection: Binding(
                        get: { prefs.glassMode },
                        set: { prefs.glassMode = $0 }
                    ).withSound()) {
                        Text("Glass").tag(Preferences.GlassMode.glass)
                        Text("Blur").tag(Preferences.GlassMode.blur)
                        Text("Solid").tag(Preferences.GlassMode.solid)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                if prefs.glassMode == .glass {
                    GlassCostNote()
                        .padding(.horizontal, 2)
                }
                SettingsRow(title: "Solid panes",
                            subtitle: prefs.glassMode == .solid
                                ? "The Solid window is fully opaque, so panes always ride on it — pick Glass or Blur for see-through panes."
                                : "Paint panes on solid black instead of letting the window material show through the cells. Off lets a translucent terminal reveal the window behind it.") {
                    Toggle("", isOn: $prefs.opaquePanes.withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                        .disabled(prefs.glassMode == .solid)
                }
                SettingsRow(title: "Tint",
                            subtitle: "Cool dark or cool light.") {
                    Picker("", selection: $prefs.lightGlass.withSound()) {
                        Text("Dark").tag(false)
                        Text("Light").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsRow(title: "Frost",
                            subtitle: "How clear the glass reads. Clear shows the desktop through the top bar and gaps; frost it up for more privacy on a busy wallpaper. Does not change its cost.") {
                    HStack(spacing: 8) {
                        Text("Clear").subLabel().fixedSize()
                        Slider(value: $prefs.glassiness, in: 0.0...1.0).frame(width: 180)
                        Text("Frosted").subLabel().fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                SettingsRow(title: "Pane corner radius",
                            subtitle: "How round the terminal tile's corners are. Raise it to match the window's curve, lower it toward the system radius for tighter corners.") {
                    HStack(spacing: 8) {
                        Text("Sharp").subLabel().fixedSize()
                        Slider(value: $prefs.paneCornerRadius, in: 0.0...24.0, step: 1)
                            .frame(width: 180)
                        Text("Round").subLabel().fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                SettingsRow(title: "Interface size",
                            subtitle: "How large the chrome around the terminal is drawn — the tab bar, the toolbar and their pills. The terminal's own font size is set separately, above.") {
                    HStack(spacing: 8) {
                        Text("Smaller").subLabel().fixedSize()
                        Slider(value: $prefs.uiScale, in: 0.85...1.25, step: 0.05)
                            .frame(width: 180)
                        Text("Larger").subLabel().fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                SettingsRow(title: "Action pill",
                            subtitle: "The bell / search / ⌘K cluster wears an accent. Monochrome returns it to plain glass.") {
                    HStack(spacing: 7) {
                        ForEach(Preferences.ActionAccent.allCases) { accent in
                            AccentSwatch(accent: accent,
                                         selected: prefs.actionAccent == accent) {
                                prefs.actionAccent = accent
                            }
                        }
                    }
                }
                SettingsRow(title: "New tab",
                            subtitle: "Color of the new-tab + disc. Monochrome makes it a plain glass disc.") {
                    HStack(spacing: 7) {
                        ForEach(Preferences.ActionAccent.allCases) { accent in
                            AccentSwatch(accent: accent,
                                         selected: prefs.newTabAccent == accent) {
                                prefs.newTabAccent = accent
                            }
                        }
                    }
                }
                SettingsRow(title: "Toolbar collapse button",
                            subtitle: "Chevron circle at the right end of the horizontal tab bar that tucks the toolbar cluster away. Hiding the chevron also brings the cluster back.") {
                    Toggle("", isOn: $prefs.showToolbarCollapse.withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                }
                SettingsRow(title: "Layout switcher",
                            subtitle: "The horizontal / vertical / agents / orbit segments in the toolbar. Turn off to hide the switcher if you stick with one layout (⌘⇧M still opens Orbit).") {
                    Toggle("", isOn: $prefs.showLayoutSwitcher.withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                }
                SettingsRow(title: "Blink when an agent needs you",
                            subtitle: "Pulse a pane's border in amber while its Claude agent is waiting on your input.") {
                    Toggle("", isOn: $prefs.blinkOnAttention.withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                }
                SettingsRow(title: "Tool bubbles on the agent pill",
                            subtitle: "A bubble beside the Claude pill for each terraform, kubectl, helm, docker, ssh, git or gh call in flight, ringed in the tool's colour; finished calls line up at the pane's top-left. Click one for the command and its output.") {
                    Toggle("", isOn: $prefs.agentToolBubbles.withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                }
                SettingsRow(title: "Efficient rendering",
                            subtitle: "Redraw the terminal only when its output changes, not on every screen refresh. Fast scrolling may tear slightly. Relaunch to fully apply.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.lowPowerRendering },
                        set: { newValue in
                            prefs.lowPowerRendering = newValue
                            // Rebuild the config chain so the new
                            // window-vsync value lands; a relaunch
                            // guarantees the renderer's display link is
                            // recreated if libghostty doesn't swap it live.
                            Ghostty.App.shared?.reloadConfig()
                        }
                    ).withSound())
                    .toggleStyle(.drop)
                    .labelsHidden()
                }
            }
        }
        .onAppear {
            // Lazily kick off the heavy catalog loads the first time
            // the user actually visits Appearance (kept OUT of app
            // launch so the intro animation stays smooth).
            themes.ensureLoaded()
            fonts.ensureLoaded()
        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Tabs", subtitle: "Tab bar position and behaviour.")
            card {
                SettingsRow(title: "Orientation",
                            subtitle: "Top bar or left sidebar.") {
                    Picker("", selection: Binding(
                        get: { prefs.tabOrientation },
                        set: { prefs.tabOrientation = $0 }
                    ).withSound()) {
                        ForEach(Preferences.TabOrientation.allCases) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .labelsHidden()
                }
                SettingsRow(title: "Widgets",
                            subtitle: "Stats, clock, git, GitHub, ping, notes, pixel pet, and more — enable and reorder them in the Widgets tab.") {
                    Button("Widgets…") {
                        section = .widgets
                    }
                    .buttonStyle(.drop)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Widgets

    private var widgets: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Widgets",
                          subtitle: "Glanceable pills in the tab bar / sidebar. Enable the ones you want, drag with the arrows to reorder. Git, GitHub, Kubernetes, Containers, and Session stats hide themselves when there's nothing to show.")
            card {
                ForEach(Array(orderedWidgets.enumerated()), id: \.element.id) { idx, kind in
                    widgetRow(kind, index: idx, count: orderedWidgets.count)
                    if kind != orderedWidgets.last { Divider().opacity(0.5) }
                }
            }
            // Per-widget options.
            if prefs.isWidgetEnabled(WidgetKind.systemStats.rawValue) {
                card {
                    Text("System stats")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsRow(title: "CPU", subtitle: "Show the CPU load chip.") {
                        Toggle("", isOn: $prefs.statsShowCPU.withSound()).labelsHidden()
                    }
                    SettingsRow(title: "Memory", subtitle: "Show the memory load chip.") {
                        Toggle("", isOn: $prefs.statsShowMemory.withSound()).labelsHidden()
                    }
                    SettingsRow(title: "Network", subtitle: "Show the up/down throughput chip.") {
                        Toggle("", isOn: $prefs.statsShowNetwork.withSound()).labelsHidden()
                    }
                }
            }
            if prefs.isWidgetEnabled(WidgetKind.clock.rawValue) {
                card {
                    Text("Clock")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsRow(title: "24-hour", subtitle: "Use a 24-hour clock.") {
                        Toggle("", isOn: $prefs.clock24Hour.withSound()).labelsHidden()
                    }
                    SettingsRow(title: "Seconds", subtitle: "Tick every second.") {
                        Toggle("", isOn: $prefs.clockShowSeconds.withSound()).labelsHidden()
                    }
                    SettingsRow(title: "Date", subtitle: "Show the weekday and date.") {
                        Toggle("", isOn: $prefs.clockShowDate.withSound()).labelsHidden()
                    }
                }
            }
            if prefs.isWidgetEnabled(WidgetKind.kubernetes.rawValue) {
                card {
                    Text("Kubernetes")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsRow(title: "Production patterns",
                                subtitle: "Comma-separated, case-insensitive substrings. A kubectl context whose name contains one turns red — pill, context list, and the focused pane's glow. Also editable from the pill's gear.") {
                        TextField("prod", text: $prefs.kubeDangerPatterns)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 180)
                    }
                    SettingsRow(title: "Kubeconfig paths",
                                subtitle: "Colon-separated files to read (first file's current-context wins, like kubectl). Empty uses $KUBECONFIG, then ~/.kube/config.") {
                        TextField("~/.kube/config", text: $prefs.kubeConfigPaths)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 180)
                    }
                    SettingsRow(title: "Watch cluster",
                                subtitle: "Poll kubectl across all namespaces every 45 seconds: a health gem on the pill (red = node down, amber = pod trouble), and notifications for crash-looping pods and NotReady nodes.") {
                        Toggle("", isOn: $prefs.kubeWatchCluster.withSound())
                            .toggleStyle(.drop)
                            .labelsHidden()
                    }
                    SettingsRow(title: "Remember context switches",
                                subtitle: "Off: switching from the widget exports KUBECONFIG into the focused pane only — new panes start on the default context. On: switches write the global kubeconfig.") {
                        Toggle("", isOn: $prefs.kubeRememberContext.withSound())
                            .toggleStyle(.drop)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    /// Enabled widgets first (in their saved order), disabled ones after.
    private var orderedWidgets: [WidgetKind] {
        let enabled = prefs.enabledWidgets.compactMap { WidgetKind(rawValue: $0) }
        let rest = WidgetKind.allCases.filter { !prefs.enabledWidgets.contains($0.rawValue) }
        return enabled + rest
    }

    private func widgetRow(_ kind: WidgetKind, index: Int, count: Int) -> some View {
        let on = prefs.isWidgetEnabled(kind.rawValue)
        let position = prefs.enabledWidgets.firstIndex(of: kind.rawValue)
        return HStack(spacing: 10) {
            Group {
                if let asset = kind.markAsset,
                   let img = CommandRow.bundledTemplateImage(named: asset) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(Theme.textSecondary)
                } else if kind.icon == TerraformMark.iconName {
                    TerraformGlyph(color: Theme.textSecondary, size: 14)
                } else if kind.icon == RobotGlyph.iconName {
                    RobotGlyph(color: Theme.textSecondary, size: 14)
                } else {
                    Image(systemName: kind.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                Text(kind.subtitle)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer()
            // Reorder (only meaningful while enabled).
            Button { prefs.moveWidget(kind.rawValue, by: -1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!on || position == 0)
            .foregroundStyle((!on || position == 0) ? Theme.textSecondary.opacity(0.3) : Theme.textSecondary)
            Button { prefs.moveWidget(kind.rawValue, by: 1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!on || position == (prefs.enabledWidgets.count - 1))
            .foregroundStyle((!on || position == (prefs.enabledWidgets.count - 1)) ? Theme.textSecondary.opacity(0.3) : Theme.textSecondary)
            Toggle("", isOn: Binding(
                get: { on },
                set: { prefs.setWidget(kind.rawValue, enabled: $0) }
            ).withSound())
            .labelsHidden()
        }
        .padding(.vertical, 3)
        .animation(Theme.Spring.snappy, value: prefs.enabledWidgets)
    }

    private var panes: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Panes", subtitle: "Pane controls and chrome.")
            card {
                SettingsRow(title: "Pane title pill",
                            subtitle: "Floating pill in each pane showing the directory or SSH host plus its ⌥N shortcut.") {
                    Toggle("", isOn: $prefs.showPaneTitleBar.withSound()).labelsHidden()
                }
                SettingsRow(title: "Command alerts",
                            subtitle: "Show a ✓/✗ result badge when a command fails or runs a while, and notify you when a long command finishes while you're away. ⌘↑/⌘↓ jump between prompts. Needs shell integration.") {
                    Toggle("", isOn: $prefs.commandAlerts.withSound()).labelsHidden()
                }
            }
        }
    }

    private var integrations: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Integrations",
                          subtitle: "What Conterm reads from the tools you run.")
            card {
                SettingsRow(title: "Conterm for iOS",
                            subtitle: "Publish this Mac's sessions for the phone app to read over SSH, act on what it asks, and advertise the Mac on the local network so it can be found without typing a hostname. Nothing is published while this is off.") {
                    Toggle("", isOn: $prefs.companionEnabled.withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                }
                SettingsRow(title: "Terraform cockpit",
                            subtitle: "Read each `terraform plan` back as a card: what it destroys, replaces and creates. With this on, terraform saves the plan to a file and prints where — a few lines the console would not otherwise show.") {
                    Toggle("", isOn: $prefs.terraformCockpit.withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                }
                SettingsRow(title: "While you were away",
                            subtitle: "Coming back after a long absence, sum up what happened: agents that finished, runs that failed, alerts, and changes left unreviewed.") {
                    Toggle("", isOn: $prefs.briefingEnabled.withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                }
                SettingsRow(title: "Away means",
                            subtitle: "Hours unattended before a return is worth summarising.") {
                    Stepper(value: $prefs.briefingAfterHours, in: 1...24, step: 1) {
                        Text("\(Int(prefs.briefingAfterHours))h")
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .disabled(!prefs.briefingEnabled)
                }
            }
        }
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Window", subtitle: "Window state and quit.")
            card {
                SettingsRow(title: "Restore window state",
                            subtitle: "Reopen at the last position and size.") {
                    Toggle("", isOn: $prefs.rememberWindowState.withSound()).labelsHidden()
                }
                SettingsRow(title: "Confirm on quit",
                            subtitle: "⌘Q asks first and lets you restore tabs and panes next launch.") {
                    Toggle("", isOn: $prefs.confirmBeforeQuit.withSound()).labelsHidden()
                }
            }
        }
    }

    private var launch: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Launch", subtitle: "What happens at startup.")
            card {
                SettingsRow(title: "Launch animation",
                            subtitle: "Play the wordmark intro at startup.") {
                    Toggle("", isOn: $prefs.launchAnimationEnabled.withSound()).labelsHidden()
                }
                SettingsRow(title: "Launch chime",
                            subtitle: "Short chord during the launch animation.") {
                    Toggle("", isOn: $prefs.launchSoundEnabled.withSound()).labelsHidden()
                }
                SettingsRow(title: "UI sound effects",
                            subtitle: "Subtle clicks on panes, tabs, and the command palette.") {
                    HStack(spacing: 10) {
                        Button {
                            // Audible sample of the engine's
                            // output. Disabled when SFX are off so
                            // the affordance can't claim sound is
                            // being played while the toggle silences
                            // it.
                            SoundEffects.shared.play(.paletteOpen)
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Play sample")
                        .disabled(!prefs.soundEffectsEnabled)
                        Toggle("", isOn: $prefs.soundEffectsEnabled.withSound()).labelsHidden()
                    }
                }
                SettingsRow(title: "Preview animation",
                            subtitle: "Play the launch animation now.") {
                    Button("Play") {
                        SoundEffects.shared.play(.click)
                        state.launchOverlayVisible = true
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent.opacity(0.7))
                }
                SettingsRow(title: "Run setup wizard",
                            subtitle: "Re-run the first-run setup.") {
                    Button("Run") {
                        // Bypass the once-per-launch guard so the
                        // wizard always opens from this button.
                        SoundEffects.shared.play(.click)
                        state.setupWizardVisible = true
                    }
                    .buttonStyle(.drop)
                }
            }
        }
    }

    // MARK: - Palette (reorder)

    /// Drag-free reordering of the command palette's main list. The
    /// effective order = (user picks, in their chosen order) +
    /// (any commands they haven't touched, in built-in order). A
    /// "Reset" button clears the override so new releases that ship
    /// extra commands don't have to be re-arranged manually.
    private var palette: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Palette",
                          subtitle: "Reorder the commands shown in ⌘K, or hide the ones you don't use. Hidden commands still work from their keyboard shortcut.")
            card {
                let effective = effectivePaletteOrder
                ForEach(Array(effective.enumerated()), id: \.element.id) { idx, item in
                    let hidden = prefs.hiddenPaletteCommands.contains(item.id)
                    HStack(spacing: 10) {
                        Group {
                            if item.icon == RobotGlyph.iconName {
                                RobotGlyph(color: Theme.textSecondary, size: 14)
                            } else if item.icon == TerraformMark.iconName {
                                TerraformGlyph(color: Theme.textSecondary, size: 13)
                            } else {
                                Image(systemName: item.icon)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(width: 18)
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(hidden ? Theme.textSecondary.opacity(0.5)
                                                    : Theme.textPrimary)
                            .strikethrough(hidden, color: Theme.textSecondary.opacity(0.6))
                        Spacer()
                        // Eye toggle: show ⇄ hide this command in ⌘K.
                        Button { togglePaletteItemHidden(item.id) } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(hidden ? Theme.accent : Theme.textSecondary)
                        .help(hidden ? "Show in ⌘K" : "Hide from ⌘K")
                        Button { movePaletteItem(item.id, by: -1) } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(idx == 0)
                        .foregroundStyle(idx == 0 ? Theme.textSecondary.opacity(0.3)
                                                  : Theme.textSecondary)
                        Button { movePaletteItem(item.id, by: 1) } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(idx == effective.count - 1)
                        .foregroundStyle(idx == effective.count - 1 ? Theme.textSecondary.opacity(0.3)
                                                                    : Theme.textSecondary)
                    }
                    .padding(.vertical, 3)
                }
                HStack {
                    Spacer()
                    Button("Show all hidden") {
                        withAnimation(Theme.Spring.snappy) {
                            prefs.hiddenPaletteCommands = []
                        }
                    }
                    .buttonStyle(.drop)
                    .controlSize(.small)
                    .disabled(prefs.hiddenPaletteCommands.isEmpty)
                    Button("Reset to default order") {
                        prefs.paletteCommandOrder = []
                    }
                    .buttonStyle(.drop)
                    .controlSize(.small)
                    .disabled(prefs.paletteCommandOrder.isEmpty)
                }
                .padding(.top, 6)
            }
        }
    }

    /// The currently-effective list of palette commands, in display
    /// order. User-ordered IDs first, built-in remainder appended.
    private var effectivePaletteOrder: [(id: String, title: String, icon: String)] {
        let all = CommandPalette.catalog
        let override = prefs.paletteCommandOrder
        guard !override.isEmpty else { return all }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var result: [(id: String, title: String, icon: String)] = []
        var seen = Set<String>()
        for id in override {
            if let item = byID[id] { result.append(item); seen.insert(id) }
        }
        for item in all where !seen.contains(item.id) { result.append(item) }
        return result
    }

    private func movePaletteItem(_ id: String, by delta: Int) {
        var order = effectivePaletteOrder.map { $0.id }
        guard let i = order.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < order.count else { return }
        order.swapAt(i, j)
        withAnimation(Theme.Spring.snappy) {
            prefs.paletteCommandOrder = order
        }
    }

    private func togglePaletteItemHidden(_ id: String) {
        var hidden = prefs.hiddenPaletteCommands
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
        withAnimation(Theme.Spring.snappy) {
            prefs.hiddenPaletteCommands = hidden
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Shortcuts", subtitle: "Keyboard reference.")
            ForEach(KeyboardShortcuts.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                        .kerning(0.5)
                        .padding(.horizontal, 2)
                    card {
                        ForEach(group.items, id: \.label) { s in
                            HStack {
                                Text(s.label)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(s.keys)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(Color.white.opacity(0.08))
                                    )
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }

    private var config: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Config", subtitle: "Conterm reads a single file. Ghostty syntax — see the Ghostty docs.")
            // Single source-of-truth card: shows the file Conterm
            // actually reads, what it currently includes, and the
            // three actions a user wants (open / reload / reset).
            card {
                configSourceRow
                SettingsRow(title: "Reload",
                            subtitle: "Re-read the config file and reapply blur.") {
                    Button("Reload") {
                        SoundEffects.shared.play(.click)
                        (NSApp.delegate as? AppDelegate)?.reloadConfigAndReapplyBlur()
                        prefs.refreshPaneBlurFromConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                SettingsRow(title: "Safe mode",
                            subtitle: "Ignore both config files and boot on Ghostty's built-in defaults. Use to recover from a bad edit; your files aren't touched.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.useDefaultConfig },
                        set: { newValue in
                            prefs.useDefaultConfig = newValue
                            // Reload the whole config chain live so the
                            // change applies without a relaunch.
                            Ghostty.App.shared?.reloadConfig()
                        }
                    ).withSound())
                    .toggleStyle(.drop)
                    .labelsHidden()
                }
                SettingsRow(title: "Remote arrow keys",
                            subtitle: "Send Shift / Option / Ctrl + Arrow as xterm motion sequences so word and line jumps work in remote vim, tmux, and similar. Shift + Arrow stops extending text selection while this is on.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.remoteArrowKeys },
                        set: { newValue in
                            prefs.remoteArrowKeys = newValue
                            // Reload the config so the change applies
                            // to live panes without a relaunch.
                            Ghostty.App.shared?.reloadConfig()
                        }
                    ).withSound())
                    .toggleStyle(.drop)
                    .labelsHidden()
                }
                SettingsRow(title: "Launch command delay",
                            subtitle: "How long a new tab waits for its shell to finish loading before an SSH shortcut or other launch command is typed into it. Raise it if a heavy shell startup (a big .zshrc) swallows the command.") {
                    HStack(spacing: 8) {
                        Text("Instant").subLabel().fixedSize()
                        Slider(value: $prefs.launchCommandDelay, in: 0.0...3.0, step: 0.1)
                            .frame(width: 180)
                        Text("Patient").subLabel().fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                SettingsRow(title: "Claude Code integration",
                            subtitle: "Add hooks to ~/.claude/settings.json so a running Claude shows ready / thinking / needs-input in its pane. Your other hooks are preserved.") {
                    Toggle("", isOn: Binding(
                        get: { claudeIntegrationOn },
                        set: { on in
                            if on { ClaudeIntegration.install() }
                            else  { ClaudeIntegration.uninstall() }
                            claudeIntegrationOn = ClaudeIntegration.isInstalled
                        }
                    ).withSound())
                    .toggleStyle(.drop)
                    .labelsHidden()
                }
                SettingsRow(title: "Codex integration",
                            subtitle: codexAwaitsTrust
                                ? "Hooks are in ~/.codex/hooks.json, and Codex is ignoring them until you say they are yours: type /hooks in Codex, open the Conterm entries and trust them."
                                : "Add hooks to ~/.codex/hooks.json so a running Codex shows ready / thinking / needs-input and its tool bubbles, like Claude. Codex runs a new hook only after you trust it from its /hooks screen. Your other hooks are preserved.") {
                    HStack(spacing: 10) {
                        if codexAwaitsTrust {
                            Label("Trust in /hooks", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.warning)
                                .fixedSize()
                        }
                        Toggle("", isOn: Binding(
                            get: { codexIntegrationOn },
                            set: { on in
                                if on { CodexIntegration.install() }
                                else  { CodexIntegration.uninstall() }
                                codexIntegrationOn = CodexIntegration.isInstalled
                                codexAwaitsTrust = CodexIntegration.awaitsTrust
                            }
                        ).withSound())
                        .toggleStyle(.drop)
                        .labelsHidden()
                    }
                }
                SettingsRow(title: "opencode integration",
                            subtitle: "Install an opencode plugin that drives the same status pill. Your config and other plugins are untouched.") {
                    Toggle("", isOn: Binding(
                        get: { openCodeIntegrationOn },
                        set: { on in
                            if on { OpenCodeIntegration.install() }
                            else  { OpenCodeIntegration.uninstall() }
                            openCodeIntegrationOn = OpenCodeIntegration.isInstalled
                        }
                    ).withSound())
                    .toggleStyle(.drop)
                    .labelsHidden()
                }
                SettingsRow(title: "Diagnostic logging",
                            subtitle: "Write internal events to ~/Library/Logs/Conterm/conterm.log. A development aid; off by default.") {
                    HStack(spacing: 10) {
                        Button {
                            SoundEffects.shared.play(.click)
                            DiagnosticLog.reveal()
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal log in Finder")
                        Toggle("", isOn: $prefs.diagnosticLogging.withSound())
                            .toggleStyle(.drop)
                            .labelsHidden()
                    }
                }
            }
            card {
                SettingsRow(title: "Automatic updates",
                            subtitle: "Check GitHub for a newer release at launch and once a day while running. Silent — only the toolbar pill lights up.") {
                    Toggle("", isOn: $prefs.autoCheckUpdates.withSound()).labelsHidden()
                }
                SettingsRow(title: "Check now",
                            subtitle: "You're on \(UpdateChecker.shared.currentVersion). Looks for a newer release on GitHub.") {
                    Button("Check for Updates") {
                        SoundEffects.shared.play(.click)
                        UpdateChecker.shared.checkInBackground(announce: true)
                    }
                    .buttonStyle(.drop)
                    .controlSize(.regular)
                }
            }
            card {
                SettingsRow(title: "Back up",
                            subtitle: "Save your sessions, app settings, and Conterm + Ghostty config to one file.") {
                    Button("Back Up…") {
                        SoundEffects.shared.play(.click)
                        BackupStore.exportWithPanel()
                    }
                    .buttonStyle(.drop)
                    .controlSize(.regular)
                }
                SettingsRow(title: "Restore",
                            subtitle: "Load a backup file. Conterm relaunches to apply it.") {
                    Button("Restore…") {
                        SoundEffects.shared.play(.click)
                        BackupStore.restoreWithPanel()
                    }
                    .buttonStyle(.drop)
                    .controlSize(.regular)
                }
            }
            ConfigEditor()
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("About", subtitle: "Build info & credits.")
            AboutContent()
        }
    }

    // MARK: - Helpers

    // MARK: - Config section helpers

    /// Compact summary card at the top of Settings → Config. Names
    /// the one file Conterm reads, shows what it currently includes
    /// (linked to Ghostty / standalone / fresh), and exposes Open /
    /// Reset actions. Keeps the user from having to read load-order
    /// docs to understand what's active.
    @ViewBuilder
    private var configSourceRow: some View {
        let path = InstanceState.configPath("config")
        let linked = SetupAssistant.isLinkedToGhostty()
        let status = linked
            ? "Includes ~/.config/ghostty/config (edits in either apply)."
            : "Standalone — Ghostty config is not read."

        SettingsRow(title: "Conterm reads",
                    subtitle: path) {
            HStack(spacing: 6) {
                Button("Open") {
                    SoundEffects.shared.play(.click)
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .buttonStyle(.drop)
                Menu {
                    Button("Link to Ghostty config") {
                        SetupAssistant.linkGhosttyConfig()
                        (NSApp.delegate as? AppDelegate)?.reloadConfigAndReapplyBlur()
                    }
                    .disabled(!SetupAssistant.ghosttyConfigExists())
                    Button("Reset to defaults") {
                        SetupAssistant.writeFreshConfig()
                        (NSApp.delegate as? AppDelegate)?.reloadConfigAndReapplyBlur()
                    }
                } label: { Text("More…") }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
            }
        }
        // Status line under the path so the user can see at a glance
        // whether their Ghostty config is in play.
        HStack(spacing: 6) {
            Image(systemName: linked ? "link.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(linked ? Theme.accent : Theme.textSecondary)
            Text(status)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RollUpText(title, font: Drop.title(), color: Theme.textPrimary,
                       step: 0.024)
            Text(subtitle)
                .font(Drop.display(12.5, .regular))
                .foregroundStyle(Theme.textSecondary)
                .rollUp(delay: 0.14)
        }
        .padding(.bottom, 6)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 6) {
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Drop.wellRadius + 4, style: .continuous)
                .fill(Theme.selectionFill.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Drop.wellRadius + 4, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
        .modifier(DropCascade(space: Self.scrollSpace))
    }
}

// MARK: - Sidebar

/// The section list. Its own view, with its own state, on purpose: hover
/// and the gliding selection are animated, and an animated change to state
/// owned by `SettingsPanel` would re-run the whole panel — every section's
/// rows and controls — on each frame of the animation. Here the animation
/// touches eleven small rows.
private struct SettingsSidebar: View {
    let selection: SettingsPanel.Section
    let onSelect: (SettingsPanel.Section) -> Void

    @State private var hovered: SettingsPanel.Section?
    /// Row of the selection as drawn; follows `selection` inside an
    /// animation.
    @State private var shownIndex = 0

    private static let rowHeight: CGFloat = 34
    private static let rowGap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DropEyebrow("Settings", branded: true)
                .padding(.leading, 12)
                .padding(.bottom, 14)
                .rollUp(delay: 0)

            VStack(spacing: Self.rowGap) {
                ForEach(Array(SettingsPanel.Section.allCases.enumerated()), id: \.element) { i, item in
                    row(item)
                        .rollUp(delay: 0.04 + Double(i) * 0.03, blurs: false)
                }
            }
            // One selection bubble for the whole list, moved by `offset`.
            // An offset is a render transform: gliding it costs no layout.
            // A matched-geometry bubble re-runs layout every frame, and
            // layout here reaches the section page beside it, whose AppKit
            // controls are re-measured each time.
            .background(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(Theme.selectionFill)
                    .overlay(Capsule(style: .continuous).strokeBorder(Drop.sheen, lineWidth: 1))
                    .frame(height: Self.rowHeight)
                    .offset(y: CGFloat(shownIndex) * (Self.rowHeight + Self.rowGap))
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, Drop.inset - 12)
        .padding(.top, 40)
        .padding(.bottom, 40)
        .frame(width: 236)
        .onChange(of: selection, initial: true) { _, now in
            let index = SettingsPanel.Section.allCases.firstIndex(of: now) ?? 0
            withAnimation(Theme.Spring.snappy) { shownIndex = index }
        }
    }

    private func row(_ item: SettingsPanel.Section) -> some View {
        let active = selection == item
        let shape = Capsule(style: .continuous)
        return Button {
            // Suppress the click sound on a re-tap of the active
            // section — the visible state is unchanged.
            if !active { SoundEffects.shared.play(.toggle) }
            onSelect(item)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 18)
                Text(item.label)
                    .font(Drop.display(13, .medium))
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(height: Self.rowHeight)
            .background(shape.fill(Theme.selectionFill.opacity(hovered == item && !active ? 0.7 : 0)))
            // Without this the row is only clickable where it draws — the
            // icon and the label — and the rest of it ignores the pointer.
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hovered = inside ? item : (hovered == item ? nil : hovered)
            }
        }
    }
}

// MARK: - Row primitive

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 9)
    }
}

private extension Text {
    func subLabel() -> some View {
        self.font(.system(size: 10, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
    }
    func monoLabel() -> some View {
        self.font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Keyboard shortcuts table

private struct KeyboardShortcuts {
    struct Item { let label: String; let keys: String }
    struct Group { let title: String; let items: [Item] }

    static let groups: [Group] = [
        Group(title: "Tabs & windows", items: [
            Item(label: "New window",       keys: "⌘N"),
            Item(label: "New tab",          keys: "⌘T"),
            Item(label: "Close pane / tab", keys: "⌘W"),
            Item(label: "Jump to tab 1–9",  keys: "⌘1 … ⌘9"),
            Item(label: "Next / previous tab", keys: "⌘⇧] ⌘⇧["),
            Item(label: "Minimize window",  keys: "⌘M"),
        ]),
        Group(title: "Panes", items: [
            Item(label: "Split right",    keys: "⌘D"),
            Item(label: "Split down",     keys: "⌘⇧D"),
            Item(label: "Focus pane 1–9", keys: "⌥1 … ⌥9"),
        ]),
        Group(title: "Terminal", items: [
            Item(label: "Previous prompt",   keys: "⌘↑"),
            Item(label: "Next prompt",       keys: "⌘↓"),
            Item(label: "Search scrollback", keys: "⌘F"),
        ]),
        Group(title: "Overlays", items: [
            Item(label: "Command palette",      keys: "⌘K"),
            Item(label: "Agent command center", keys: "⌘⇧A"),
            Item(label: "Settings",             keys: "⌘,"),
            Item(label: "Dismiss overlay",      keys: "Esc"),
        ]),
        Group(title: "Command palette", items: [
            Item(label: "Move selection",    keys: "↑ ↓"),
            Item(label: "Switch suggestion", keys: "← →"),
            Item(label: "Run selection",     keys: "↩"),
            Item(label: "Delete note",       keys: "⌘⌫"),
        ]),
    ]
}

// MARK: - Config editor

private struct ConfigEditor: View {
    @State private var text: String = ""
    @State private var path: String = ""
    @State private var saved: Bool = false

    private var configPath: String {
        let home = NSHomeDirectory()
        return InstanceState.configPath("config")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                        .font(.system(size: 11, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.30))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
                .frame(minHeight: 260)
            HStack {
                Text("Changes take effect on next launch.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.green)
                }
                Button("Save") {
                    SoundEffects.shared.play(.click)
                    save()
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent.opacity(0.75))
            }
        }
        .task {
            let p = configPath
            path = p
            // Read off the main thread so opening the Config section never
            // blocks the UI on disk (the file can grow with includes).
            text = await Task.detached {
                (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
            }.value
        }
    }

    private func save() {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: configPath, atomically: true, encoding: .utf8)
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { saved = false }
        }
    }
}

// MARK: - About content (also used in standalone About panel)

struct AboutContent: View {
    /// The About window sets everything on one centred axis; Settings keeps
    /// the page's leading edge.
    var centered = false

    var body: some View {
        let info = Ghostty.buildInfo
        let axis: HorizontalAlignment = centered ? .center : .leading
        VStack(alignment: axis, spacing: Drop.sectionGap) {
            masthead

            HStack(alignment: .top, spacing: 34) {
                DropFact(label: "Version", value: appVersion(), mono: true)
                DropFact(label: "libghostty", value: libghosttyVersion(info.version), mono: true)
                DropFact(label: "Core build", value: buildMode(info.mode.rawValue))
                DropFact(label: "License", value: "MIT")
                if !centered { Spacer(minLength: 0) }
            }
            .rollUp(delay: 0.24, blurs: false)

            HStack(spacing: 10) {
                linkButton("GitHub", symbol: "chevron.left.forwardslash.chevron.right",
                           url: "https://github.com/mahdiarfrm/conterm")
                linkButton("Report a bug", symbol: "ladybug",
                           url: "https://github.com/mahdiarfrm/conterm/issues")
            }
            .rollUp(delay: 0.30, blurs: false)

            VStack(alignment: axis, spacing: 13) {
                DropEyebrow("Credits")
                VStack(alignment: axis, spacing: 7) {
                    credit("libghostty by Mitchell Hashimoto — the terminal-emulator core.")
                    credit("Ghostty's shell-integration scripts for zsh and bash, bundled directly.")
                }
            }
            .rollUp(delay: 0.36, blurs: false)

            Text("© 2026 Mahdiyar Faramarzpour")
                .font(Drop.mono(9.5))
                .kerning(0.6)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
                .rollUp(delay: 0.44, blurs: false)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    /// Icon, name and the one-line description: stacked on the centred
    /// axis, side by side on a leading one.
    @ViewBuilder
    private var masthead: some View {
        if centered {
            VStack(spacing: 16) {
                appIcon
                nameAndTagline(alignment: .center)
            }
        } else {
            HStack(spacing: 22) {
                appIcon
                nameAndTagline(alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let img = NSImage(named: "AppIcon") {
            // High-quality interpolation, then a continuous-curve squircle
            // clip: the raw .icns scaled down leaves jaggies at the corners.
            // The icon art carries its own transparent margin; the frame is
            // drawn past it so the visible tile lands on the layout's edge.
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
                .padding(-8)
                .rollUp(delay: 0)
        }
    }

    private func nameAndTagline(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            RollUpText("Conterm", font: Drop.title(),
                       color: Theme.textPrimary, startDelay: 0.05, step: 0.03)
            Text("A modern macOS terminal, built on libghostty.")
                .font(Drop.display(12.5, .regular))
                .foregroundStyle(Theme.textSecondary)
                .rollUp(delay: 0.18, blurs: false)
        }
    }

    private func credit(_ s: String) -> some View {
        Text(s)
            .font(Drop.display(12.5, .regular))
            .foregroundStyle(Theme.textPrimary.opacity(0.9))
            .multilineTextAlignment(centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func linkButton(_ label: String, symbol: String, url: String) -> some View {
        DropButton(title: label, symbol: symbol) {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }

    /// The version without its build metadata: `1.3.2-main-+24c5671` reads
    /// as `1.3.2-main`, and a long git SHA can't overflow the column.
    private func libghosttyVersion(_ raw: String) -> String {
        let core = raw.split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
        let trimmed = core.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(14))
    }

    /// libghostty's `ghostty_build_mode_e`, by raw value in header order.
    private func buildMode(_ raw: UInt32) -> String {
        switch raw {
        case 0:  return "debug"
        case 1:  return "release · safe"
        case 2:  return "release · fast"
        case 3:  return "release · small"
        default: return "unknown"
        }
    }

    /// Conterm's own version, read from Info.plist so it stays in sync
    /// with every build instead of hard-coded here.
    private func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}

// MARK: - Theme picker

/// Searchable swatch grid backed by ThemeCatalog. Each tile shows a
/// mini "terminal" — background fill, foreground glyph, and three
/// palette dots — so the user can recognize their favorite at a
/// glance instead of reading 463 names.
private struct ThemePicker: View {
    @EnvironmentObject var themes: ThemeCatalog
    @EnvironmentObject var prefs: Preferences
    @Binding var filter: String

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Theme")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if prefs.themeFromConfig {
                    Text("from config")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.stroke))
                } else if let cur = themes.current {
                    Text(cur)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.stroke))
                }
            }

            // Source switch. ON defers colors to the user's own Ghostty
            // config (the picker is disabled and its managed block is
            // removed); OFF lets the swatches below own the palette.
            sourceToggle

            // Only the filter + swatches dim/disable while the config owns
            // the colors — the toggle above stays live so it can be turned
            // back off.
            Group {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textSecondary)
                        .font(.system(size: 11))
                    TextField("Filter \(themes.themes.count) themes…", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .rounded))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.5)
                )

                if themes.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading themes…")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(filteredThemes, id: \.id) { theme in
                                ThemeSwatch(
                                    theme: theme,
                                    isSelected: theme.id == themes.current
                                )
                                .onTapGesture { themes.apply(theme) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 280)
                }
            }
            .disabled(prefs.themeFromConfig)
            .opacity(prefs.themeFromConfig ? 0.4 : 1)
            .animation(Theme.Spring.snappy, value: prefs.themeFromConfig)
        }
    }

    /// Toggle row choosing where the terminal palette comes from.
    private var sourceToggle: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use theme from terminal config")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(prefs.themeFromConfig
                     ? "Colors follow your Ghostty config. Turn off to pick a theme."
                     : "The picker below sets the colors. Turn on to defer to your config.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $prefs.themeFromConfig)
                .labelsHidden()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
        // Flipping ON hands control back to the config (removes the
        // managed block + reloads); OFF re-enables the swatches and the
        // user picks one.
        .onChange(of: prefs.themeFromConfig) { _, on in
            if on { themes.followConfig() }
        }
    }

    private var filteredThemes: [ThemeCatalog.Theme] {
        guard !filter.isEmpty else { return themes.themes }
        let q = filter.lowercased()
        return themes.themes.filter { $0.name.lowercased().contains(q) }
    }
}

private struct ThemeSwatch: View {
    let theme: ThemeCatalog.Theme
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.background)
                    .frame(height: 56)
                // Tiny "$ ls" preview in the foreground color.
                Text("$ ls")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.foreground)
                    .padding(.leading, 8).padding(.bottom, 6)
                // Palette accent dots in the corner.
                HStack(spacing: 4) {
                    Circle().fill(theme.warn).frame(width: 6, height: 6)
                    Circle().fill(theme.accent).frame(width: 6, height: 6)
                    Circle().fill(theme.foreground).frame(width: 6, height: 6)
                }
                .padding(.trailing, 8).padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.accent
                                    : Color.white.opacity(hovering ? 0.22 : 0.08),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
            .shadow(color: isSelected ? Theme.accent.opacity(0.45) : .clear,
                    radius: isSelected ? 6 : 0)

            Text(theme.name)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(4)
        .contentShape(Rectangle())
        .scaleEffect(hovering && !isSelected ? 1.025 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
        .animation(Theme.Spring.snappy, value: isSelected)
        .onHover { hovering = $0 }
    }
}

/// One colour dot in the action-pill accent picker. `mono` shows a
/// half-filled glyph on a faint disc; the rest are saturated circles.
private struct AccentSwatch: View {
    let accent: Preferences.ActionAccent
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(accent.fill ?? Color.white.opacity(0.10))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                    )
                if accent == .mono {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(selected ? Theme.textPrimary : .clear, lineWidth: 2)
                    .padding(-3)
            )
            .scaleEffect(hovering ? 1.12 : 1.0)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(accent.label)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
        .animation(Theme.Spring.snappy, value: selected)
    }
}

// MARK: - Font editor

private struct FontEditor: View {
    @EnvironmentObject var fonts: FontCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Font")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if let f = fonts.currentFamily {
                    Text(f)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.stroke))
                }
            }

            // Live preview using the picked family + size.
            FontPreview(family: fonts.currentFamily, size: fonts.currentSize)

            SettingsRow(title: "Family",
                        subtitle: "Monospaced fonts only — what libghostty needs to render terminal cells.") {
                FontFamilyPicker()
                    .frame(width: 220)
            }

            SettingsRow(title: "Size",
                        subtitle: "Font size in points. Restart-free for live panes.") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { fonts.currentSize },
                        set: { fonts.apply(size: $0) }
                    ), in: FontCatalog.minSize...FontCatalog.maxSize, step: 1)
                    .frame(width: 200)
                    Text("\(Int(fonts.currentSize)) pt").monoLabel()
                        .frame(width: 48, alignment: .trailing)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

private struct FontFamilyPicker: View {
    @EnvironmentObject var fonts: FontCatalog

    var body: some View {
        Menu {
            // "System default" first → clears the override.
            Button("System default") { fonts.apply(family: nil) }
            Divider()
            ForEach(fonts.families, id: \.self) { family in
                Button(family) { fonts.apply(family: family) }
            }
        } label: {
            HStack {
                Text(fonts.currentFamily ?? "System default")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

private struct FontPreview: View {
    let family: String?
    let size: Double

    var body: some View {
        let resolved = family ?? "Menlo"
        return VStack(alignment: .leading, spacing: 4) {
            Text("$ echo \"hello, world\"  → 1234567890")
                .font(.custom(resolved, size: size))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("for i in 1 2 3; do echo $i; done    # AaBbCc")
                .font(.custom(resolved, size: size))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
    }
}
