import Foundation
import Testing
@testable import Conterm

/// Follow-system mode rewrites the managed block with one slot's colors;
/// `slotToApply` decides which slot, or whether to leave the block alone.
struct ThemeFollowTests {
    @Test func picksTheSlotForTheAppearance() {
        #expect(ThemeCatalog.slotToApply(fromConfig: false, light: "L", dark: "D",
                                         lightAppearance: true, current: "D") == "L")
        #expect(ThemeCatalog.slotToApply(fromConfig: false, light: "L", dark: "D",
                                         lightAppearance: false, current: "L") == "D")
    }

    @Test func leavesTheBlockAlone() {
        // "Use theme from terminal config" owns the colors.
        #expect(ThemeCatalog.slotToApply(fromConfig: true, light: "L", dark: "D",
                                         lightAppearance: true, current: nil) == nil)
        // Empty slot: keep whatever is applied rather than blanking it.
        #expect(ThemeCatalog.slotToApply(fromConfig: false, light: nil, dark: "D",
                                         lightAppearance: true, current: "D") == nil)
        // Already applied: no config rewrite and reload.
        #expect(ThemeCatalog.slotToApply(fromConfig: false, light: "L", dark: "D",
                                         lightAppearance: true, current: "L") == nil)
    }
}

/// Which file a theme id means, and what a user theme may put in the config.
struct UserThemeTests {
    private func withDirs(_ body: (_ bundled: URL, _ user: URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conterm-themes-\(UUID().uuidString)")
        let bundled = root.appendingPathComponent("bundled"), user = root.appendingPathComponent("user")
        for d in [bundled, user] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try body(bundled, user)
    }
    private func write(_ text: String, _ dir: URL, _ name: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private let colors = "background = #000000\nforeground = #ffffff\n"

    @Test func aUserThemeSetsOnlyColors() throws {
        try withDirs { bundled, user in
            try write(colors + "palette = 1=#ff0000\ncursor-color = #00ff00\nselection-background = #222222\n"
                + "keybind = ctrl+a=quit\nfont-size = 18\ncommand = /bin/false\nselection-clear-on-typing = false\ncursor-style = bar\n", user, "Mine")
            let lines = ThemeCatalog.colorLines(forThemeID: "Mine", in: [bundled, user], userDirectory: user)
            #expect(lines == ["background = #000000", "foreground = #ffffff", "palette = 1=#ff0000",
                              "cursor-color = #00ff00", "selection-background = #222222"])
        }
    }

    @Test func aBundledThemeIsCopiedVerbatim() throws {
        try withDirs { bundled, user in
            try write(colors + "cursor-style = bar\n", bundled, "B")
            let lines = ThemeCatalog.colorLines(forThemeID: "B", in: [bundled, user], userDirectory: user)
            #expect(lines.last == "cursor-style = bar")
        }
    }

    @Test func theAppliedFileIsTheListedOne() throws {
        try withDirs { bundled, user in
            for name in ["Shadowed", "Broken", "Cased"] { try write(colors, bundled, name) }
            try write(colors, user, "Shadowed")
            try write("not a theme", user, "Broken")
            try write(colors, user, "cased")
            func dir(_ id: String) -> String? {
                ThemeCatalog.url(forThemeID: id, in: [bundled, user])?
                    .deletingLastPathComponent().lastPathComponent
            }
            #expect(dir("Shadowed") == "user")
            #expect(dir("Broken") == "bundled")
            #expect(dir("Cased") == "bundled")
            #expect(dir("cased") == "user")
            #expect(dir("../bundled/Cased") == nil)
        }
    }
}

/// The theme source goes off while following macOS and comes back after.
@MainActor
@Suite(.serialized) struct FollowRestoresThemeSourceTests {
    @Test(arguments: [true, false]) func roundTrip(fromConfig: Bool) {
        let ud = UserDefaults.standard
        let keys = ["followSystemAppearance", "themeFromConfig", "lightGlass", "manualLightGlass", "manualThemeFromConfig"]
            .map { "conterm.\($0)" }
        for k in keys { ud.removeObject(forKey: k) }
        defer { for k in keys { ud.removeObject(forKey: k) } }
        let prefs = Preferences()
        prefs.themeFromConfig = fromConfig
        prefs.followSystemAppearance = true
        #expect(!prefs.themeFromConfig)
        prefs.followSystemAppearance = false
        #expect(prefs.themeFromConfig == fromConfig)
    }
}
