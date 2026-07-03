import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted by `Ghostty.App.reloadConfig` after libghostty's config
    /// has been rebuilt. Lets `Preferences` re-parse view-scoped
    /// values like `background-blur` that aren't fed back through
    /// libghostty's surface APIs.
    static let contermConfigReloaded =
        Notification.Name("conterm.configReloaded")
}

/// User-tunable application preferences, persisted in UserDefaults. We
/// route every property through `@Published + didSet` (rather than
/// SwiftUI's `@AppStorage`, which only fires correctly inside Views)
/// so observers across the app react to changes everywhere.
@MainActor
final class Preferences: ObservableObject {
    /// Window layout. `horizontal`/`vertical` place the tab bar on top or
    /// in a sidebar; `agents` swaps the sidebar's tab list for the live
    /// agent roster — the window becomes agent-first.
    enum TabOrientation: String, CaseIterable, Identifiable {
        case horizontal, vertical, agents
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// Advance the layout: Horizontal → Vertical → Agents → Horizontal.
    func cycleTabOrientation() {
        let all = TabOrientation.allCases
        let i = all.firstIndex(of: tabOrientation) ?? 0
        tabOrientation = all[(i + 1) % all.count]
    }

    /// Accent for the action cluster (bell / search / ⌘K) and the new-tab
    /// `+`. `mono` returns both to plain glass; a colour gives the cluster a
    /// saturated fill and lights the `+` in its yellow. Colours are kept
    /// dark/saturated enough for white glyphs.
    enum ActionAccent: String, CaseIterable, Identifiable {
        case mono, red, orange, yellow, green, blue, purple, pink
        var id: String { rawValue }
        var isColored: Bool { self != .mono }
        var label: String { self == .mono ? "Mono" : rawValue.capitalized }
        /// Saturated fill for the action cluster; nil = monochrome glass.
        var fill: Color? {
            switch self {
            case .mono:   return nil
            case .red:    return Color(red: 1.00, green: 0.18, blue: 0.18)
            case .orange: return Color(red: 1.00, green: 0.50, blue: 0.16)
            case .yellow: return Color(red: 0.945, green: 0.835, blue: 0.0)
            case .green:  return Color(red: 0.26, green: 0.74, blue: 0.40)
            case .blue:   return Color(red: 0.24, green: 0.52, blue: 1.00)
            case .purple: return Color(red: 0.58, green: 0.40, blue: 1.00)
            case .pink:   return Color(red: 0.97, green: 0.34, blue: 0.62)
            }
        }
    }

