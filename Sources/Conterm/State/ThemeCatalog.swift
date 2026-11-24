import AppKit
import Combine
import Foundation
import os
import SwiftUI

/// Loads the theme catalog, bundled libghostty themes
/// (`Conterm.app/Contents/Resources/ghostty/themes/`) plus the user's own
/// (`~/.config/conterm/themes`), and parses each file just enough to render a swatch grid in Settings → Appearance.
@MainActor
final class ThemeCatalog: ObservableObject {
    struct Theme: Identifiable, Hashable {
        let id: String          // file name (e.g. "Tokyo Night")
        let name: String        // human label (same as id, just renamed)
        let background: Color
        let foreground: Color
        let accent: Color       // ANSI 4 (blue) — most themes' "accent" register
        let warn: Color         // ANSI 3 (yellow)
        let isDark: Bool

        // Equatable + Hashable on id alone — name + colors are derived.
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var themes: [Theme] = []
    @Published private(set) var isLoading = false
    @Published var current: String?     // currently-applied theme name

    /// Init is intentionally cheap — it only reads ONE config line.
    /// Parsing the ~460 bundled theme files is deferred to the first
    /// time Settings → Appearance asks for them (`ensureLoaded`), and
    /// even then it runs OFF the main thread. Doing it in init() blocked
    /// the main thread during `applicationDidFinishLaunching`, freezing
    /// the launch animation (and tripping the OS launch watchdog on
    /// slower machines).
    init() {
        current = UserConfigStore.managedThemeID() ?? UserConfigStore.read(key: "theme")
    }

    func reloadCurrent() {
        current = UserConfigStore.managedThemeID() ?? UserConfigStore.read(key: "theme")
    }

    private weak var prefs: Preferences?
    private var appearanceObservation: AnyCancellable?
    private var followObservation: AnyCancellable?
    private var sourceObservation: AnyCancellable?

