import AppKit
import Foundation
import SwiftUI

/// Loads the bundled libghostty theme catalog (
/// `Conterm.app/Contents/Resources/ghostty/themes/`) and parses each
/// file just enough to render a swatch grid in Settings → Appearance.
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

    private var didStartLoad = false

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

    /// Kick off a one-time background parse. Safe to call repeatedly
    /// (no-ops after the first call). Results publish on the main actor
    /// when ready; the picker shows a spinner via `isLoading` until then.
    func ensureLoaded() {
        guard !didStartLoad else { return }
        didStartLoad = true
        isLoading = true
        let dir = themesDirectoryURL()
        Task.detached(priority: .userInitiated) {
            let parsed = await Self.parseAll(in: dir)
            await MainActor.run {
                self.themes = parsed
                self.isLoading = false
            }
        }
    }

    /// Pure, off-main parse of every theme file in `dir`. `nonisolated`
    /// + `static` so it can run on a background executor without
    /// touching `self`'s main-actor state.
    nonisolated private static func parseAll(in dir: URL?) -> [Theme] {
        guard let dir else { return [] }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var loaded: [Theme] = []
        for name in names {
            if name.hasPrefix(".") || name.hasSuffix(".md") { continue }
            let path = dir.appendingPathComponent(name).path
            guard let theme = parse(path: path, name: name) else { continue }
            loaded.append(theme)
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return loaded
    }

    nonisolated private func themesDirectoryURL() -> URL? {
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty/themes"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
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
    func apply(_ theme: Theme) {
        let colors = Self.colorLines(forThemeID: theme.id)
        if colors.isEmpty {
            // Theme file unreadable — fall back to a bare key. Won't win
            // against hardcoded colors, but it's better than a silent no-op.
            UserConfigStore.write(key: "theme",
                                   value: UserConfigStore.quote(theme.id))
        } else {
            UserConfigStore.writeManagedThemeBlock(themeID: theme.id,
                                                    colorLines: colors)
        }
        current = theme.id
        Ghostty.App.shared?.reloadConfig()
    }

    /// Hand color control back to the user's own config: remove the
    /// managed block and reload. The included Ghostty config (and any
    /// hardcoded background/palette) then sets the colors again.
    func followConfig() {
        UserConfigStore.removeManagedThemeBlock()
        current = nil
        Ghostty.App.shared?.reloadConfig()
    }

    /// Verbatim color-defining lines from a bundled theme file: every
    /// `key = value` except `theme`/`config-file` (which a theme file
    /// can't set anyway). Emitted into the user config so the theme's
    /// colors land as explicit keys that override a hardcoded palette.
    nonisolated private static func colorLines(forThemeID id: String) -> [String] {
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty/themes") else { return [] }
        let path = dir.appendingPathComponent(id).path
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var out: [String] = []
        for raw in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key == "theme" || key == "config-file" { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out.append("\(key) = \(value)")
        }
        return out
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
