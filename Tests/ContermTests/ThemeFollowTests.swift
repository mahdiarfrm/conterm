import Foundation
import GhosttyKit
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

    @Test func aCaseOnlyDifferenceStillResolves() throws {
        try withDirs { bundled, user in
            try write(colors, bundled, "Nord")
            try write("not a theme", user, "NORD")
            #expect(ThemeCatalog.url(forThemeID: "nord", in: [bundled, user])?.lastPathComponent == "Nord")
            #expect(ThemeCatalog.url(forThemeID: "nor", in: [bundled, user]) == nil)
        }
    }

    @Test func aResolvedFileIsKeptUntilTheNextScan() throws {
        try withDirs { bundled, user in
            func dir() -> String? {
                ThemeCatalog.url(forThemeID: "Mine", in: [bundled, user])?
                    .deletingLastPathComponent().lastPathComponent
            }
            #expect(dir() == nil)
            try write(colors, bundled, "Mine")
            #expect(dir() == "bundled")
            try write(colors, user, "Mine")
            #expect(dir() == "bundled")
            ThemeCatalog.forgetResolvedURLs()
            #expect(dir() == "user")
        }
    }
}

/// Turning follow-system mode on and off leaves the user's config and manual
/// picks as they were. Runs on a scratch config file and scratch themes.
@MainActor
@Suite(.serialized) struct FollowRestoresThemeTests {
    private let theirs = "font-size = 14\ntheme = Dracula\n"