    @Published var tabOrientation: TabOrientation {
        didSet { ud.set(tabOrientation.rawValue, forKey: K.orientation) }
    }
    @Published var launchAnimationEnabled: Bool {
        didSet { ud.set(launchAnimationEnabled, forKey: K.launchAnim) }
    }
    @Published var launchSoundEnabled: Bool {
        didSet { ud.set(launchSoundEnabled, forKey: K.launchSound) }
    }
    /// Quick UI sound effects on pane / tab / palette events. The
    /// `SoundEffects` engine reads this same UserDefaults key
    /// directly so it doesn't need a Preferences reference on the
    /// playback path.
    @Published var soundEffectsEnabled: Bool {
        didSet { ud.set(soundEffectsEnabled, forKey: K.soundEffects) }
    }
    @Published var hasLaunched: Bool {
        didSet { ud.set(hasLaunched, forKey: K.launched) }
    }
    @Published var sidebarWidth: Double {
        didSet { ud.set(sidebarWidth, forKey: K.sidebar) }
    }
    /// Glass frost, 0…1. The window is one sheet of Liquid Glass over the
    /// desktop (panes sit on top as opaque tiles), so this only changes how
    /// the glass *looks*, never its cost: 0 ≈ clear (the desktop reads
    /// through), 1 ≈ heavy frost. Clear and frosted both composite once
    /// over the static desktop. Does not touch libghostty's desktop blur.
    @Published var glassiness: Double {
        didSet { ud.set(glassiness, forKey: K.glassiness) }
    }
    /// Light vs dark glass tint. OFF (default) = dark glass, which the
    /// chrome's text colors are tuned for. ON = a light tint.
    @Published var lightGlass: Bool {
        didSet { ud.set(lightGlass, forKey: K.lightGlass) }
    }
    /// Theme source. OFF (default): the Settings ▸ Appearance picker owns
    /// the terminal colors (written as a managed block in the conterm
    /// config). ON: defer to the user's own Ghostty config — the picker
    /// is disabled and its managed block is removed, so a hand-tuned
    /// `background`/`palette` (or a `config-file`-included Ghostty config)
    /// sets the colors. The actual block add/remove + reload is driven by
    /// `ThemeCatalog`; this only persists the chosen source.
    @Published var themeFromConfig: Bool {
        didSet { ud.set(themeFromConfig, forKey: K.themeFromConfig) }
    }
    /// How the window dresses behind the panes.
    /// - `glass`: one sheet of real Liquid Glass over the desktop.
    /// - `blur`: the classic behind-window frosted material
    ///   (`NSVisualEffectView`).
    /// - `solid`: opaque window, no glass anywhere. Drives the window's
    ///   opacity in `WindowController`.
    /// The three measure power-equivalent (docs/POWER-TESTS-2026-07.md
    /// §1) — the choice is purely visual. Tri-state on purpose: no bool
    /// facade, so a writer can never collapse `.blur` into another mode.
    enum GlassMode: String, CaseIterable {
        case glass, blur, solid
    }
    @Published var glassMode: GlassMode {
        didSet { ud.set(glassMode.rawValue, forKey: K.glassMode) }
    }
    /// Use real Liquid Glass (macOS 26 `NSGlassEffectView`) for the modal
    /// overlay panels — Command Palette, Search, Settings, Notifications,
    /// Rename, the floating sidebar card. OFF (default) paints them as solid
    /// cards: cheaper, since these panels cover the streaming terminal — the
    /// one place live glass re-lenses every frame.
    @Published var liquidGlassPanels: Bool {
        didSet { ud.set(liquidGlassPanels, forKey: K.liquidGlassPanels) }
    }
    /// "Safe mode" recovery switch. OFF by default: Conterm uses your
    /// config (~/.config/conterm/config has top priority). Turn ON to
    /// boot on Ghostty's genuine defaults and ignore your config —
    /// useful when a config edit breaks the terminal so you can fix
    /// the file. Applied live via a config reload.
    @Published var useDefaultConfig: Bool {
        didSet { ud.set(useDefaultConfig, forKey: K.useDefaultConfig) }
    }
    /// Remember window position + size between launches. macOS handles
    /// the actual persistence via NSWindow.setFrameAutosaveName.
    @Published var rememberWindowState: Bool {
        didSet { ud.set(rememberWindowState, forKey: K.windowSaveState) }
    }
    /// Show a confirmation dialog on ⌘Q with a "save session" toggle.
    /// Lets the user bail out of an accidental quit and choose whether
    /// the next launch restores tabs/panes or starts fresh.
    @Published var confirmBeforeQuit: Bool {
        didSet { ud.set(confirmBeforeQuit, forKey: K.confirmBeforeQuit) }
    }
    /// First-run setup wizard has been completed OR skipped. Until this
    /// is true the wizard reappears after the launch animation on every
    /// start (so a user who quit mid-wizard still gets it next time).
    @Published var hasCompletedSetup: Bool {
        didSet { ud.set(hasCompletedSetup, forKey: K.hasCompletedSetup) }
    }
    /// User-defined order for the command palette's main list. Stores
    /// command IDs (e.g. "reveal_finder", "sessions") in the order
    /// the user wants them to appear. Commands not listed here are
    /// appended at the end in their built-in default order, so a new
    /// release that adds a command never silently hides it from a
    /// user who has customised their list.
    @Published var paletteCommandOrder: [String] {
        didSet { ud.set(paletteCommandOrder, forKey: K.paletteOrder) }
    }
    /// Command IDs the user has hidden from the ⌘K palette list. The
    /// command's keyboard shortcut / menu item still works — this only
    /// removes the row from the palette. Stored as an array; order is
    /// irrelevant (membership only).
    @Published var hiddenPaletteCommands: Set<String> {
        didSet { ud.set(Array(hiddenPaletteCommands), forKey: K.hiddenPaletteCommands) }
    }
    /// Hide the tab bar entirely when there's only one tab open
    /// (more screen for the terminal, less chrome).
    @Published var hideTabBarSingleTab: Bool {
        didSet { ud.set(hideTabBarSingleTab, forKey: K.hideTabBarSingleTab) }
    }
    /// Show the floating per-pane title bar (dir name + ⌥N chip).
    /// Off = no title bar, more room for terminal output.
    @Published var showPaneTitleBar: Bool {
        didSet { ud.set(showPaneTitleBar, forKey: K.showPaneTitleBar) }
    }
    /// Surface shell-command results (libghostty OSC 133 marks): a
    /// transient ✓/✗ + duration badge in the pane's corner when a
    /// command fails or runs a while, and a notification when a
    /// long-running command finishes while you're looking elsewhere.
    /// Needs shell integration, which Ghostty enables by default.
    @Published var commandAlerts: Bool {
        didSet { ud.set(commandAlerts, forKey: K.commandAlerts) }
    }
    /// Check GitHub for a newer release each time Conterm launches. The
    /// check is silent — it only lights up the toolbar update pill when
    /// something newer exists. Manual checks always work regardless.
    @Published var autoCheckUpdates: Bool {
        didSet { ud.set(autoCheckUpdates, forKey: K.autoCheckUpdates) }
    }
    /// Show the live system-stats widget (CPU/RAM/Net) in the tab bar.
    /// Legacy flag — kept only to seed `enabledWidgets` once. Widget
    /// visibility is now driven by `enabledWidgets`.
    @Published var showSystemStats: Bool {
        didSet { ud.set(showSystemStats, forKey: K.showSystemStats) }
    }
    /// Ordered list of enabled tab-bar widgets (`WidgetKind` rawValues).
    /// Single source of truth for what the widget rail renders and in
    /// what order.
    @Published var enabledWidgets: [String] {
        didSet { ud.set(enabledWidgets, forKey: K.enabledWidgets) }
    }
    /// Per-metric visibility for the System Stats widget.
    @Published var statsShowCPU: Bool {
        didSet { ud.set(statsShowCPU, forKey: K.statsShowCPU) }
    }
    @Published var statsShowMemory: Bool {
        didSet { ud.set(statsShowMemory, forKey: K.statsShowMemory) }
    }
    @Published var statsShowNetwork: Bool {
        didSet { ud.set(statsShowNetwork, forKey: K.statsShowNetwork) }
    }
    /// Clock widget options.
    @Published var clock24Hour: Bool {
        didSet { ud.set(clock24Hour, forKey: K.clock24Hour) }
    }
    @Published var clockShowSeconds: Bool {
        didSet { ud.set(clockShowSeconds, forKey: K.clockShowSeconds) }
    }
    @Published var clockShowDate: Bool {
        didSet { ud.set(clockShowDate, forKey: K.clockShowDate) }
    }

