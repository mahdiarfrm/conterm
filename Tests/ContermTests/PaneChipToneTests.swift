import AppKit
import Combine
import Foundation
import GhosttyKit
import SwiftUI
import Testing
@testable import Conterm

/// The pane chips take a light or dark bed from the terminal background's
/// luminance, never the glass tint, and their dark values equal the pinned
/// sRGB constants.
@MainActor
struct PaneChipToneTests {

    // MARK: - Luminance decides the bed

    @Test func darkThemeBackgroundsKeepTheDarkBed() {
        // Ghostty's default, and a couple of common dark themes.
        #expect(ThemeCatalog.isDark(r: 0x28, g: 0x2c, b: 0x34))
        #expect(ThemeCatalog.isDark(r: 0x1a, g: 0x1b, b: 0x26))
        #expect(ThemeCatalog.isDark(r: 0, g: 0, b: 0))
    }

    @Test func lightThemeBackgroundsTakeTheLightBed() {
        #expect(!ThemeCatalog.isDark(r: 0xfd, g: 0xf6, b: 0xe3))   // Solarized Light
        #expect(!ThemeCatalog.isDark(r: 0xff, g: 0xff, b: 0xff))
        #expect(!ThemeCatalog.isDark(r: 0xee, g: 0xee, b: 0xee))
    }

    @Test func byteAndColorFormsAgree() {
        for v in stride(from: 0, through: 255, by: 15) {
            let b = UInt8(v)
            let c = Color(red: Double(v) / 255, green: Double(v) / 255, blue: Double(v) / 255)
            #expect(ThemeCatalog.isDark(r: b, g: b, b: b) == ThemeCatalog.isDark(c))
        }
    }

