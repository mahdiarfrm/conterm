import Testing
import Foundation
import GhosttyKit
@testable import Conterm

/// The libghostty config chain: later files win, and the generated
/// lastword block both parses clean and carries the correctness
/// overrides Conterm depends on (legacy ctrl encoding, word separators,
/// shell integration). `.serialized` because `lastwordText()` varies
/// with process-shared UserDefaults keys the tests flip.
@MainActor
@Suite(.serialized) struct ConfigChainTests {

    private static let touchedKeys = [
        "conterm.sshCompatMode",
        "conterm.lowPowerRendering",
    ]

    private func withDefaults(_ values: [String: Any],
                              _ body: () throws -> Void) rethrows {
        let ud = UserDefaults.standard
        for k in Self.touchedKeys { ud.removeObject(forKey: k) }
        for (k, v) in values { ud.set(v, forKey: k) }
        defer { for k in Self.touchedKeys { ud.removeObject(forKey: k) } }
        try body()
    }

    /// Build a finalized config from config-file texts loaded in order.
    /// Returns nil if libghostty can't allocate one.
    private func loadConfig(_ texts: [String]) -> ghostty_config_t? {
        Ghostty.initializeOnce()
        guard let cfg = ghostty_config_new() else { return nil }
        for text in texts {
            let path = NSTemporaryDirectory() + "conterm-test-\(UUID().uuidString).conf"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            path.withCString { ghostty_config_load_file(cfg, $0) }
        }
        ghostty_config_finalize(cfg)
        return cfg
    }

    private func stringValue(_ cfg: ghostty_config_t, _ key: String) -> String? {
        var ptr: UnsafePointer<CChar>? = nil
        let ok = key.withCString {
            ghostty_config_get(cfg, &ptr, $0, UInt(strlen($0)))
        }
        guard ok, let ptr else { return nil }
        return String(cString: ptr)
    }

    private func diagnostics(_ cfg: ghostty_config_t) -> [String] {
        (0..<ghostty_config_diagnostics_count(cfg)).map { i in
            let d = ghostty_config_get_diagnostic(cfg, i)
            return d.message.map { String(cString: $0) } ?? "<no message>"
        }
    }

    // MARK: - Merge order

    @Test func laterFileWinsForTheSameKey() {
        guard let cfg = loadConfig(["cursor-style = block",
                                    "cursor-style = underline"]) else {
            Issue.record("ghostty_config_new failed")
            return
        }
        defer { ghostty_config_free(cfg) }
        #expect(stringValue(cfg, "cursor-style") == "underline")
        #expect(diagnostics(cfg).isEmpty)
    }

    @Test func withinOneFileTheLastAssignmentWins() {
        guard let cfg = loadConfig(["cursor-style = underline\ncursor-style = bar"]) else {
            Issue.record("ghostty_config_new failed")
            return
        }
        defer { ghostty_config_free(cfg) }
        #expect(stringValue(cfg, "cursor-style") == "bar")
    }

    // MARK: - Lastword block

