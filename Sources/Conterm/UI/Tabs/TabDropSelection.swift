import SwiftUI

/// Where the selected pill sits, reported up to the strip that draws the
/// Liquid Drop selection under its pills.
struct TabSelectionFrameKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Liquid Drop's tab selection: one glass drop that flows from pill to
/// pill. Its edges are sprung separately — the edge facing the new tab
/// leads and the other is dragged after it — so the drop stretches across
/// the gap, thins while it is stretched, and gathers itself on arrival.
/// The timeline runs only while the drop is off its target.
struct TabDropSelection: View {
    let target: CGRect
    let tint: Color
    let light: Bool
    /// Sidebar cards already sit on the panel's glass; the pooled light
    /// spreads wider and quieter there.
    let sidebar: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = TabDropMotion()
    @State private var moving = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !moving)) { timeline in
            let rect = motion.placed ? motion.advance(to: timeline.date) : target
            TabDrop(tint: tint, light: light, sidebar: sidebar)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
                .onChange(of: timeline.date) { _, _ in
                    if moving, motion.settled { moving = false }
                }
        }
        .animation(Theme.Spring.snappy, value: tint)
        .allowsHitTesting(false)
        .onChange(of: target, initial: true) { _, new in
            motion.aim(at: new, snap: reduceMotion)
            moving = !motion.settled
        }
    }
}

/// The drop's four edges as springs. A reference type held in `@State`:
/// stepping it per frame must not invalidate the view.
@MainActor
private final class TabDropMotion {
    private struct Edge {
        var value: CGFloat = 0
        var velocity: CGFloat = 0
        var target: CGFloat = 0
        var response: CGFloat = 0.3
        var damping: CGFloat = 0.8

        mutating func step(_ dt: CGFloat) {
            let omega = 2 * CGFloat.pi / response
            velocity += (omega * omega * (target - value) - 2 * damping * omega * velocity) * dt
            value += velocity * dt
        }

        var settled: Bool { abs(target - value) < 0.2 && abs(velocity) < 2 }

        mutating func snap() { value = target; velocity = 0 }
    }

    // minX, maxX, minY, maxY
    private var edges = [Edge](repeating: Edge(), count: 4)
    private var size = CGSize.zero
    private var last: Date?
    private(set) var placed = false

    var settled: Bool { edges.allSatisfy(\.settled) }

    func aim(at rect: CGRect, snap: Bool) {
        let targets = [rect.minX, rect.maxX, rect.minY, rect.maxY]
        size = rect.size
        // A drop at rest has no recent frame to measure the next step from.
        if settled { last = nil }
        for i in edges.indices { edges[i].target = targets[i] }
        guard placed, !snap else {
            for i in edges.indices { edges[i].snap() }
            placed = true
            last = nil
            return
        }
        // Per axis, the edge on the side of travel leads.
        for axis in 0..<2 {
            let low = axis * 2, high = low + 1
            let travel = (edges[low].target + edges[high].target)
                       - (edges[low].value + edges[high].value)
            let lead = travel >= 0 ? high : low
            let trail = travel >= 0 ? low : high
            edges[lead].response = 0.24;  edges[lead].damping = 0.74
            edges[trail].response = 0.40; edges[trail].damping = 0.80
        }
    }

    /// Steps to `date` and returns the drop's frame, thinned across the
    /// axis it is stretched along so its area roughly holds.
    func advance(to date: Date) -> CGRect {
        if let last, !settled {
            var remaining = CGFloat(min(max(date.timeIntervalSince(last), 0), 1.0 / 20.0))
            while remaining > 0 {
                let dt = min(remaining, 1.0 / 240.0)
                for i in edges.indices { edges[i].step(dt) }
                remaining -= dt
            }
            if settled { for i in edges.indices { edges[i].snap() } }
        }
        last = date
        let width = edges[1].value - edges[0].value
        let height = edges[3].value - edges[2].value
        let thinY = min(max(width - size.width, 0) * 0.03, size.height * 0.16)
        let thinX = min(max(height - size.height, 0) * 0.03, size.width * 0.05)
        return CGRect(x: edges[0].value + thinX, y: edges[2].value + thinY,
                      width: max(width - 2 * thinX, 1), height: max(height - 2 * thinY, 1))
    }
}

/// The drop itself: the kit's lit lens over a contact shadow, with the
/// selection colour pooled onto the bar beneath it.
private struct TabDrop: View {
    let tint: Color
    let light: Bool
    let sidebar: Bool

    var body: some View {
        DropLens(shape: RoundedRectangle(cornerRadius: Theme.pillCorner, style: .continuous),
                 lit: true, light: light, tint: tint)
            .shadow(color: tint.opacity(sidebar ? 0.22 : 0.32),
                    radius: sidebar ? 9 : 8, y: 3)
            .shadow(color: Color.black.opacity(light ? 0.10 : 0.30), radius: 3, y: 1.5)
    }
}
