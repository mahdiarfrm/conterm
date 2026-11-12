import AppKit
import Foundation
import GhosttyKit
import SwiftUI
import Testing
@testable import Conterm

/// The pane chips take a light or dark bed from the terminal background's
/// luminance, never the glass tint, and their dark bed must stay exactly
/// what it was before the light bed existed.
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
        #expect(Self.withConfig("") { Ghostty.App.backgroundIsLight($0) } == false)
        #expect(Self.withConfig("background = #fdf6e3\n") {
            Ghostty.App.backgroundIsLight($0)
        } == true)
        #expect(Self.withConfig("background = #282c34\n") {
            Ghostty.App.backgroundColor($0).map { [$0.r, $0.g, $0.b] }
        } == [0x28, 0x2c, 0x34])
    }

    // MARK: - Dark is unchanged

    /// Every chip colour's dark value against the SwiftUI sRGB value it
    /// replaced, compared in sRGB.
    @Test func darkValuesMatchTheOldSRGBColors() {
        let pairs: [(String, Color, Color)] = [
            ("paneTitleBar", Theme.paneTitleBar, Color(red: 0.12, green: 0.13, blue: 0.16)),
            ("paneRemoteBar", Theme.paneRemoteBar, Color(red: 0.07, green: 0.13, blue: 0.20)),
            ("warning", Theme.warning, Color(red: 1.00, green: 0.80, blue: 0.55)),
            ("PanePill.bed", PanePill.bed, Color(red: 0.05, green: 0.055, blue: 0.07)),
            ("PanePill.ink", PanePill.ink, Color(white: 0.96)),
            ("onChip", Theme.onChip, Color.white),
            ("onChipAccent", Theme.onChipAccent, Theme.accentOnDark),
            ("sshOnChip", Theme.sshOnChip, Theme.sshAccent),
        ] + AgentToolKind.allCases.map { ("kind.\($0)", $0.chipColor, $0.color) }
        for (name, now, old) in pairs {
            let a = Self.srgb(now, dark: true)
            let b = Self.srgb(old, dark: true)
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

    /// The pale accents get a shade that holds up on the light bed.
    @Test func paleAccentsDeepenOnTheLightBed() {
        for kind in [AgentToolKind.ssh, .github, .shell, .todo] {
            let dark = Self.luminance(Self.srgb(kind.chipColor, dark: true))
            let light = Self.luminance(Self.srgb(kind.chipColor, dark: false))
            #expect(light < dark - 0.15, "\(kind): \(light) vs \(dark)")
        }
    }

    // MARK: - Helpers

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