    /// The generated lastword must always be syntactically valid Ghostty
    /// config — a bad edit here would silently poison every layer below.
    @Test func lastwordParsesCleanInEveryVariant() {
        let variants: [[String: Any]] = [
            [:],
            ["conterm.sshCompatMode": true],
            ["conterm.lowPowerRendering": false],
            ["conterm.sshCompatMode": true, "conterm.lowPowerRendering": false],
        ]
        for values in variants {
            withDefaults(values) {
                guard let cfg = loadConfig([Ghostty.App.lastwordText()]) else {
                    Issue.record("ghostty_config_new failed")
                    return
                }
                defer { ghostty_config_free(cfg) }
                #expect(diagnostics(cfg).isEmpty,
                        "variant \(values): \(diagnostics(cfg))")
                #expect(stringValue(cfg, "shell-integration") == "detect")
            }
        }
    }

    /// `ssh-env` pins TERM to xterm-256color for the remote; the
    /// `ssh-terminfo` install is never offered, at any setting, because
    /// its remote `infocmp` probe can't be trusted to agree with the
    /// remote's own ncurses.
    @Test func lastwordAlwaysTakesSshEnvWithoutTerminfo() {
        for values in [[:], ["conterm.sshCompatMode": true]] as [[String: Any]] {
            withDefaults(values) {
                let text = Ghostty.App.lastwordText()
                #expect(text.contains("cursor,sudo,title,ssh-env\n"))
                #expect(!text.contains("ssh-terminfo"))
            }
        }
    }

    @Test func defaultLastwordLeavesArrowsAloneAndDropsVsync() {
        withDefaults([:]) {
            let text = Ghostty.App.lastwordText()
            #expect(text.contains("window-vsync = false"))   // lowPower defaults on
            #expect(!text.contains("csi:1;2D"))
        }
    }

    /// Opting in displaces Ghostty's `adjust_selection` bindings on
    /// Shift+Arrow — the cost that keeps this off by default.
    @Test func remoteArrowKeysAddsTheCsiBindings() {
        withDefaults(["conterm.sshCompatMode": true]) {
            let text = Ghostty.App.lastwordText()
            #expect(text.contains("keybind = shift+arrow_left=csi:1;2D"))
            #expect(text.contains("keybind = ctrl+arrow_down=csi:1;5B"))
        }
    }

    /// Compat mode keeps `ssh-env` — that wrapper is what pins TERM to
    /// xterm-256color — and drops only `ssh-terminfo`, whose remote
    /// `infocmp` probe can report xterm-ghostty present when the
    /// remote's ncurses can't actually resolve it.
    @Test func sshCompatModeSwapsTerminfoInstallForCsiKeybinds() {
        withDefaults(["conterm.sshCompatMode": true]) {
            let text = Ghostty.App.lastwordText()
            #expect(text.contains("cursor,sudo,title,ssh-env\n"))
            #expect(!text.contains("ssh-terminfo"))
            #expect(text.contains("keybind = shift+arrow_left=csi:1;2D"))
            #expect(text.contains("keybind = ctrl+arrow_down=csi:1;5B"))
        }
    }

    @Test func lowPowerRenderingOffKeepsVsyncDefault() {
        withDefaults(["conterm.lowPowerRendering": false]) {
            #expect(!Ghostty.App.lastwordText().contains("window-vsync"))
        }
    }

    /// The legacy-encoding stance: every ctrl+a…z (plus escape and the
    /// C0 stragglers) is pinned to a text: byte so libghostty's Kitty
    /// CSI-u path never engages. Losing one of these regresses vim/fzf
    /// over SSH in ways no compile step catches.
    @Test func legacyControlEncodingCoversTheC0Range() {
        withDefaults([:]) {
            let text = Ghostty.App.lastwordText()
            for (i, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
                let hex = String(format: "%02x", i + 1)
                #expect(text.contains("keybind = ctrl+\(letter)=text:\\x\(hex)"),
                        "missing ctrl+\(letter)")
            }
            #expect(text.contains("keybind = escape=text:\\x1b"))
            #expect(text.contains("keybind = ctrl+bracket_left=text:\\x1b"))
            #expect(text.contains("keybind = ctrl+backslash=text:\\x1c"))
            #expect(text.contains("keybind = ctrl+bracket_right=text:\\x1d"))
            #expect(text.contains("keybind = ctrl+space=text:\\x00"))
            #expect(text.contains("selection-word-chars"))
        }
    }

    // MARK: - Firstword block

    /// Firstword carries Conterm's overridable defaults. It must parse
    /// clean and set ⌥-as-Alt on.
    @Test func firstwordParsesCleanAndSetsOptionAsAlt() {
        guard let cfg = loadConfig([Ghostty.App.firstwordText()]) else {
            Issue.record("ghostty_config_new failed")
            return
        }
        defer { ghostty_config_free(cfg) }
        #expect(diagnostics(cfg).isEmpty, "\(diagnostics(cfg))")
        #expect(stringValue(cfg, "macos-option-as-alt") == "true")
    }

    /// `macos-option-as-alt` must stay in firstword, never lastword:
    /// a user's `false` (native ⌥ accent composition) has to survive
    /// the full chain.
    @Test func userConfigOverridesOptionAsAlt() {
        withDefaults([:]) {
            guard let cfg = loadConfig([Ghostty.App.firstwordText(),
                                        "macos-option-as-alt = false",
                                        Ghostty.App.lastwordText()]) else {
                Issue.record("ghostty_config_new failed")
                return
            }
            defer { ghostty_config_free(cfg) }
            #expect(stringValue(cfg, "macos-option-as-alt") == "false")
            #expect(!Ghostty.App.lastwordText().contains("macos-option-as-alt"))
        }
    }

    /// Lastword loaded after a user file overrides the keys it owns —
    /// the property the whole "correctness-only overrides" layer
    /// depends on.
    @Test func lastwordOverridesUserConfig() {
        withDefaults([:]) {
            guard let cfg = loadConfig(["shell-integration = none",
                                        Ghostty.App.lastwordText()]) else {
                Issue.record("ghostty_config_new failed")
                return
            }
            defer { ghostty_config_free(cfg) }
            #expect(stringValue(cfg, "shell-integration") == "detect")
        }
    }
}
