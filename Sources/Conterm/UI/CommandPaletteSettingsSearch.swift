import SwiftUI

/// App-settings rows for the omni search: every palette-reachable
/// setting, its keywords, and the flip-in-place vs open-Settings
/// behavior.
extension CommandPalette {
    /// One settings row: static match fields plus a builder that reads
    /// live state (On/Off, the current mode) only when the row matches.
    struct SettingsItem {
        let title: String
        let kw: String
        let section: SettingsPanel.Section
        let make: @MainActor () -> Command
    }

    /// App-settings results for the omni search. Bool prefs flip in
    /// place (the row's subtitle shows the live state and what ↩ does);
    /// richer controls — theme, accents, sliders, the config file —
    /// open Settings to their section. `kw` widens what each row
    /// matches beyond its visible title. The table is built once per
    /// palette open; a keystroke only filters it and materializes the
    /// few matching rows.
    @MainActor
    func settingsResults(matching ql: String) -> [Command] {
        if cachedSettingsItems.isEmpty { cachedSettingsItems = settingsItems() }
        return cachedSettingsItems.filter { item in
            item.title.lowercased().contains(ql)
            || item.kw.contains(ql)
            || item.section.label.lowercased().contains(ql)
        }.map { $0.make() }
    }

    @MainActor
    private func settingsItems() -> [SettingsItem] {
        typealias Sec = SettingsPanel.Section
        let prefs = self.prefs
        let state = self.state

        func toggle(_ id: String, _ title: String, _ kw: String,
                    _ section: Sec, _ icon: String,
                    _ isOn: @autoclosure @escaping @MainActor () -> Bool,
                    _ set: @escaping @MainActor (Bool) -> Void) -> SettingsItem {
            SettingsItem(title: title, kw: kw, section: section, make: {
                let on = isOn()
                return Command(
                    id: "set.\(id)", icon: icon, title: title,
                    subtitle: "Settings · \(section.label) · \(on ? "On" : "Off") — ↩ turns \(on ? "off" : "on")",
                    shortcut: "", run: { set(!on) })
            })
        }
        func open(_ id: String, _ title: String, _ kw: String,
                  _ section: Sec, _ icon: String) -> SettingsItem {
            SettingsItem(title: title, kw: kw, section: section, make: {
                Command(
                    id: "set.\(id)", icon: icon, title: title,
                    subtitle: "Settings · \(section.label)",
                    shortcut: "", run: { [weak state] in
                        state?.openSettings(section: section.rawValue)
                    })
            })
        }
        // Window mode is tri-state (glass / blur / solid), so its row
        // cycles through the modes — every mode stays reachable from the
        // search, and no mode is silently discarded on a round trip.
        func windowMode() -> SettingsItem {
            SettingsItem(title: "Window mode",
                         kw: "glass blur solid opaque window mode frost flat",
                         section: .appearance, make: {
                let mode = prefs.glassMode
                let all = Preferences.GlassMode.allCases
                let next = all[(all.firstIndex(of: mode)! + 1) % all.count]
                return Command(
                    id: "set.glassMode", icon: "macwindow", title: "Window mode",
                    subtitle: "Settings · Appearance · \(mode.rawValue.capitalized) — ↩ switches to \(next.rawValue.capitalized)",
                    shortcut: "", run: { prefs.glassMode = next })
            })
        }

        return [
            // Appearance
            open("theme", "Theme", "colors palette swatch dark light scheme",
                 .appearance, "paintpalette.fill"),
            toggle("themeFromConfig", "Use theme from terminal config",
                   "colors palette ghostty source defer", .appearance, "paintpalette",
                   prefs.themeFromConfig) { prefs.themeFromConfig = $0 },
            toggle("lightGlass", "Light glass", "appearance white tint mode bright",
                   .appearance, "sun.max", prefs.lightGlass) { prefs.lightGlass = $0 },
            windowMode(),
            toggle("liquidGlassPanels", "Liquid glass panels",
                   "frosted overlay command palette settings", .appearance, "drop.fill",
                   prefs.liquidGlassPanels) { prefs.liquidGlassPanels = $0 },
            open("glassiness", "Glass frost", "blur frost transparency clear",
                 .appearance, "drop"),
            open("backgroundBlur", "Background blur", "desktop blur radius wallpaper",
                 .appearance, "drop.circle"),
            open("accent", "Accent color", "action cluster tint new tab plus",
                 .appearance, "paintbrush"),
            // Tabs
            open("tabLayout", "Tab layout", "horizontal vertical sidebar agents orientation",
                 .tabs, "rectangle.lefthalf.inset.filled"),
            toggle("hideTabBarSingleTab", "Hide tab bar with one tab",
                   "single chrome minimal", .tabs, "rectangle.tophalf.inset.filled",
                   prefs.hideTabBarSingleTab) { prefs.hideTabBarSingleTab = $0 },
            // Widgets — toggle a pill in/out of the rail; manage + reorder
            // in Settings ▸ Widgets.
            open("widgets", "Widgets", "rail manage reorder pills tab bar",
                 .widgets, "square.grid.2x2"),
            toggle("widget.systemStats", "System stats widget",
                   "cpu memory network ram bar", .widgets, "chart.bar",
                   prefs.isWidgetEnabled("systemStats")) { prefs.setWidget("systemStats", enabled: $0) },
            toggle("widget.clock", "Clock widget", "time date hour minute",
                   .widgets, "clock", prefs.isWidgetEnabled("clock")) { prefs.setWidget("clock", enabled: $0) },
            toggle("widget.battery", "Battery widget", "charge power laptop percent",
                   .widgets, "battery.100", prefs.isWidgetEnabled("battery")) { prefs.setWidget("battery", enabled: $0) },
            toggle("widget.gitStatus", "Git status widget", "branch dirty ahead behind repo",
                   .widgets, "arrow.triangle.branch", prefs.isWidgetEnabled("gitStatus")) { prefs.setWidget("gitStatus", enabled: $0) },
            toggle("autoHideSidebar", "Auto-hide sidebar",
                   "vertical collapse edge reveal", .tabs, "sidebar.left",
                   prefs.autoHideSidebar) { prefs.autoHideSidebar = $0 },
            // Panes
            toggle("opaquePanes", "Solid panes",
                   "opaque backing translucent tile glass", .panes, "rectangle.split.2x1.fill",
                   prefs.opaquePanes) { prefs.opaquePanes = $0 },
            toggle("showPaneTitleBar", "Pane title bar",
                   "directory name header dir chip", .panes, "macwindow.badge.plus",
                   prefs.showPaneTitleBar) { prefs.showPaneTitleBar = $0 },
            toggle("commandAlerts", "Command alerts",
                   "osc 133 result badge notification finished", .panes, "bell.badge",
                   prefs.commandAlerts) { prefs.commandAlerts = $0 },
            toggle("lowPowerRendering", "Low power rendering",
                   "vsync battery performance idle", .panes, "bolt.badge.automatic",
                   prefs.lowPowerRendering) {
                       prefs.lowPowerRendering = $0
                       Ghostty.App.shared?.reloadConfig()
                   },
            // Window
            toggle("rememberWindowState", "Remember window size & position",
                   "frame restore relaunch", .window, "macwindow",
                   prefs.rememberWindowState) { prefs.rememberWindowState = $0 },
            toggle("confirmBeforeQuit", "Confirm before quit",
                   "cmd q dialog save session", .window, "xmark.shield",
                   prefs.confirmBeforeQuit) { prefs.confirmBeforeQuit = $0 },
            // Launch
            toggle("launchAnimation", "Launch animation",
                   "splash intro startup", .launch, "sparkles",
                   prefs.launchAnimationEnabled) { prefs.launchAnimationEnabled = $0 },
            toggle("launchSound", "Launch sound", "chime startup audio",
                   .launch, "speaker.wave.2", prefs.launchSoundEnabled) { prefs.launchSoundEnabled = $0 },
            toggle("soundEffects", "UI sound effects", "clicks sounds feedback",
                   .launch, "speaker.wave.1", prefs.soundEffectsEnabled) { prefs.soundEffectsEnabled = $0 },
            toggle("autoCheckUpdates", "Check for updates automatically",
                   "github release new version daily", .launch, "arrow.down.circle",
                   prefs.autoCheckUpdates) { prefs.autoCheckUpdates = $0 },
            // Shortcuts / config / about
            open("shortcuts", "Keyboard shortcuts", "keys bindings hotkeys",
                 .shortcuts, "keyboard"),
            toggle("sshCompatMode", "SSH compatibility mode",
                   "remote vim tmux arrow keys term", .config, "network",
                   prefs.sshCompatMode) {
                       prefs.sshCompatMode = $0
                       Ghostty.App.shared?.reloadConfig()
                   },
            toggle("useDefaultConfig", "Safe mode",
                   "ignore config recovery default boot", .config, "shield",
                   prefs.useDefaultConfig) {
                       prefs.useDefaultConfig = $0
                       Ghostty.App.shared?.reloadConfig()
                   },
            toggle("diagnosticLogging", "Diagnostic logging",
                   "debug log clog troubleshoot", .config, "ladybug",
                   prefs.diagnosticLogging) { prefs.diagnosticLogging = $0 },
            open("config", "Config file", "ghostty conterm edit reference",
                 .config, "doc.text"),
            open("about", "About Conterm", "version license credits libghostty",
                 .about, "info.circle"),
        ]
    }
}
