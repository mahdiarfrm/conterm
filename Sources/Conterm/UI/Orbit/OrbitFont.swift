import AppKit
import CoreText
import SwiftUI

/// Orbit's own typeface: a wide square grotesque, used for the wordmark and for
/// the small identifying marks on its chrome.
///
/// Eurostile is the face the mode was designed around, and it is licensed —
/// Monotype's, whatever a download site offers — so the app does not carry it.
/// It is used when the machine has it. Otherwise the bundled fallback is
/// Orbitron, SIL OFL, a variable face carrying a weight axis up to 900, which
/// is the point: a display face at 400 reads thin at the sizes this chrome uses
/// and the mark has to hold its own beside a heavy system UI. Its licence ships
/// beside it, as the OFL requires.
@MainActor
enum OrbitFont {
    /// Tried in order: what you may have licensed, then what is bundled.
    static let candidates = [
        "EurostileBQ-BoldExtended", "Eurostile Bold Extended", "Eurostile BQ",
        "Orbitron-Regular", "Orbitron",
    ]

    /// Where the fallback is set on its own weight axis. The top of Orbitron's
    /// range — anything lighter loses to the chrome around it.
    static let fallbackWeight: CGFloat = 900

    static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        guard let url = Bundle.main.url(forResource: "orbitron-variable", withExtension: "ttf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// The first candidate this machine actually has.
    static func resolvedName(_ size: CGFloat) -> String? {
        register()
        return candidates.first { NSFont(name: $0, size: size) != nil }
    }

    /// The face as an `NSFont`, already set on its weight axis where it has one.
    ///
    /// A variable font's default instance is whatever its axis defaults to —
    /// 400 for Orbitron — and neither `NSFont(name:size:)` nor SwiftUI's
    /// `.custom` can move it. The axis has to be set through a font descriptor,
    /// which is what this does; asking for `.bold` on top would only synthesise
    /// a smear over the same outlines.
    static func nsFont(_ size: CGFloat) -> NSFont? {
        guard let name = resolvedName(size) else { return nil }
        guard name.hasPrefix("Orbitron") else { return NSFont(name: name, size: size) }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: name as CFString,
            kCTFontVariationAttribute: [kCTFontWeightAxis: fallbackWeight] as CFDictionary,
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    /// Rendered width of a string in this face. These faces are far wider than
    /// the system one at the same size, so estimating from the system metrics
    /// clipped every kind tag.
    static func width(_ s: String, size: CGFloat) -> CGFloat {
        guard let f = nsFont(size) else {
            return ceil(TabPill.textWidth(s, size: size) * 1.4)
        }
        return ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    /// The wordmark face at an arbitrary size. Falls back to a wide heavy
    /// system face when neither the licensed nor the bundled one is present.
    static func face(_ size: CGFloat) -> Font {
        guard let f = nsFont(size) else {
            return .system(size: size - 1, weight: .black, design: .rounded).width(.expanded)
        }
        return Font(f)
    }
}

/// CoreText spells the weight axis as a four-character tag packed into an
/// integer. `fvar` reports it as `wght`; this is that, as the key the
/// variation dictionary wants.
private let kCTFontWeightAxis: NSNumber = {
    let tag = "wght".utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    return NSNumber(value: tag)
}()