    private func withStore(config: String,
                           _ body: (_ prefs: Preferences, _ file: () -> String) throws -> Void) throws {
        let ud = InstanceState.defaults
        let keys = ["followSystemAppearance", "themeFromConfig", "lightGlass", "lightThemeID", "darkThemeID",
                    "manualLightGlass", "manualThemeFromConfig", "manualThemeID"].map { "conterm.\($0)" }
        let saved = keys.map { ud.object(forKey: $0) }
        for k in keys { ud.removeObject(forKey: k) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conterm-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let realPath = UserConfigStore.path
        UserConfigStore.path = root.appendingPathComponent("config").path
        let names = ["Follow Test A", "Follow Test B", "Follow Test Picked"]
        let urlKeys = names.map { ThemeCatalog.URLKey(id: $0, dirs: ThemeCatalog.themeDirectories()) }
        defer {
            for (k, v) in zip(keys, saved) {
                if let v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) }
            }
            UserConfigStore.path = realPath
            ThemeCatalog.resolvedURLs.withLock { for k in urlKeys { $0[k] = nil } }
            try? FileManager.default.removeItem(at: root)
        }
        for (name, key) in zip(names, urlKeys) {
            let url = root.appendingPathComponent(name)
            try "background = #000000\nforeground = #ffffff\n".write(to: url, atomically: true, encoding: .utf8)
            ThemeCatalog.resolvedURLs.withLock { $0[key] = url }
        }
        try config.write(toFile: UserConfigStore.path, atomically: true, encoding: .utf8)
        try body(Preferences()) {
            (try? String(contentsOfFile: UserConfigStore.path, encoding: .utf8)) ?? ""
        }
    }

    private func setSlots(_ prefs: Preferences, _ id: String) {
        prefs.lightThemeID = id
        prefs.darkThemeID = id
    }

    @Test(arguments: [true, false]) func roundTrip(fromConfig: Bool) throws {
        try withStore(config: "") { prefs, _ in
            prefs.themeFromConfig = fromConfig
            prefs.followSystemAppearance = true
            #expect(!prefs.themeFromConfig)
            prefs.followSystemAppearance = false
            #expect(prefs.themeFromConfig == fromConfig)
        }
    }

    /// Every way a slot gets written: Follow on, macOS switching, a slot
    /// pick, config colors off again, and a relaunch.
    @Test func followingKeepsTheUsersThemeLine() throws {
        try withStore(config: theirs) { prefs, file in
            prefs.themeFromConfig = true
            setSlots(prefs, "Follow Test A")
            let catalog = ThemeCatalog()
            catalog.bind(prefs)
            prefs.followSystemAppearance = true
            catalog.setFollowSystem(true)
            #expect(UserConfigStore.managedThemeID() == "Follow Test A")
            #expect(file().hasPrefix(theirs))

            setSlots(prefs, "Follow Test B")
            catalog.applyFollowedSlot()
            #expect(UserConfigStore.managedThemeID() == "Follow Test B")
            #expect(file().hasPrefix(theirs))

            catalog.followConfig()
            #expect(file() == theirs)

            let reloadedPrefs = Preferences(), relaunched = ThemeCatalog()
            relaunched.bind(reloadedPrefs)
            #expect(UserConfigStore.managedThemeID() == "Follow Test B")
            #expect(file().hasPrefix(theirs))

            reloadedPrefs.followSystemAppearance = false
            relaunched.setFollowSystem(false)
            #expect(reloadedPrefs.themeFromConfig)
            relaunched.followConfig()
            #expect(file() == theirs)
        }
    }

    @Test func aLineEditedWhileFollowingStays() throws {
        try withStore(config: theirs) { prefs, file in
            setSlots(prefs, "Follow Test A")
            let catalog = ThemeCatalog()
            catalog.bind(prefs)
            prefs.followSystemAppearance = true
            catalog.setFollowSystem(true)
            try file().replacingOccurrences(of: "Dracula", with: "Nord")
                .write(toFile: UserConfigStore.path, atomically: true, encoding: .utf8)
            prefs.followSystemAppearance = false
            catalog.setFollowSystem(false)
            #expect(file() == theirs.replacingOccurrences(of: "Dracula", with: "Nord"))
            #expect(catalog.current == "Nord")
        }
    }

    @Test func turningOffRestoresThePickedTheme() throws {
        try withStore(config: theirs) { prefs, file in
            ThemeCatalog().apply(id: "Follow Test Picked")
            // A swatch pick takes the theme key.
            #expect(!file().contains("theme = Dracula"))
            setSlots(prefs, "Follow Test A")
            let catalog = ThemeCatalog()
            catalog.bind(prefs)
            prefs.followSystemAppearance = true
            catalog.setFollowSystem(true)
            #expect(UserConfigStore.managedThemeID() == "Follow Test A")

            let reloadedPrefs = Preferences(), relaunched = ThemeCatalog()
            relaunched.bind(reloadedPrefs)
            try (theirs + file()).write(toFile: UserConfigStore.path, atomically: true, encoding: .utf8)
            reloadedPrefs.followSystemAppearance = false
            relaunched.setFollowSystem(false)
            #expect(UserConfigStore.managedThemeID() == "Follow Test Picked")
            #expect(relaunched.current == "Follow Test Picked")
            #expect(file().hasPrefix(theirs))
        }
    }

    /// `theme = X` alone names the current theme without its explicit colors,
    /// so following still has to write them.
    @Test func aBareThemeLineIsNotAnAppliedSlot() throws {
        try withStore(config: "theme = \"Follow Test A\"\n") { prefs, _ in
            setSlots(prefs, "Follow Test A")
            let catalog = ThemeCatalog()
            catalog.bind(prefs)
            prefs.followSystemAppearance = true
            catalog.setFollowSystem(true)
            #expect(UserConfigStore.managedThemeID() == "Follow Test A")
        }
    }

    /// The block's colors win over a `theme =` line left in the file.
    @Test(arguments: [true, false]) func theBlockWinsOverAThemeLine(lineLast: Bool) throws {
        try withStore(config: "") { _, file in
            let other = UserConfigStore.path + "-other"
            try "background = #ff0000\nforeground = #00ff00\n".write(toFile: other, atomically: true, encoding: .utf8)
            let line = "theme = \(other)\n"
            @MainActor func background() throws -> UInt8 {
                Ghostty.initializeOnce()
                let cfg = try #require(ghostty_config_new())
                defer { ghostty_config_free(cfg) }
                Ghostty.App.loadContermConfig(cfg, path: UserConfigStore.path)
                ghostty_config_finalize(cfg)
                var color = ghostty_config_color_s()
                #expect("background".withCString { ghostty_config_get(cfg, &color, $0, UInt(strlen($0))) })
                return color.r
            }
            try line.write(toFile: UserConfigStore.path, atomically: true, encoding: .utf8)
            #expect(try background() == 255)
            UserConfigStore.writeManagedThemeBlock(themeID: "Follow Test A",
                                                   colorLines: ["background = #000000", "foreground = #ffffff"],
                                                   keepingThemeLine: true)
            if lineLast {
                try (file().replacingOccurrences(of: line, with: "") + line)
                    .write(toFile: UserConfigStore.path, atomically: true, encoding: .utf8)
            }
            #expect(try background() == 0)
        }
    }
}
