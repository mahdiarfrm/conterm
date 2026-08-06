import AppKit
import Combine
import SwiftUI

/// A node on the canvas: a glass card carrying its own identity, rather than an
/// orb with a caption floating beside it. The caption was the readability
/// problem — free text has no bounds, so in a dense graph labels crossed each
/// other and the orbs underneath. A card owns its label, so crowding costs
/// overlap of whole cards instead of an unreadable pile of words.
///
/// Driven by the canvas clock (`now`) rather than its own animation, so it
/// breathes only while the map is awake and stops dead when the map sleeps.
struct NodeCard: View {
    let label: String
    let subtitle: String?
    /// Width for the text column, measured by the caller. `.frame(maxWidth:)`
    /// *expands* to its maximum under `.position()`, which proposes the whole
    /// canvas — so every card came out the same width whatever its name.
    let contentWidth: CGFloat
    /// What this card *is*, plus its number among its own kind — "HOST 3".
    /// Set in the mode's own typeface, as a quiet identifying mark rather than
    /// another piece of information to read.
    let kindTag: String?
    let glyph: String
    /// A resolved host wears its distribution's mark in place of the glyph.
    let distro: Distro?
    let tint: Color
    let status: MapNode.Status
    let now: TimeInterval
    let zoom: CGFloat
    let hovered: Bool
    let selected: Bool
    let dimmed: Bool
    let faded: Bool
    let light: Bool
    /// Zoomed out far enough that the card shows its name and nothing else.
    let compact: Bool
    /// Phase offset so a wall of working nodes doesn't pulse in lockstep.
    let phase: Double

    var busy: Bool { status == .working }
    var wants: Bool { status == .attention }
    /// 0…1 breathing curve — shared by the glyph, its ring and the border, so
    /// the whole card reads as one live object rather than parts blinking.
    var pulse: Double {
        guard busy || wants else { return 0 }
        return 0.5 + 0.5 * sin(now * (busy ? 2.6 : 3.4) + phase)
    }

    var scale: CGFloat {
        let hover: CGFloat = hovered ? 1.06 : 1.0
        return hover * (busy ? 1 + 0.012 * CGFloat(pulse) : 1)
    }

    /// Generously round. These are the objects the mode is about, and a soft
    /// capsule-adjacent shape separates them from the square panels and pills
    /// of the chrome around them.
    static let corner: CGFloat = 22

    /// Below this zoom a card drops to its name alone. Shrinking the full card
    /// instead put three lines of type below legibility and left an overview
    /// you could see the shape of but not read.
    static let compactBelow: CGFloat = 0.72