    /// Whether a widget kind is in the enabled rail.
    func isWidgetEnabled(_ id: String) -> Bool { enabledWidgets.contains(id) }
    /// Add / remove a widget kind, preserving order (appends on enable).
    func setWidget(_ id: String, enabled: Bool) {
        var list = enabledWidgets
        if enabled {
            if !list.contains(id) { list.append(id) }
        } else {
            list.removeAll { $0 == id }
        }
        enabledWidgets = list
    }
    /// Reorder an enabled widget by one slot.
    func moveWidget(_ id: String, by delta: Int) {
        guard let i = enabledWidgets.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < enabledWidgets.count else { return }
        enabledWidgets.swapAt(i, j)
    }
    /// Vertical mode only: collapse the sidebar out of the layout so the
    /// terminal uses the full width, and float it back in (over the
    /// terminal, on the glass layer) when the cursor hits the left edge.
    @Published var autoHideSidebar: Bool {
        didSet { ud.set(autoHideSidebar, forKey: K.autoHideSidebar) }
    }
    /// Stop libghostty presenting the terminal on every display refresh
    /// (`window-vsync = false`). Conterm's window is non-opaque so the
    /// glass backdrop shows through; every surface present then makes
    /// WindowServer re-composite the whole translucent window, so a
    /// foreground pane pulls a continuous slice of a WindowServer core
    /// even while idle. With vsync off the renderer presents only when
    /// content actually changes, so an idle pane costs the compositor
    /// nothing. Trade-off: fast scroll / streaming can tear slightly.
    /// Injected into the libghostty config chain via `lastwordText()`;
    /// a relaunch guarantees the renderer's display link is rebuilt.
    @Published var lowPowerRendering: Bool {
        didSet { ud.set(lowPowerRendering, forKey: K.lowPowerRendering) }
    }
    /// Use a broadly-compatible TERM (`xterm-256color`) and standard
    /// xterm modifier sequences for `Shift`/`Option`/`Ctrl + Arrow`
    /// over SSH, so word- and line-motions work in remote vim, tmux,
    /// and similar TUIs. Trade-off: with this enabled, `Shift+Arrow`
    /// no longer extends libghostty's local text selection.
    @Published var sshCompatMode: Bool {
        didSet {
            ud.set(sshCompatMode, forKey: K.sshCompatMode)
        }
    }
    /// Write internal diagnostics to ~/Library/Logs/Conterm/conterm.log.
    /// A development aid, OFF by default. `clog` reads this same
    /// UserDefaults key directly (via `DiagnosticLog`) so the logging
    /// path needs no Preferences reference.
    @Published var diagnosticLogging: Bool {
        didSet { ud.set(diagnosticLogging, forKey: K.diagnosticLogging) }
    }

