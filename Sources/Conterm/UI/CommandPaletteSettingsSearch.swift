import SwiftUI

/// App-settings rows for the omni search: every palette-reachable
/// setting, its keywords, and the flip-in-place vs open-Settings
/// behavior.
extension CommandPalette {
    /// App-settings results for the omni search. Bool prefs flip in
    /// place (the row's subtitle shows the live state and what ↩ does);
    /// richer controls — theme, accents, sliders, the config file —
    /// open Settings to their section. `keywords` widen what each row
    /// matches beyond its visible title.
    func settingsResults(matching ql: String) -> [Command] {
        typealias Sec = SettingsPanel.Section
        struct Item { let kw: String; let section: Sec; let cmd: Command }

        func toggle(_ id: String, _ title: String, _ kw: String,
                    _ section: Sec, _ icon: String,
                    _ isOn: Bool, _ set: @escaping (Bool) -> Void) -> Item {
            let cmd = Command(
                id: "set.\(id)", icon: icon, title: title,
                subtitle: "Settings · \(section.label) · \(isOn ? "On" : "Off") — ↩ turns \(isOn ? "off" : "on")",
                shortcut: "", run: { set(!isOn) })
            return Item(kw: kw, section: section, cmd: cmd)
        }
        func open(_ id: String, _ title: String, _ kw: String,
                  _ section: Sec, _ icon: String) -> Item {
            let cmd = Command(
                id: "set.\(id)", icon: icon, title: title,
                subtitle: "Settings · \(section.label)",
                shortcut: "", run: { [weak state] in
                    state?.openSettings(section: section.rawValue)
                })
            return Item(kw: kw, section: section, cmd: cmd)
        }

        let items: [Item] = [
            // Appearance
            open("theme", "Theme", "colors palette swatch dark light scheme",
                 .appearance, "paintpalette.fill"),
            toggle("themeFromConfig", "Use theme from terminal config",
                   "colors palette ghostty source defer", .appearance, "paintpalette",
                   prefs.themeFromConfig) { prefs.themeFromConfig = $0 },
            toggle("lightGlass", "Light glass", "appearance white tint mode bright",
                   .appearance, "sun.max", prefs.lightGlass) { prefs.lightGlass = $0 },
            toggle("solidGlass", "Solid mode (no glass)",
                   "opaque disable glass flat window", .appearance, "square.fill",
                   prefs.solidGlass) { prefs.solidGlass = $0 },
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
            toggle("autoCheckUpdates", "Check for updates on launch",
                   "github release new version", .launch, "arrow.down.circle",
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

        return items.filter { item in
            item.cmd.title.lowercased().contains(ql)
            || item.kw.contains(ql)
            || item.section.label.lowercased().contains(ql)
        }.map(\.cmd)
    }

}
