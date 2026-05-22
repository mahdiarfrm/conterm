import Combine
import Foundation
import SwiftUI

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
    @Published var windowOpacity: Double {
        didSet { ud.set(windowOpacity, forKey: K.opacity) }
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
    /// "Safe mode" recovery switch. OFF by default: Conterm uses your
    /// config (~/.config/conterm/config has top priority). Turn ON to
    /// boot on Ghostty's genuine defaults and ignore your config —
    /// useful when a config edit breaks the terminal so you can fix
    /// the file. Applied live via a config reload.
    @Published var useDefaultConfig: Bool {
        didSet { ud.set(useDefaultConfig, forKey: K.useDefaultConfig) }
    }
    /// Roll-back switch. `false` (default) = the new real liquid-glass
    /// backdrop (always-on blur, slider = blur radius, refraction
    /// highlights, Reduce-Transparency fallback). `true` = the exact
    /// previous backdrop, untouched, for instant revert if the new
    /// look regresses anywhere.
    @Published var useLegacyGlass: Bool {
        didSet { ud.set(useLegacyGlass, forKey: K.useLegacyGlass) }
    }
    /// Remember window position + size between launches. macOS handles
    /// the actual persistence via NSWindow.setFrameAutosaveName.
    @Published var rememberWindowState: Bool {
        didSet { ud.set(rememberWindowState, forKey: K.windowSaveState) }
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

    private let ud = UserDefaults.standard

    private enum K {
        static let orientation = "conterm.tabOrientation"
        static let launchAnim  = "conterm.launchAnimation"
        static let launchSound = "conterm.launchSound"
        static let opacity     = "conterm.windowOpacity"
        static let launched    = "conterm.hasLaunched"
        static let sidebar     = "conterm.sidebarWidth"
        static let glassiness       = "conterm.glassiness"
        static let windowSaveState  = "conterm.rememberWindowState"
        static let hideTabBarSingleTab = "conterm.hideTabBarSingleTab"
        static let showPaneTitleBar = "conterm.showPaneTitleBar"
        static let showSystemStats  = "conterm.showSystemStats"
        static let autoHideSidebar  = "conterm.autoHideSidebar"
        static let batterySavingMode = "conterm.batterySavingMode"
        static let useLegacyGlass   = "conterm.useLegacyGlass"
        static let useDefaultConfig = "conterm.useDefaultConfig"
        static let lightGlass       = "conterm.lightGlass"
    }

    init() {
        let ud = UserDefaults.standard
        self.tabOrientation = TabOrientation(
            rawValue: ud.string(forKey: K.orientation) ?? TabOrientation.horizontal.rawValue
        ) ?? .horizontal
        self.launchAnimationEnabled = ud.object(forKey: K.launchAnim) as? Bool ?? true
        self.launchSoundEnabled     = ud.object(forKey: K.launchSound) as? Bool ?? true
        self.windowOpacity          = ud.object(forKey: K.opacity) as? Double ?? 0.55
        self.hasLaunched            = ud.bool(forKey: K.launched)
        self.sidebarWidth           = ud.object(forKey: K.sidebar) as? Double ?? 180
        // Default 0.25 = mostly liquid with a hint of frost. Users
        // who liked the old chrome can crank to 1.0.
        self.glassiness             = ud.object(forKey: K.glassiness) as? Double ?? 0.25
        self.rememberWindowState    = ud.object(forKey: K.windowSaveState) as? Bool ?? true
        self.hideTabBarSingleTab    = ud.object(forKey: K.hideTabBarSingleTab) as? Bool ?? false
        self.showPaneTitleBar       = ud.object(forKey: K.showPaneTitleBar) as? Bool ?? true
        self.showSystemStats        = ud.object(forKey: K.showSystemStats) as? Bool ?? true
        self.autoHideSidebar        = ud.object(forKey: K.autoHideSidebar) as? Bool ?? false
        self.batterySavingMode      = ud.object(forKey: K.batterySavingMode) as? Bool ?? true
        self.useLegacyGlass         = ud.object(forKey: K.useLegacyGlass) as? Bool ?? false
        self.useDefaultConfig       = ud.object(forKey: K.useDefaultConfig) as? Bool ?? false
        self.lightGlass             = ud.object(forKey: K.lightGlass) as? Bool ?? false
    }

    /// First launch always shows the intro so the user sees what it does.
    var shouldShowLaunchOverlay: Bool {
        !hasLaunched || launchAnimationEnabled
    }
}