    /// Accent for the action cluster + new-tab `+`. `mono` = plain glass;
    /// a colour fills the cluster and lights the `+` yellow.
    @Published var actionAccent: ActionAccent {
        didSet { ud.set(actionAccent.rawValue, forKey: K.actionAccent) }
    }
    /// Color of the new-tab + disc, chosen independently of the action
    /// cluster's accent. `.mono` = a plain glass disc.
    @Published var newTabAccent: ActionAccent {
        didSet { ud.set(newTabAccent.rawValue, forKey: K.newTabAccent) }
    }

    /// Paint each pane on a solid opaque backing instead of letting a
    /// translucent terminal reveal the glass behind it. The desktop never
    /// re-composites under a streaming pane, so this is markedly cooler on
    /// fanless Macs — ON by default.
    @Published var opaquePanes: Bool {
        didSet { ud.set(opaquePanes, forKey: K.opaquePanes) }
    }
    /// Window background-blur radius. Initialised from the user's
    /// libghostty `background-blur` config value and kept in sync by
    /// the live Background blur slider (which also writes it back to
    /// the config). Drives the real CGS Gaussian blur via `WindowBlur`.
    /// 0 = no blur. The config file remains the persisted source of
    /// truth, so the value transfers with a Ghostty config.
    @Published var paneBlurRadius: Int = 0

    private let ud = UserDefaults.standard

    private enum K {
        static let orientation = "conterm.tabOrientation"
        static let launchAnim  = "conterm.launchAnimation"
        static let launchSound = "conterm.launchSound"
        static let launched    = "conterm.hasLaunched"
        static let sidebar     = "conterm.sidebarWidth"
        static let glassiness       = "conterm.glassiness"
        static let windowSaveState  = "conterm.rememberWindowState"
        static let confirmBeforeQuit = "conterm.confirmBeforeQuit"
        static let hasCompletedSetup = "conterm.hasCompletedSetup"
        static let paletteOrder      = "conterm.paletteCommandOrder"
        static let hiddenPaletteCommands = "conterm.hiddenPaletteCommands"
        static let hideTabBarSingleTab = "conterm.hideTabBarSingleTab"
        static let showPaneTitleBar = "conterm.showPaneTitleBar"
        static let commandAlerts    = "conterm.commandAlerts"
        static let autoCheckUpdates  = "conterm.autoCheckUpdates"
        static let showSystemStats  = "conterm.showSystemStats"
        static let enabledWidgets   = "conterm.enabledWidgets"
        static let statsShowCPU     = "conterm.statsShowCPU"
        static let statsShowMemory  = "conterm.statsShowMemory"
        static let statsShowNetwork = "conterm.statsShowNetwork"
        static let clock24Hour      = "conterm.clock24Hour"
        static let clockShowSeconds = "conterm.clockShowSeconds"
        static let clockShowDate    = "conterm.clockShowDate"
        static let autoHideSidebar  = "conterm.autoHideSidebar"
        static let lowPowerRendering = "conterm.lowPowerRendering"
        static let useDefaultConfig = "conterm.useDefaultConfig"
        static let lightGlass       = "conterm.lightGlass"
        static let themeFromConfig  = "conterm.themeFromConfig"
        static let solidGlass        = "conterm.solidGlass"   // pre-glassMode migration source
        static let glassMode         = "conterm.glassMode"
        static let liquidGlassPanels = "conterm.liquidGlassPanels"
        static let sshCompatMode    = "conterm.sshCompatMode"
        static let actionAccent     = "conterm.actionAccent"
        static let newTabAccent     = "conterm.newTabAccent"
        static let opaquePanes      = "conterm.opaquePanes"
        static let soundEffects     = "conterm.soundEffects"
        static let diagnosticLogging = "conterm.diagnosticLogging"
    }

