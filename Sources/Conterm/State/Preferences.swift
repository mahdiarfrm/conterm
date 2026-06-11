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
    enum TabOrientation: String, CaseIterable, Identifiable {
        case horizontal, vertical
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
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
    /// Glass clarity, 0…1. In the new liquid-glass backdrop this drives
    /// the REAL CGS background-blur radius: 0 ≈ clear glass (light
    /// blur), 1 ≈ heavy frost. (In the legacy backdrop it instead
    /// cross-faded a dark material's opacity.)
    @Published var glassiness: Double {
        didSet { ud.set(glassiness, forKey: K.glassiness) }
    }
    /// Light vs dark Liquid Glass. OFF (default) = dark glass, which
    /// the chrome's text colors are tuned for. ON = light-appearance
    /// glass (the macOS 26 material + vibrancy render lighter).
    @Published var lightGlass: Bool {
        didSet { ud.set(lightGlass, forKey: K.lightGlass) }
    }
    /// Use frosted Liquid Glass (macOS 26 `NSGlassEffectView`) for the
    /// modal overlay panels — Settings, Command Palette, Search,
    /// Notifications, Rename, GroupRename, floating sidebar. OFF
    /// (default) keeps them on the original `hudWindow` vibrancy.
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
    @Published var showSystemStats: Bool {
        didSet { ud.set(showSystemStats, forKey: K.showSystemStats) }
    }
    /// Vertical mode only: collapse the sidebar out of the layout so the
    /// terminal uses the full width, and float it back in (over the
    /// terminal, on the glass layer) when the cursor hits the left edge.
    @Published var autoHideSidebar: Bool {
        didSet { ud.set(autoHideSidebar, forKey: K.autoHideSidebar) }
    }
    /// When ON, Conterm drops the Liquid Glass backdrop to a cheap
    /// flat fill whenever the window isn't visible to the user
    /// (occluded, different Space, or app not active). Dramatically
    /// cuts GPU compositor cost in the background. When OFF, the
    /// backdrop stays as real Liquid Glass at all times.
    @Published var batterySavingMode: Bool {
        didSet { ud.set(batterySavingMode, forKey: K.batterySavingMode) }
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
    /// Render the per-pane agent status pill (Claude Code / opencode)
    /// with reduced animations: a static colored border instead of
    /// the rotating mark, sweep glow, and attention pulse. The pill
    /// still shows ready / thinking / needs-you states; it just stops
    /// continuously redrawing, which lowers GPU cost during long
    /// agent sessions.
    @Published var agentPillLite: Bool {
        didSet { ud.set(agentPillLite, forKey: K.agentPillLite) }
    }

    /// The bell / search / ⌘K cluster wears the flat Conterm-red fill;
    /// off returns it to the monochrome glass capsule.
    @Published var redActionBar: Bool {
        didSet { ud.set(redActionBar, forKey: K.redActionBar) }
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
        static let autoHideSidebar  = "conterm.autoHideSidebar"
        static let batterySavingMode = "conterm.batterySavingMode"
        static let useDefaultConfig = "conterm.useDefaultConfig"
        static let lightGlass       = "conterm.lightGlass"
        static let liquidGlassPanels = "conterm.liquidGlassPanels"
        static let sshCompatMode    = "conterm.sshCompatMode"
        static let agentPillLite    = "conterm.agentPillLite"
        static let redActionBar     = "conterm.redActionBar"
        static let soundEffects     = "conterm.soundEffects"
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
        // Default 0.25 = mostly liquid with a hint of frost. Users
        // who liked the old chrome can crank to 1.0.
        self.glassiness             = ud.object(forKey: K.glassiness) as? Double ?? 0.25
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
        self.autoHideSidebar        = ud.object(forKey: K.autoHideSidebar) as? Bool ?? false
        self.batterySavingMode      = ud.object(forKey: K.batterySavingMode) as? Bool ?? true
        self.useDefaultConfig       = ud.object(forKey: K.useDefaultConfig) as? Bool ?? false
        self.lightGlass             = ud.object(forKey: K.lightGlass) as? Bool ?? false
        self.liquidGlassPanels      = ud.object(forKey: K.liquidGlassPanels) as? Bool ?? false
        self.sshCompatMode          = ud.object(forKey: K.sshCompatMode) as? Bool ?? false
        self.agentPillLite          = ud.object(forKey: K.agentPillLite) as? Bool ?? false
        self.redActionBar           = ud.object(forKey: K.redActionBar) as? Bool ?? true
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
