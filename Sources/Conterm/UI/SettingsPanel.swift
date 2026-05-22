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
    @State private var claudeIntegrationOn = ClaudeIntegration.isInstalled
    @State private var openCodeIntegrationOn = OpenCodeIntegration.isInstalled
    @State private var themeFilter: String = ""

    enum Section: String, CaseIterable, Identifiable {
        case appearance, tabs, panes, window, launch, shortcuts, config, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance: return "Appearance"
            case .tabs:       return "Tabs"
            case .panes:      return "Panes"
            case .window:     return "Window"
            case .launch:     return "Launch"
            case .shortcuts:  return "Shortcuts"
            case .config:     return "Config"
            case .about:      return "About"
            }
        }
        var icon: String {
            switch self {
            case .appearance: return "paintpalette.fill"
            case .tabs:       return "rectangle.lefthalf.inset.filled"
            case .panes:      return "rectangle.split.2x1.fill"
            case .window:     return "macwindow"
            case .launch:     return "sparkles"
            case .shortcuts:  return "keyboard"
            case .config:     return "doc.text"
            case .about:      return "info.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.35)
            content
        }
        .frame(width: 860, height: 540)
        // Keyboard nav: ↑/↓/Tab in sidebar. AppState.settingsNavDelta
        // is bumped by Main.swift's event monitor whenever those keys
        // fire while the panel is open (we can't use .onKeyPress alone
        // because focus may still be on the terminal underneath).
        .onChange(of: state.settingsNavDelta) { old, new in
            moveSelection(by: new - old)
        }
        .background(
            ZStack {
                GlassBackground(material: .hudWindow)
                Color.black.opacity(0.22)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
        .shadow(color: .black.opacity(0.45), radius: 36, x: 0, y: 14)
        .onExitCommand { state.toggleSettings() }
    }

    private func moveSelection(by step: Int) {
        let all = Section.allCases
        guard let i = all.firstIndex(of: section) else { return }
        let next = (i + step + all.count) % all.count
        withAnimation(Theme.Spring.snappy) { section = all[next] }
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
        .frame(width: 192)
    }

    private func sidebarItem(_ item: Section) -> some View {
        let active = section == item
        return Button {
            withAnimation(Theme.Spring.snappy) { section = item }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.white : Theme.textSecondary)
                    .frame(width: 16)
                Text(item.label)
                    .font(.system(size: 12, weight: active ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(active ? Color.white : Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
                case .panes:      panes
                case .window:     window
                case .launch:     launch
                case .shortcuts:  shortcuts
                case .config:     config
                case .about:      about
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Appearance", subtitle: "Theme, font, and the window glass.")

            // Theme
            card {
                ThemePicker(filter: $themeFilter)
            }

            // Font
            card {
                FontEditor()
            }

            // Glass / opacity
            card {
                SettingsRow(title: "Chrome glass",
                            subtitle: "Strength of Conterm's own glass (backdrop, pills, border). The terminal's own background blur is the `background-blur` option in your config.") {
                    HStack(spacing: 8) {
                        Text("Clear").subLabel().fixedSize()
                        Slider(value: $prefs.glassiness, in: 0.0...1.0).frame(width: 180)
                        Text("Frosted").subLabel().fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                SettingsRow(title: "Glass tint",
                            subtitle: "Tint the liquid glass dark or light. The glass stays clear/refractive either way — only the tint colour changes.") {
                    Picker("", selection: $prefs.lightGlass) {
                        Text("Dark").tag(false)
                        Text("Light").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsRow(title: "Classic backdrop",
                            subtitle: "Use the original layered backdrop instead of the new liquid glass.") {
                    Toggle("", isOn: $prefs.useLegacyGlass)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRow(title: "Battery Saving Mode",
                            subtitle: "Drop the live Liquid Glass to a flat fill when Conterm isn't the active window — saves GPU when you're in another app. Turn off if you want the glass to stay alive even in the background.") {
                    Toggle("", isOn: $prefs.batterySavingMode)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRow(title: "Window opacity",
                            subtitle: "Chrome around the terminal — cells are controlled via `background-opacity` in your config.") {
                    HStack(spacing: 8) {
                        Slider(value: $prefs.windowOpacity, in: 0.25...0.95).frame(width: 180)
                        Text("\(Int(prefs.windowOpacity * 100))%").monoLabel()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .fixedSize(horizontal: true, vertical: false)
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
            sectionHeader("Tabs", subtitle: "Position and behavior of the tab bar.")
            card {
                SettingsRow(title: "Orientation",
                            subtitle: "Horizontal across the top or vertical on the leading edge.") {
                    Picker("", selection: Binding(
                        get: { prefs.tabOrientation },
                        set: { prefs.tabOrientation = $0 }
                    )) {
                        ForEach(Preferences.TabOrientation.allCases) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .labelsHidden()
                }
                SettingsRow(title: "Hide tab bar when only one tab",
                            subtitle: "Frees up some screen real estate while a single tab is open.") {
                    Toggle("", isOn: $prefs.hideTabBarSingleTab).labelsHidden()
                }
                SettingsRow(title: "Live system stats",
                            subtitle: "CPU · RAM · Network widget in the tab bar.") {
                    Toggle("", isOn: $prefs.showSystemStats).labelsHidden()
                }
            }
        }
    }

    private var panes: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Panes", subtitle: "Floating glass title bar and split behavior.")
            card {
                SettingsRow(title: "Show pane title bar",
                            subtitle: "The liquid-glass pill in each pane's top-right showing dir / SSH host + the ⌥N keybind.") {
                    Toggle("", isOn: $prefs.showPaneTitleBar).labelsHidden()
                }
            }
        }
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Window", subtitle: "How the window persists between launches.")
            card {
                SettingsRow(title: "Remember position & size",
                            subtitle: "Reopens where you last left it. Disable to always center on launch.") {
                    Toggle("", isOn: $prefs.rememberWindowState).labelsHidden()
                }
            }
        }
    }

    private var launch: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Launch", subtitle: "What happens when Conterm opens.")
            card {
                SettingsRow(title: "Launch animation",
                            subtitle: "Plays the wordmark overlay each app start.") {
                    Toggle("", isOn: $prefs.launchAnimationEnabled).labelsHidden()
                }
                SettingsRow(title: "Launch chime",
                            subtitle: "A short synthesized chord during the launch animation.") {
                    Toggle("", isOn: $prefs.launchSoundEnabled).labelsHidden()
                }
                SettingsRow(title: "Replay now",
                            subtitle: "Preview your sound/animation settings.") {
                    Button("Play") { state.launchOverlayVisible = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent.opacity(0.7))
                }
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Shortcuts", subtitle: "Keyboard reference.")
            card {
                ForEach(KeyboardShortcuts.all, id: \.label) { s in
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

    private var config: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Config", subtitle: "Direct edit of your ~/.config/conterm/config — see Ghostty's docs for every option.")
            card {
                SettingsRow(title: "Safe mode",
                            subtitle: "Recovery switch. Normally Conterm loads your config (~/.config/conterm/config, then ~/.config/ghostty/config). If a bad edit makes the terminal misbehave or fail to start right, turn this on: Conterm boots on Ghostty's genuine built-in defaults and ignores both files so you can open the editor below, fix it, then turn Safe mode back off. Your files are never modified.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.useDefaultConfig },
                        set: { newValue in
                            prefs.useDefaultConfig = newValue
                            // Reload the whole config chain live so the
                            // change applies without a relaunch.
                            Ghostty.App.shared?.reloadConfig()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                SettingsRow(title: "Claude Code integration",
                            subtitle: "Adds hooks to ~/.claude/settings.json so a running Claude shows a live status pill at the top of its pane: “Claude is Ready.” when waiting, “Claude is thinking…” with an orange glow while working, “needs you” when it wants input. Non-destructive — your other hooks are kept and the file is backed up.") {
                    Toggle("", isOn: Binding(
                        get: { claudeIntegrationOn },
                        set: { on in
                            if on { ClaudeIntegration.install() }
                            else  { ClaudeIntegration.uninstall() }
                            claudeIntegrationOn = ClaudeIntegration.isInstalled
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                SettingsRow(title: "opencode integration",
                            subtitle: "Installs a small opencode plugin (~/.config/opencode/plugin/conterm-agent.js) that drives the same status pill for opencode sessions. It's a dedicated file — your config and other plugins are untouched.") {
                    Toggle("", isOn: Binding(
                        get: { openCodeIntegrationOn },
                        set: { on in
                            if on { OpenCodeIntegration.install() }
                            else  { OpenCodeIntegration.uninstall() }
                            openCodeIntegrationOn = OpenCodeIntegration.isInstalled
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
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

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 4) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Row primitive

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
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
        .padding(.vertical, 6)
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
    static let all: [(label: String, keys: String)] = [
        ("New tab",                  "⌘T"),
        ("Close active pane / tab",  "⌘W"),
        ("Split horizontal",         "⌘D"),
        ("Split vertical",           "⌘⇧D"),
        ("Open command palette",     "⌘K"),
        ("Open settings",            "⌘,"),
        ("Jump to tab N",            "⌘1 … ⌘9"),
        ("Focus pane N in tab",      "⌥1 … ⌥9"),
        ("Close palette / settings", "Esc"),
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
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent.opacity(0.75))
            }
        }
        .onAppear {
            path = configPath
            text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
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
    @Binding var filter: String

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Theme")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if let cur = themes.current {
                    Text(cur)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.stroke))
                }
            }
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