    init() {
        let ud = UserDefaults.standard
        self.tabOrientation = TabOrientation(
            rawValue: ud.string(forKey: K.orientation) ?? TabOrientation.horizontal.rawValue
        ) ?? .horizontal
        self.launchAnimationEnabled = ud.object(forKey: K.launchAnim) as? Bool ?? true
        self.launchSoundEnabled     = ud.object(forKey: K.launchSound) as? Bool ?? true
        self.soundEffectsEnabled    = ud.object(forKey: K.soundEffects) as? Bool ?? true
        self.hasLaunched            = ud.bool(forKey: K.launched)
        // Clamp on load so a stale persisted value below the current
        // drag-handle minimum can't slip past — narrow sidebars push
        // the auto-hide icon over the native traffic lights.
        let storedWidth = ud.object(forKey: K.sidebar) as? Double ?? 180
        self.sidebarWidth           = max(260, min(360, storedWidth))
        // Default clear: the desktop reads through the glass. Frost up
        // toward 1.0 for more privacy / legibility on busy wallpapers.
        self.glassiness             = ud.object(forKey: K.glassiness) as? Double ?? 0.0
        self.rememberWindowState    = ud.object(forKey: K.windowSaveState) as? Bool ?? true
        self.confirmBeforeQuit      = ud.object(forKey: K.confirmBeforeQuit) as? Bool ?? true
        self.hasCompletedSetup      = ud.object(forKey: K.hasCompletedSetup) as? Bool ?? false
        var storedOrder             = ud.stringArray(forKey: K.paletteOrder) ?? []
        // A saved custom order that predates a built-in command would
        // push it to the bottom of the palette (reordered() appends
        // unknown IDs last). Splice late additions into their default
        // slot instead.
        if !storedOrder.isEmpty, !storedOrder.contains("agents") {
            let anchor = storedOrder.firstIndex(of: "shell_history")
                      ?? storedOrder.firstIndex(of: "sessions")
            storedOrder.insert("agents",
                               at: anchor.map { $0 + 1 } ?? storedOrder.endIndex)
            ud.set(storedOrder, forKey: K.paletteOrder)
        }
        self.paletteCommandOrder    = storedOrder
        self.hiddenPaletteCommands  = Set(ud.stringArray(forKey: K.hiddenPaletteCommands) ?? [])
        self.hideTabBarSingleTab    = ud.object(forKey: K.hideTabBarSingleTab) as? Bool ?? false
        self.showPaneTitleBar       = ud.object(forKey: K.showPaneTitleBar) as? Bool ?? true
        self.commandAlerts          = ud.object(forKey: K.commandAlerts) as? Bool ?? true
        self.autoCheckUpdates       = ud.object(forKey: K.autoCheckUpdates) as? Bool ?? true
        self.showSystemStats        = ud.object(forKey: K.showSystemStats) as? Bool ?? true
        // Seed the enabled-widget rail once from the legacy stats flag so
        // existing users keep their widget; thereafter `enabledWidgets`
        // is authoritative. Strip `agentStatus` (not a current widget
        // kind) so the stored list stays valid.
        var widgets = ud.stringArray(forKey: K.enabledWidgets)
            ?? ((ud.object(forKey: K.showSystemStats) as? Bool ?? true) ? ["systemStats"] : [])
        widgets.removeAll { $0 == "agentStatus" }
        self.enabledWidgets = widgets
        ud.set(widgets, forKey: K.enabledWidgets)
        self.statsShowCPU           = ud.object(forKey: K.statsShowCPU) as? Bool ?? true
        self.statsShowMemory        = ud.object(forKey: K.statsShowMemory) as? Bool ?? true
        self.statsShowNetwork       = ud.object(forKey: K.statsShowNetwork) as? Bool ?? true
        self.clock24Hour            = ud.object(forKey: K.clock24Hour) as? Bool ?? false
        self.clockShowSeconds       = ud.object(forKey: K.clockShowSeconds) as? Bool ?? false
        self.clockShowDate          = ud.object(forKey: K.clockShowDate) as? Bool ?? false
        self.autoHideSidebar        = ud.object(forKey: K.autoHideSidebar) as? Bool ?? false
        self.lowPowerRendering      = ud.object(forKey: K.lowPowerRendering) as? Bool ?? true
        self.useDefaultConfig       = ud.object(forKey: K.useDefaultConfig) as? Bool ?? false
        self.lightGlass             = ud.object(forKey: K.lightGlass) as? Bool ?? false
        self.themeFromConfig        = ud.object(forKey: K.themeFromConfig) as? Bool ?? false
        self.glassMode              = GlassMode(rawValue: ud.string(forKey: K.glassMode) ?? "")
            ?? ((ud.object(forKey: K.solidGlass) as? Bool ?? false) ? .solid : .glass)
        self.liquidGlassPanels      = ud.object(forKey: K.liquidGlassPanels) as? Bool ?? false
        self.sshCompatMode          = ud.object(forKey: K.sshCompatMode) as? Bool ?? false
        self.actionAccent           = ActionAccent(
            rawValue: ud.string(forKey: K.actionAccent) ?? ActionAccent.red.rawValue
        ) ?? .red
        self.newTabAccent           = ActionAccent(
            rawValue: ud.string(forKey: K.newTabAccent) ?? ActionAccent.yellow.rawValue
        ) ?? .yellow
        self.opaquePanes            = ud.object(forKey: K.opaquePanes) as? Bool ?? true
        self.diagnosticLogging      = ud.object(forKey: K.diagnosticLogging) as? Bool ?? false
        refreshPaneBlurFromConfig()
        NotificationCenter.default.addObserver(
            forName: .contermConfigReloaded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPaneBlurFromConfig() }
        }
    }