    /// The signal is read from libghostty's resolved config, so the
    /// `background` getter must actually return the colour.
    @Test func resolvedConfigBackgroundDecidesTheBed() {
        func isLight(_ text: String) -> Bool? {
            Self.withConfig(text) {
                Ghostty.App.backgroundColor($0).map { Ghostty.TerminalBackground(base: $0).isLight }
            } ?? nil
        }
        #expect(isLight("") == false)
        #expect(isLight("background = #fdf6e3\n") == true)
        #expect(Self.withConfig("background = #282c34\n") {
            Ghostty.App.backgroundColor($0).map { [$0.r, $0.g, $0.b] }
        } == [0x28, 0x2c, 0x34])
    }

    @Test func aConfigChangeKeepsTheProgramsBackground() {
        let dark = Ghostty.TerminalBackground.RGB(r: 0x28, g: 0x2c, b: 0x34)
        let darker = Ghostty.TerminalBackground.RGB(r: 0, g: 0, b: 0)
        let white = Ghostty.TerminalBackground.RGB(r: 255, g: 255, b: 255)
        var bg = Ghostty.TerminalBackground(base: dark)
        bg.programSet(white)    // OSC 11
        #expect(bg.isLight)
        bg.base = darker        // theme pick, reload
        #expect(bg.isLight)
        bg.programSet(darker)   // OSC 111 reports the new default
        #expect(!bg.isLight)
        bg.base = white         // no override left
        #expect(bg.isLight)
    }

    /// The box is built inside a SwiftUI view update, where a publish is
    /// undefined behavior, so the tone reaches the chrome as a plain value.
    @Test func theBoxTakesItsToneWithoutPublishing() throws {
        let pane = Pane()
        var publishes = 0
        let sink = pane.objectWillChange.sink { publishes += 1 }
        defer { sink.cancel() }
        let box = PaneBox(pane: pane,
                          host: .init(surfaceView: Ghostty.SurfaceView(frame: .zero)),
                          prefs: Preferences(), tab: nil, terminalIsLight: true)
        let chrome = try #require(box.subviews.lazy
            .compactMap { $0 as? NSHostingView<PaneChrome> }.first)
        #expect(chrome.rootView.terminalIsLight)
        #expect(chrome.appearance?.name == .aqua)
        box.terminalIsLight = false
        #expect(!chrome.rootView.terminalIsLight)
        #expect(chrome.appearance?.name == .darkAqua)
        #expect(publishes == 0)
    }

    // MARK: - Dark values

    /// Every chip colour's dark value equals its pinned sRGB constant.
    @Test func darkValuesEqualThePinnedSRGBConstants() {
        let pairs: [(String, Color, Color)] = [
            ("paneTitleBar", Theme.paneTitleBar, Color(red: 0.12, green: 0.13, blue: 0.16)),
            ("paneRemoteBar", Theme.paneRemoteBar, Color(red: 0.07, green: 0.13, blue: 0.20)),
            ("warning", Theme.warning, Color(red: 1.00, green: 0.80, blue: 0.55)),
            ("PanePill.bed", PanePill.bed, Color(red: 0.05, green: 0.055, blue: 0.07)),
            ("PanePill.ink", PanePill.ink, Color(white: 0.96)),
            ("onChip", Theme.onChip, Color.white),
            ("onChipAccent", Theme.onChipAccent, Theme.accentOnDark),
            ("sshOnChip", Theme.sshOnChip, Theme.sshAccent),
            ("goodOnChip", Theme.goodOnChip, Color(red: 0.45, green: 0.86, blue: 0.55)),
            ("badOnChip", Theme.badOnChip, Color(red: 1.0, green: 0.42, blue: 0.42)),
        ] + AgentToolKind.allCases.map { ("kind.\($0)", $0.chipColor, $0.color) }
          + Self.agents.map { ("glow.\($0)", $0.chipGlow(.dark), $0.glowColor) }
          + [("rim", PaneChrome.rimTint(light: false), Theme.highlight)]
        for (name, now, pinned) in pairs {
            let a = Self.srgb(now, dark: true)
            let b = Self.srgb(pinned, dark: true)
            for i in 0..<4 {
                #expect(abs(a[i] - b[i]) < 1e-4, "\(name) component \(i): \(a) vs \(b)")
            }
        }
    }

    /// The light bed really is light, and its ink dark, so the chips read.
    @Test func lightBedIsLightWithDarkInk() {
        for bed in [PanePill.bed, Theme.paneTitleBar, Theme.paneRemoteBar] {
            #expect(Self.luminance(Self.srgb(bed, dark: false)) > 0.8)
        }
        for ink in [PanePill.ink, Theme.onChip, Theme.onChipAccent] {
            #expect(Self.luminance(Self.srgb(ink, dark: false)) < 0.2)
        }
    }

    /// No accent stays pale on the light bed.
    @Test func everyAccentHoldsUpOnTheLightBed() {
        let accents = AgentToolKind.allCases.map { ("\($0)", $0.chipColor) }
            + Self.agents.map { ("\($0)", $0.chipGlow(.light)) }
            + [("good", Theme.goodOnChip), ("bad", Theme.badOnChip),
               ("rim", PaneChrome.rimTint(light: true))]
        for (name, color) in accents {
            let light = Self.luminance(Self.srgb(color, dark: false))
            #expect(light < 0.65, "\(name): \(light)")
        }
    }

    // MARK: - Helpers

    private static let agents: [AgentTool] = [.claude, .opencode, .codex, .generic]

    private static func srgb(_ color: Color, dark: Bool) -> [Double] {
        let ns = NSColor(color)
        var out = [Double]()
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = ns.usingColorSpace(.sRGB)!
            out = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
                .map(Double.init)
        }
        return out
    }

    private static func luminance(_ c: [Double]) -> Double {
        0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    private static func withConfig<T>(_ text: String,
                                      _ body: (ghostty_config_t) -> T) -> T? {
        Ghostty.initializeOnce()
        guard let cfg = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(cfg) }
        let path = NSTemporaryDirectory() + "conterm-test-\(UUID().uuidString).conf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        return body(cfg)
    }
}
