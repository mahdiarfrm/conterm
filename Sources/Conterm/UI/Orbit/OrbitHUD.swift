import SwiftUI

// The surfaces Orbit's HUD sits on: the bars, lists and panels floating over
// the map, and the chips on it. Liquid Drop draws them with the kit's lens
// (`DropLens`) rather than Metal drops, since there are many, they come and
// go with every aim, and most are small. Classic keeps system material bars
// and flat chrome chips. The map's own content (node cards, action chips,
// group labels) is not HUD and keeps its glass in both styles.

extension View {
    /// A bar, list or panel floating over the map. `rim` carries meaning (a
    /// status tint, the note colour) and is drawn in both styles;
    /// `classicRim` is Classic's neutral outline, which the lens's own rim
    /// replaces. `bed` darkens (or, light, whitens) the glass under text
    /// that must stay readable over whatever it floats above. `lit` is for
    /// the bar aimed at something.
    func orbitGlass<S: InsettableShape>(_ shape: S, bed: Double = 0,
                                        rim: Color? = nil, rimWidth: CGFloat = 1,
                                        classicRim: Color = Theme.strokeStrong,
                                        lit: Bool = false) -> some View {
        modifier(OrbitGlass(shape: shape, bed: bed, rim: rim, rimWidth: rimWidth,
                            classicRim: classicRim, lit: lit))
    }

    /// A chip or small control cluster on the map. `tint` washes it (a
    /// toggle that's on); `rim` carries meaning and is drawn in both styles;
    /// `outlined` gives Classic its neutral outline.
    func orbitChip<S: InsettableShape>(_ shape: S, selected: Bool = false,
                                       tint: Color? = nil, rim: Color? = nil,
                                       outlined: Bool = false) -> some View {
        modifier(OrbitChip(shape: shape, selected: selected, tint: tint, rim: rim,
                           outlined: outlined))
    }
}

private struct OrbitGlass<S: InsettableShape>: ViewModifier {
    @EnvironmentObject private var prefs: Preferences
    let shape: S
    let bed: Double
    let rim: Color?
    let rimWidth: CGFloat
    let classicRim: Color
    let lit: Bool

    func body(content: Content) -> some View {
        let light = prefs.lightGlass
        content
            .background(ZStack {
                shape.fill(.ultraThinMaterial)
                if bed > 0 {
                    shape.fill(light ? Color.white.opacity(bed) : Color.black.opacity(bed))
                }
                if prefs.liquidDrop {
                    DropLens(shape: shape, lit: lit, light: light, gathers: false)
                }
            })
            .overlay {
                if let rim {
                    shape.strokeBorder(rim, lineWidth: rimWidth)
                } else if !prefs.liquidDrop {
                    shape.strokeBorder(classicRim, lineWidth: rimWidth)
                }
            }
    }
}

private struct OrbitChip<S: InsettableShape>: ViewModifier {
    @EnvironmentObject private var prefs: Preferences
    let shape: S
    let selected: Bool
    let tint: Color?
    let rim: Color?
    let outlined: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if prefs.liquidDrop {
                    DropLens(shape: shape, lit: selected, light: prefs.lightGlass, tint: tint,
                             bed: prefs.lightGlass ? 0 : 0.28)
                } else if let tint {
                    shape.fill(tint.opacity(0.14))
                } else {
                    shape.fill(chromeFill(prefs, selected: selected))
                }
            }
            .overlay {
                if let rim {
                    shape.strokeBorder(rim, lineWidth: 1)
                } else if outlined, !prefs.liquidDrop {
                    shape.strokeBorder(Theme.strokeStrong, lineWidth: 1)
                }
            }
    }
}