    /// First launch always shows the intro so the user sees what it does.
    /// `SPLASH_SCREEN=1` in the env forces it on, for visual testing
    /// after the first run has been completed.
    var shouldShowLaunchOverlay: Bool {
        if ProcessInfo.processInfo.environment["SPLASH_SCREEN"] != nil { return true }
        return !hasLaunched || launchAnimationEnabled
    }

    private var ghosttyConfigPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty/config")
    }
    private var contermConfigPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/conterm/config")
    }

    /// Read `background-blur` from a config file (last uncommented
    /// assignment wins, matching Ghostty's parse order). Returns nil if
    /// the key isn't present, so callers can fall through to the next
    /// config in the chain. `true` → 20 (Ghostty's default radius),
    /// `false` → 0, integers pass through.
    private func backgroundBlur(in path: String) -> Int? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        var value: Int? = nil
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.lowercased().hasPrefix("background-blur"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let v = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            switch v {
            case "true":  value = 20
            case "false": value = 0
            default:      value = Int(v) ?? 0
            }
        }
        return value
    }

    /// Does a config file contain ANY uncommented setting (i.e. the
    /// user actually uses it, vs the all-commented seed template)?
    private func hasActiveSettings(in path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return true
        }
        return false
    }

    /// The config file the Desktop blur slider should edit — i.e. the
    /// one the user actually uses, so the change takes effect and lands
    /// where they'd expect:
    ///   1. whichever file already defines `background-blur` (conterm
    ///      wins since it's loaded last / highest priority);
    ///   2. else the file the user otherwise configures with;
    ///   3. else the conterm overrides file.
    var backgroundBlurConfigTarget: String {
        if backgroundBlur(in: contermConfigPath) != nil { return contermConfigPath }
        if backgroundBlur(in: ghosttyConfigPath) != nil { return ghosttyConfigPath }
        if hasActiveSettings(in: contermConfigPath) { return contermConfigPath }
        if FileManager.default.fileExists(atPath: ghosttyConfigPath) { return ghosttyConfigPath }
        return contermConfigPath
    }

    /// Sync `paneBlurRadius` to the EFFECTIVE `background-blur` libghostty
    /// will use: the conterm config's value if set, else the Ghostty
    /// config's, else 0. Drives the Desktop blur slider's position.
    func refreshPaneBlurFromConfig() {
        paneBlurRadius = backgroundBlur(in: contermConfigPath)
            ?? backgroundBlur(in: ghosttyConfigPath)
            ?? 0
    }

    /// Write the `background-blur` value into the config the user uses
    /// (see `backgroundBlurConfigTarget`) and return the path written,
    /// so the caller can reload libghostty. Replaces the first
    /// uncommented assignment if present, otherwise appends one.
    @discardableResult
    func writeBackgroundBlurToConfig(_ value: Int) -> String {
        let path = backgroundBlurConfigTarget
        var lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
        // Remove EVERY existing uncommented background-blur assignment
        // first. Leaving duplicates was the bug: libghostty uses the
        // LAST one, so editing the first line silently did nothing when
        // a stale later line (e.g. a leftover "background-blur = 0")
        // overrode it. Collapse to a single authoritative line.
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#")
                && t.lowercased().hasPrefix("background-blur")
                && t.contains("=")
        }
        lines.append("background-blur = \(value)")
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        try? lines.joined(separator: "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