    /// Wire follow-system mode once, at launch, so it works while Settings
    /// is closed. The hops go through the main queue: `@Published` fires
    /// before the new value is stored, and Preferences' own `didSet` (which
    /// saves or restores the manual tint) must run first.
    func bind(_ prefs: Preferences) {
        self.prefs = prefs
        followObservation = prefs.$followSystemAppearance
            .removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated { self?.setFollowSystem(on) }
            }
        // On hands the colors back to the config; off takes them again for
        // the followed slot, or leaves them until a theme is picked.
        sourceObservation = prefs.$themeFromConfig
            .removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    if on { self?.followConfig() } else { self?.applyFollowedSlot() }
                }
            }
        appearanceObservation = DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.prefs?.syncLightGlassToSystem()
                    self?.applyFollowedSlot()
                }
            }
        // macOS may have switched while Conterm wasn't running.
        applyFollowedSlot()
    }

    private var isScanning = false

    /// Scan the theme folders in the background, each time Appearance
    /// opens, so a theme file added or edited meanwhile shows up. Results
    /// publish on the main actor when ready; the picker shows a spinner
    /// via `isLoading` until the first ones.
    func ensureLoaded() {
        guard !isScanning else { return }
        isScanning = true
        isLoading = themes.isEmpty
        let dirs = Self.themeDirectories()
        Task.detached(priority: .userInitiated) {
            let parsed = Self.parseAll(in: dirs)
            await MainActor.run {
                Self.forgetResolvedURLs()
                self.themes = parsed
                self.isLoading = false
                self.isScanning = false
            }
        }
    }

    /// Pure, off-main parse of every theme file in `dir`. `nonisolated`
    /// + `static` so it can run on a background executor without
    /// touching `self`'s main-actor state.
    nonisolated private static func parseAll(in dirs: [URL]) -> [Theme] {
        var byID: [String: Theme] = [:]
        // Later directories win, so a user theme shadows a bundled one.
        for dir in dirs {
            for name in themeNames(in: dir) {
                let path = dir.appendingPathComponent(name).path
                guard let theme = parse(path: path, name: name) else {
                    clog("conterm: skipped theme \(path): needs background and foreground as #RRGGBB")
                    continue
                }
                byID[name] = theme
            }
        }
        var loaded = Array(byID.values)
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return loaded
    }

    /// Bundled libghostty themes, then the user's own in
    /// `~/.config/conterm/themes` (Ghostty theme-file syntax).
    nonisolated static func themeDirectories() -> [URL] {
        var dirs: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes") {
            dirs.append(bundled)
        }
        dirs.append(userThemeDirectory)
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static var userThemeDirectory: URL {
        URL(fileURLWithPath: InstanceState.configPath("themes"), isDirectory: true)
    }

    nonisolated private static func themeNames(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".md") }
    }

    struct URLKey: Hashable { let id: String; let dirs: [URL] }
    /// Resolved theme files: windows look their theme up on every config
    /// reload, on the main thread. Valid until the next catalog scan.
    nonisolated static let resolvedURLs = OSAllocatedUnfairLock<[URLKey: URL]>(initialState: [:])

    nonisolated static func forgetResolvedURLs() {
        resolvedURLs.withLock { $0.removeAll() }
    }

    /// The file behind a theme id, by the picker's own rule (`parseAll`): the
    /// last directory holding that exact name with a theme that parses, else
    /// the same ignoring case. Names are matched by listing, since a path
    /// lookup ignores case on APFS.
    nonisolated static func url(forThemeID id: String,
                                in dirs: [URL] = themeDirectories()) -> URL? {
        let key = URLKey(id: id, dirs: dirs)
        if let known = resolvedURLs.withLock({ $0[key] }) { return known }
        let files = dirs.reversed().flatMap { dir in
            themeNames(in: dir).sorted().map(dir.appendingPathComponent)
        }
        func firstTheme(_ matches: (String) -> Bool) -> URL? {
            files.first {
                let name = $0.lastPathComponent
                return matches(name) && parse(path: $0.path, name: name) != nil
            }
        }
        let found = firstTheme { $0 == id }
            ?? firstTheme { $0.caseInsensitiveCompare(id) == .orderedSame }
        if let found { resolvedURLs.withLock { $0[key] = found } }
        return found
    }

    nonisolated private static func parse(path: String, name: String) -> Theme? {
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        var bg: Color?
        var fg: Color?
        var palette: [Int: Color] = [:]
        for raw in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let lhs = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rhs = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch lhs {
            case "background":
                bg = Color(hex: rhs)
            case "foreground":
                fg = Color(hex: rhs)
            case "palette":
                // "0=#262427" — index then hex
                guard let split = rhs.firstIndex(of: "=") else { continue }
                let idxStr = rhs[..<split].trimmingCharacters(in: .whitespaces)
                let hex = rhs[rhs.index(after: split)...].trimmingCharacters(in: .whitespaces)
                if let i = Int(idxStr), let c = Color(hex: String(hex)) {
                    palette[i] = c
                }
            default: continue
            }
        }
        guard let bg, let fg else { return nil }
        return Theme(
            id: name,
            name: name,
            background: bg,
            foreground: fg,
            accent: palette[4] ?? palette[12] ?? fg,
            warn: palette[3] ?? palette[11] ?? fg,
            isDark: bg.luminance < 0.5
        )
    }

    /// Apply a theme: writes the theme's colors as an explicit managed
    /// block at the end of the user's config (so they override any
    /// hardcoded background/palette, including a `config-file`-included
    /// Ghostty config) and triggers a libghostty reload so it's live.
    func apply(_ theme: Theme) { apply(id: theme.id) }

    func apply(id: String) {
        let colors = Self.colorLines(forThemeID: id)
        if colors.isEmpty {
            // Theme file unreadable — fall back to a bare key. Won't win
            // against hardcoded colors, but it's better than a silent no-op.
            UserConfigStore.write(key: "theme",
                                   value: UserConfigStore.quote(id))
        } else {
            UserConfigStore.writeManagedThemeBlock(themeID: id,
                                                    colorLines: colors)
        }
        current = id
        Ghostty.App.shared?.reloadConfig()
    }

    /// The slot to write for an appearance, or nil to leave the block
    /// alone: the user's config owns the colors, the slot is empty, or
    /// it's already in the managed block (`current`).
    nonisolated static func slotToApply(fromConfig: Bool, light: String?, dark: String?,
                                        lightAppearance: Bool, current: String?) -> String? {
        guard !fromConfig, let id = lightAppearance ? light : dark, id != current else { return nil }
        return id
    }

    /// While following macOS, write the slot for the current appearance as
    /// the usual explicit-color block. Skipped when the user's config owns
    /// the colors, the slot is empty or missing, or it's already applied.
    func applyFollowedSlot() {
        guard let prefs, prefs.followSystemAppearance else { return }
        guard let id = Self.slotToApply(fromConfig: prefs.themeFromConfig,
                                        light: prefs.lightThemeID, dark: prefs.darkThemeID,
                                        lightAppearance: !Self.systemIsDark,
                                        current: UserConfigStore.managedThemeID())
        else { return }
        writeBlock(id: id)
    }

    /// Put a theme on without a swatch pick: the user's own `theme =` line
    /// stays, and an unreadable theme changes nothing.
    private func writeBlock(id: String) {
        let colors = Self.colorLines(forThemeID: id)
        guard !colors.isEmpty else { return }
        UserConfigStore.writeManagedThemeBlock(themeID: id, colorLines: colors,
                                               keepingThemeLine: true)
        current = id
        Ghostty.App.shared?.reloadConfig()
    }

    /// Back to the managed block from before following, or to none.
    private func restoreManualTheme(_ id: String?) {
        guard let id, id != UserConfigStore.managedThemeID() ?? "" else { return }
        guard id.isEmpty else { return writeBlock(id: id) }
        UserConfigStore.removeManagedThemeBlock()
        reloadCurrent()
        Ghostty.App.shared?.reloadConfig()
    }

    /// The follow-macOS switch flipped. Runs after Preferences has synced
    /// (on) or restored (off) the glass tint and theme source; see `bind`.
    func setFollowSystem(_ on: Bool) {
        guard let prefs else { return }
        if on {
            // Seed empty or stale slots from the current pick so the first
            // toggle never blanks the terminal.
            let seed = current.flatMap { Self.url(forThemeID: $0)?.lastPathComponent }
            if prefs.lightThemeID.flatMap({ Self.url(forThemeID: $0) }) == nil { prefs.lightThemeID = seed }
            if prefs.darkThemeID.flatMap({ Self.url(forThemeID: $0) }) == nil { prefs.darkThemeID = seed }
            applyFollowedSlot()
        } else if !prefs.themeFromConfig {
            restoreManualTheme(prefs.manualThemeID)
        }
    }

    /// A swatch tap: a single theme, or the slot being edited while
    /// following macOS. The slot for the appearance on screen applies now;
    /// the other one applies when macOS switches.
    func pick(_ theme: Theme, editingLight: Bool, prefs: Preferences) {
        guard prefs.followSystemAppearance else { return apply(theme) }
        if editingLight { prefs.lightThemeID = theme.id } else { prefs.darkThemeID = theme.id }
        applyFollowedSlot()
    }

    /// The swatch to ring: the edited slot while following macOS.
    func selectedID(editingLight: Bool, prefs: Preferences) -> String? {
        guard prefs.followSystemAppearance else { return current }
        return editingLight ? prefs.lightThemeID : prefs.darkThemeID
    }

    /// Hand color control back to the user's own config: remove the
    /// managed block and reload. The included Ghostty config (and any
    /// hardcoded background/palette) then sets the colors again.
    func followConfig() {
        UserConfigStore.removeManagedThemeBlock()
        current = nil
        Ghostty.App.shared?.reloadConfig()
    }

    /// Keys a user theme may set. Anything else (`keybind`, `font-size`)
    /// would reach the managed block, or a window's config after the
    /// last-word block, and override settings a theme doesn't own.
    nonisolated private static let userThemeKeys: Set<String> = [
        "background", "foreground", "palette", "bold-color",
        "cursor-color", "cursor-text", "selection-background", "selection-foreground",
        "search-background", "search-foreground",
        "search-selected-background", "search-selected-foreground",
        "split-divider-color", "unfocused-split-fill",
    ]

    /// Verbatim color-defining lines from a theme file: every `key = value`
    /// of a bundled theme except `theme`/`config-file` (which a theme file
    /// can't set anyway), only the color keys of a user theme. Emitted into the user config so the theme's
    /// colors land as explicit keys that override a hardcoded palette.
    /// Also used by `Ghostty.App.makeConfig(themeID:)` to build a
    /// per-window config variant without touching the global file.
    nonisolated static func colorLines(forThemeID id: String,
                                       in dirs: [URL] = themeDirectories(),
                                       userDirectory: URL = userThemeDirectory) -> [String] {
        guard let url = url(forThemeID: id, in: dirs),
              let body = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let isUser = url.deletingLastPathComponent().path == userDirectory.path
        var out: [String] = []
        for raw in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key == "theme" || key == "config-file" { continue }
            if isUser && !userThemeKeys.contains(key) { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out.append("\(key) = \(value)")
        }
        return out
    }

    /// `id` if it still resolves to a readable theme file, else nil.
    /// A restored per-window theme whose file is gone must drop to
    /// following the global theme — keeping the dead id would leave
    /// the picker showing a selection nothing can render.
    nonisolated static func validatedThemeID(_ id: String?) -> String? {
        guard let id, !id.isEmpty,
              !colorLines(forThemeID: id).isEmpty else { return nil }
        return id
    }

    /// Whether macOS itself is in Dark Mode: the one reading every follower
    /// uses. The global defaults domain is already current when
    /// `AppleInterfaceThemeChangedNotification` fires, and Conterm's pinned
    /// window appearances never touch it.
    nonisolated static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// The theme a window actually renders: its fixed theme, or —
    /// when following macOS — the slot for the current appearance,
    /// falling back to the other slot so a half-filled pair still
    /// themes the window. Nil = follow the global theme.
    nonisolated static func effectiveThemeID(fixed: String?,
                                             light: String?,
                                             dark: String?,
                                             followsSystem: Bool,
                                             isDark: Bool) -> String? {
        guard followsSystem else { return fixed }
        return isDark ? (dark ?? light) : (light ?? dark)
    }
}

// MARK: - Color helpers

private extension Color {
    /// Parse `#RRGGBB` (no alpha) — libghostty themes are always
    /// six-digit hex.
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        let r = Double((n >> 16) & 0xFF) / 255.0
        let g = Double((n >> 8) & 0xFF) / 255.0
        let b = Double(n & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    /// Approx perceptual brightness 0…1. Used to flag dark vs light
    /// themes so the picker can group / visually differentiate them.
    var luminance: Double {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return 0.2126 * Double(ns.redComponent)
             + 0.7152 * Double(ns.greenComponent)
             + 0.0722 * Double(ns.blueComponent)
    }
}
