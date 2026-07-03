import SwiftUI

/// Real settings panel — sidebar navigation on the left, scrollable
/// content on the right, glass chrome around the whole thing. Slides
/// in from the top like the command palette. Reachable via ⌘, or via
/// the command palette ("Open settings").
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
    @State private var openCodeIntegrationOn = false
    @State private var themeFilter: String = ""

    enum Section: String, CaseIterable, Identifiable {
        case appearance, tabs, widgets, panes, window, launch, palette, shortcuts, config, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance: return "Appearance"
            case .tabs:       return "Tabs"
            case .widgets:    return "Widgets"
            case .panes:      return "Panes"
            case .window:     return "Window"
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
            case .launch:     return "sparkles"
            case .palette:    return "command.circle"
            case .shortcuts:  return "keyboard"
            case .config:     return "doc.text"
            case .about:      return "info.circle.fill"
            }
        }
    }

    var body: some View {
        // Two detached glass bubbles — the section list and its
        // content — mirroring the command palette's split surfaces.
        HStack(spacing: 10) {
            sidebar
                .modifier(SettingsBubble())
            content
                .modifier(SettingsBubble())
        }
        .frame(width: 870, height: 540)
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
        withAnimation(Theme.Spring.snappy) { section = target }
        state.requestedSettingsSection = nil
    }

    private func moveSelection(by step: Int) {
        let all = Section.allCases
        guard let i = all.firstIndex(of: section) else { return }
        let next = (i + step + all.count) % all.count
        withAnimation(Theme.Spring.snappy) { section = all[next] }
        // Same tick as the palette arrow-key navigation — short
        // and quiet so holding the arrow doesn't machine-gun.
        SoundEffects.shared.play(.paletteMove)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 13, weight: .semibold))
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                ForEach(Section.allCases) { item in
                    sidebarItem(item)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Button {
                state.toggleSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                    Text("Close")
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.white.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .frame(width: 204)
    }

    private func sidebarItem(_ item: Section) -> some View {
        let active = section == item
        return Button {
            withAnimation(Theme.Spring.snappy) { section = item }
            // Suppress the click sound on a re-tap of the active
            // section — the visible state is unchanged.
            if !active { SoundEffects.shared.play(.toggle) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? Color.white : Theme.textSecondary)
                    .frame(width: 19)
                Text(item.label)
                    .font(.system(size: 13.5, weight: active ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(active ? Color.white : Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.30) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(active ? Theme.accent.opacity(0.50) : Color.clear, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch section {
                case .appearance: appearance
                case .tabs:       tabs
                case .widgets:    widgets
                case .panes:      panes
                case .window:     window
                case .launch:     launch
                case .palette:    palette
                case .shortcuts:  shortcuts
                case .config:     config
                case .about:      about
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Appearance", subtitle: "Theme, font, and glass.")

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
                            subtitle: "Glass is one sheet of Liquid Glass over the desktop; the panes are opaque tiles on top. Blur is the classic frosted material — lighter on the compositor than live glass. Solid is a fully opaque window, the coolest-running of the three.") {
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
                SettingsRow(title: "Solid panes",
                            subtitle: "Paint panes on solid black instead of letting the glass show through the cells. Far cooler on fanless Macs — the desktop never re-composites under a streaming pane — so it's on by default. Off lets a translucent terminal reveal the glass behind it.") {
                    Toggle("", isOn: $prefs.opaquePanes.withSound())
                        .toggleStyle(.switch)
                        .labelsHidden()
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
                SettingsRow(title: "Glass panels",
                            subtitle: "Use real Liquid Glass for overlay panels — Command Palette, Search, Settings, Notifications. Off (default) paints them as solid cards, which is cheaper since they cover the terminal.") {
                    Toggle("", isOn: $prefs.liquidGlassPanels.withSound())
                        .toggleStyle(.switch)
                        .labelsHidden()
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
                SettingsRow(title: "Efficient rendering",
                            subtitle: "Redraw the terminal only when its output changes, not on every screen refresh — a big battery saver, especially with glass on. Fast scrolling may tear slightly. Relaunch to fully apply.") {
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
                    .toggleStyle(.switch)
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
                SettingsRow(title: "Hide tab bar with one tab",
                            subtitle: "Frees space when only one tab is open.") {
                    Toggle("", isOn: $prefs.hideTabBarSingleTab.withSound()).labelsHidden()
                }
                SettingsRow(title: "Widgets",
                            subtitle: "Stats, clock, battery, git, agents — enable and reorder them in the Widgets tab.") {
                    Button("Widgets…") {
                        withAnimation(Theme.Spring.snappy) { section = .widgets }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Widgets

    private var widgets: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Widgets",
                          subtitle: "Glanceable pills in the tab bar / sidebar. Enable the ones you want, drag with the arrows to reorder. Git and Agents hide themselves when there's nothing to show.")
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
                if kind.icon == RobotGlyph.iconName {
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
                    .buttonStyle(.bordered)
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(prefs.hiddenPaletteCommands.isEmpty)
                    Button("Reset to default order") {
                        prefs.paletteCommandOrder = []
                    }
                    .buttonStyle(.bordered)
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
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                SettingsRow(title: "SSH compatibility",
                            subtitle: "Send xterm-256color over SSH so Shift / Option / Ctrl + Arrow work in remote vim, tmux, and similar.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.sshCompatMode },
                        set: { newValue in
                            prefs.sshCompatMode = newValue
                            // Reload the config so the change applies
                            // to live panes without a relaunch.
                            Ghostty.App.shared?.reloadConfig()
                        }
                    ).withSound())
                    .toggleStyle(.switch)
                    .labelsHidden()
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
                    .toggleStyle(.switch)
                    .labelsHidden()
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
                    .toggleStyle(.switch)
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
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
            card {
                SettingsRow(title: "Automatic updates",
                            subtitle: "Check GitHub for a newer release each time Conterm launches. Silent — only the toolbar pill lights up.") {
                    Toggle("", isOn: $prefs.autoCheckUpdates.withSound()).labelsHidden()
                }
                SettingsRow(title: "Check now",
                            subtitle: "You're on \(UpdateChecker.shared.currentVersion). Looks for a newer release on GitHub.") {
                    Button("Check for Updates") {
                        SoundEffects.shared.play(.click)
                        UpdateChecker.shared.checkInBackground(announce: true)
                    }
                    .buttonStyle(.bordered)
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
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                SettingsRow(title: "Restore",
                            subtitle: "Load a backup file. Conterm relaunches to apply it.") {
                    Button("Restore…") {
                        SoundEffects.shared.play(.click)
                        BackupStore.restoreWithPanel()
                    }
                    .buttonStyle(.bordered)
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
        let path = "\(NSHomeDirectory())/.config/conterm/config"
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
                .buttonStyle(.bordered)
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
        // Plain San Francisco in its bold cut — the system display
        // face, unrounded, so section titles read as headers against
        // the rounded body type.
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 21, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 6) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }
}

/// Shared chrome for the settings panel's two floating glass bubbles
/// (section list + content) — same vocabulary as the palette's.
private struct SettingsBubble: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                OverlayPanelBackground(cornerRadius: 20)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.28), .clear],
                            startPoint: .top, endPoint: .center
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 12)
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
        .padding(.vertical, 8)
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
        return "\(home)/.config/conterm/config"
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
    var body: some View {
        let info = Ghostty.buildInfo
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                if let img = NSImage(named: "AppIcon") {
                    // Render at 2x with high-quality interpolation, then
                    // clip with a continuous-curve squircle so the icon
                    // edges read as crisp + smooth (the raw .icns at
                    // 84×84 was getting nearest-pixel scaled, which left
                    // visible jaggies along the rounded corners).
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 19,
                                                     style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Conterm")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Version \(appVersion()) · \(libghosttyVersion(info.version))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    Text("A modern macOS terminal, built on libghostty.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 12) {
                        linkPill("GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
                                 url: "https://github.com/mahdiarfrm/conterm")
                        linkPill("Report a bug", systemImage: "ladybug",
                                 url: "https://github.com/mahdiarfrm/conterm/issues")
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Credits")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                bullet("libghostty by Mitchell Hashimoto — the terminal-emulator core.")
                bullet("Ghostty's shell-integration scripts for zsh and bash, bundled directly.")
            }
            Divider().opacity(0.3)
            HStack {
                Text("© 2026 Mahdiyar Faramarzpour · MIT-licensed.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(Theme.textSecondary)
            Text(s).font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func linkPill(_ label: String, systemImage: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Trim version to first 12 chars so a long git SHA doesn't overflow.
    private func libghosttyVersion(_ raw: String) -> String {
        "libghostty \(String(raw.prefix(12)))"
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