    /// How far a card is allowed to shrink. Zooming out spreads the nodes by
    /// the same factor, so the cards do not have to shrink with it — holding a
    /// floor here is what keeps an overview readable.
    static let minScale: CGFloat = 0.82

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            // The mark sits on the card, in nothing. A container around it
            // reads as chrome — and these glyphs are worth looking at, so they
            // are drawn large and given the colour rather than boxed in.
            Group {
                if let distro {
                    DistroMark(distro: distro, size: 21)
                } else {
                    Image(systemName: glyph).font(.system(size: 18, weight: .regular))
                }
            }
            .foregroundStyle(status == .neutral
                             ? Theme.textPrimary.opacity(0.78) : tint)
            // Its own soft bloom, so an active node's mark glows rather than
            // only sitting inside something that does.
            .shadow(color: status == .neutral ? .clear : tint.opacity(0.5 + 0.3 * pulse),
                    radius: status == .neutral ? 0 : 7)
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                if let kindTag, !compact {
                    // What the card *is* — never abbreviated. The tag is the
                    // one line that tells a session apart from the machine it
                    // is talking to, so it takes its natural width and the
                    // selection tick sits outside the text column entirely.
                    // The state rides on this line as a dot. A bar down the
                    // card's edge is most of what you see on a card three short
                    // lines tall.
                    HStack(spacing: 5) {
                        if status != .neutral {
                            Circle()
                                .fill(tint.opacity(wants || busy ? 0.6 + 0.4 * pulse : 0.85))
                                .frame(width: 4.5, height: 4.5)
                                .shadow(color: tint.opacity(0.8), radius: 3.5)
                        }
                        OrbitText(text: kindTag, size: 8, tracking: 1.2)
                            .foregroundStyle(selected ? Theme.accent.opacity(0.95)
                                                      : Theme.textSecondary.opacity(0.7))
                    }
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty, subtitle != label, !compact {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.85))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(width: contentWidth, alignment: .leading)
        }
        .padding(.leading, 14).padding(.trailing, 16)
        .padding(.vertical, compact ? 8 : 9)
        .background(
            ZStack {
                // A bed under the glass, thin enough that the frost still reads
                // as frost. Fully opaque killed the material; fully clear let
                // the edges and action wires beneath run straight across the
                // card's own label.
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(light ? Color.white.opacity(0.55) : Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                // Frost over frost: a second pass of material deepens the blur
                // so what shows through is light and colour rather than shapes.
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                // Status is one flat wash through the glass — no sheen, no
                // falloff. A gradient across a card this small reads as a
                // smudge rather than as light, and the dot, the border and the
                // halo already carry the state.
                if underglow > 0.001 {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .fill(glowColor.opacity(underglow))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected ? 2.2 : 1)
        )
        // Selection drives the action bar, so it has to read at a glance — a
        // tint alone is lost among the statuses. On the corner rather than in
        // the tag row, where it would compete for width with the card's
        // identity and abbreviate it.
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .background(Circle().fill(light ? Color.white : Color.black).padding(1))
                    .offset(x: 4, y: -4)
            }
        }
        // A short bright segment orbiting the card's edge while it works — the
        // one signal that reads as motion rather than as colour.
        .overlay { if busy { travellingLight } }
        // A wide, soft bloom only — the tight bright ring read as neon paint.
        .shadow(color: glowColor.opacity(haloStrength), radius: glows ? (hovered ? 18 : 13) : 0)
        // A known-but-unconnected host is still something you act on, so it is
        // only slightly quieter — 0.55 made half the fleet unreadable.
        .opacity(dimmed ? 0.3 : (faded ? 0.82 : 1))
        // Zooming in must separate cards, so the card itself never grows past
        // its natural size — only the distance between cards does. Zooming out
        // shrinks it only as far as `minScale`, past which an overview would be
        // a shape you cannot read.
        .scaleEffect(scale * max(min(zoom, 1.0), Self.minScale))
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.16), value: selected)
    }

    /// How strongly the colour blooms beneath the glass. Deliberately gentle:
    /// a wall of these has to stay calm. Lower than a gradient would need: this is a flat wash over the whole
    /// card, where a radial one only reached its stated strength at its centre.
    var underglow: Double {
        if selected { return 0.11 }          // picked reads stronger than active
        if wants { return 0.038 + 0.028 * pulse }
        if busy { return 0.03 + 0.022 * pulse }
        if hovered { return 0.028 }
        // `.ready` is an agent sitting there between turns — still a session,
        // so it keeps a colour rather than going as quiet as a bare host.
        return status == .neutral ? 0 : 0.032
    }

    /// Selection wins the card's colour: it is a state you chose, and it has to
    /// out-read whatever the node happens to be doing.
    var glowColor: Color { selected ? Theme.accent : tint }
    var glows: Bool { haloStrength > 0.01 }
    var haloStrength: Double {
        if selected { return 0.30 }
        if wants { return 0.08 + 0.05 * pulse }
        if busy { return 0.07 + 0.04 * pulse }
        if hovered { return 0.07 }
        return status == .ready ? 0.05 : 0
    }

    var borderColor: Color {
        if selected { return Theme.accent }
        if wants { return tint.opacity(0.22 + 0.14 * pulse) }
        if busy { return tint.opacity(0.18 + 0.10 * pulse) }
        if status != .neutral { return tint.opacity(0.3) }
        return (light ? Color.black : Color.white).opacity(hovered ? 0.24 : 0.12)
    }

    /// A short segment running the card's border. `trim` doesn't wrap past the
    /// end of the path, so the tail is drawn as a second segment from the start
    /// — otherwise the light would vanish and restart at the corner.
    @ViewBuilder
    var travellingLight: some View {
        // Driven by its own clock rather than the canvas's: the map parks at a
        // low frame rate once it settles, and a light crawling round an edge is
        // exactly the thing that reads as broken at 12fps. Only busy cards have
        // one, so this is a handful of loops, not one per node.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            travellingLight(at: tl.date.timeIntervalSinceReferenceDate)
        }
    }

    func travellingLight(at t: TimeInterval) -> some View {
        let span = 0.17
        let head = (t * 0.19 + phase * 0.11).truncatingRemainder(dividingBy: 1)
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        return ZStack {
            shape.trim(from: head, to: min(head + span, 1))
                .stroke(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            if head + span > 1 {
                shape.trim(from: 0, to: head + span - 1)
                    .stroke(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .blur(radius: 0.7)
    }
}
