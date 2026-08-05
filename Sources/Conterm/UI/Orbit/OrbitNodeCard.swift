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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // No disc, no ring: the glyph just sits there. The status is told by
            // the colour breathing under the whole surface instead.
            Group {
                if let distro {
                    DistroMark(distro: distro, size: 15)
                } else {
                    Image(systemName: glyph).font(.system(size: 13.5, weight: .medium))
                }
            }
            .foregroundStyle(Theme.textPrimary.opacity(status == .neutral ? 0.75 : 0.95))
            .frame(width: 17)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let kindTag {
                    HStack(spacing: 5) {
                        Text(kindTag)
                            .font(OrbitFont.face(7.5)).tracking(0.5)
                            .foregroundStyle(selected ? Theme.accent.opacity(0.95)
                                                      : Theme.textSecondary.opacity(0.62))
                            .lineLimit(1)
                        if selected {
                            // Selection drives the action bar, so it has to read
                            // at a glance — a tint alone was lost among statuses.
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(width: contentWidth, alignment: .leading)
        }
        .padding(.leading, 10).padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(
            ZStack {
                // A bed under the glass. The material alone let the edges and
                // action wires beneath read straight through the card, so a card
                // sitting on a busy part of the graph had lines running across
                // its label.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(light ? Color.white.opacity(0.9) : Color.black.opacity(0.86))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                // The colour lives *under* the surface — a soft bloom that
                // breathes through the glass rather than a bright ring on top
                // of it, so an active card glows instead of shouting.
                if underglow > 0.001 {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(RadialGradient(
                            colors: [glowColor.opacity(underglow),
                                     glowColor.opacity(underglow * 0.25), .clear],
                            center: .init(x: 0.12, y: 0.5), startRadius: 2, endRadius: 130))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected ? 2.4 : 1)
        )
        // The travelling light, kept from the old ring but run around the card
        // itself: a short bright segment orbiting the edge while it works.
        .overlay { if busy { travellingLight } }
        // A wide, soft bloom only — the tight bright ring read as neon paint.
        .shadow(color: glowColor.opacity(haloStrength), radius: glows ? (hovered ? 18 : 13) : 0)
        // A known-but-unconnected host is still something you act on, so it is
        // only slightly quieter — 0.55 made half the fleet unreadable.
        .opacity(dimmed ? 0.3 : (faded ? 0.82 : 1))
        // Zooming in must separate cards, so the card itself never grows past
        // its natural size — only the distance between cards does. Zooming out
        // shrinks them, so an overview stays proportional.
        .scaleEffect(scale * max(min(zoom, 1.0), 0.55))
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.16), value: selected)
    }

    /// How strongly the colour blooms beneath the glass. Deliberately gentle:
    /// this is the card's whole status signal now, and a wall of them has to
    /// stay calm.
    var underglow: Double {
        if selected { return 0.17 }          // picked reads stronger than active
        if wants { return 0.055 + 0.04 * pulse }
        if busy { return 0.045 + 0.03 * pulse }
        if hovered { return 0.04 }
        // `.ready` is an agent sitting there between turns — still a session,
        // so it keeps a colour rather than going as quiet as a bare host.
        return status == .neutral ? 0 : 0.05
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
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
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
