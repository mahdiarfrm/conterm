import AppKit
import SwiftUI

/// A kind's mark at a given size, in one colour — drawn, bundled as a
/// template, or an SF Symbol, never a bitmap with its own palette, so a
/// row of them reads as one set.
struct AgentToolGlyph: View {
    let kind: AgentToolKind
    var color: Color
    var size: CGFloat

    var body: some View {
        switch kind {
        case .terraform:  TerraformGlyph(color: color, size: size)
        case .ansible:    AnsibleMark(color: color, size: size)
        case .helm:       bundled("helm-mark", fallback: "sailboat.fill")
        case .docker:     bundled("docker-mark", fallback: "shippingbox.fill")
        case .github:     bundled("github-mark", fallback: "cat.fill")
        case .agent:      AgentBrandMark(color: color, size: size)
        case .kubernetes: symbol("helm")
        case .ssh:        symbol("network")
        case .git:        symbol("arrow.triangle.branch")
        case .shell:      bundled("shell-mark", fallback: "terminal")
        case .read:       symbol("doc.text")
        case .edit:       symbol("square.and.pencil")
        case .search:     symbol("text.magnifyingglass")
        case .webSearch:  symbol("sparkle.magnifyingglass")
        case .webFetch:   symbol("globe")
        case .todo:       symbol("checklist")
        case .skill:      symbol("wand.and.stars")
        case .mcp:        symbol("puzzlepiece.extension")
        }
    }

    @ViewBuilder
    private func bundled(_ asset: String, fallback: String) -> some View {
        if let img = MarkImage.load(asset, template: true) {
            Image(nsImage: img)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(color)
        } else {
            symbol(fallback)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.88, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

/// Material shared by the chrome that floats over a pane — the agent pill,
/// its tool bubbles, the History capsule. Flat and opaque on purpose: these
/// stay up for as long as an agent runs, over a terminal that is streaming,
/// so a sampled material would re-render with every frame of output. The
/// bed and ink are pinned, not adaptive — the chips sit on the terminal in
/// both appearances.
enum PanePill {
    static let bed = Color(red: 0.05, green: 0.055, blue: 0.07)
    static let ink = Color(white: 0.96)

    /// Light caught on the rim: strongest where the key light lands
    /// (top-leading), nearly gone at the far corner. Neutral, like the
    /// kit's `Drop.sheen`, but pinned light to match the bed.
    static var edge: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.05)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// One kind of call in flight as a bubble: the mark, monochrome on the
/// pill's dark bed, ringed in the kind's colour — the mark says what, the
/// ring says whose. While the call runs the ring is the same
/// compositor-side sweep the agent pill uses; a bubble held past its
/// call's end shows a still rim, with a red dot when the call failed.
/// `count` badges several calls of the kind running at once.
struct AgentToolBubble: View {
    let run: AgentToolRun
    var count: Int = 1
    var size: CGFloat = 28
    var action: () -> Void

    /// The sweep only animates while it can be seen and the machine isn't
    /// asking for less motion — same gates as the pill.
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var systemLite = false
    @State private var hovering = false

    private var color: Color { run.kind.color }
    private static let failColor = Drop.bad
    private static let bed = PanePill.bed
    private static let ink = PanePill.ink

    private var sweeps: Bool {
        run.isRunning && activeState == .key && !reduceMotion && !systemLite
    }

    private var ringColor: Color {
        if run.isRunning { return color.opacity(0.8) }
        return run.failed ? Self.failColor.opacity(0.7) : color.opacity(0.55)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Self.bed)
                Circle().strokeBorder(PanePill.edge, lineWidth: 0.75)
                AgentToolGlyph(kind: run.kind,
                               color: Self.ink.opacity(run.isRunning || hovering ? 1 : 0.75),
                               size: size * 0.52)
            }
            .frame(width: size, height: size)
            .overlay {
                if sweeps {
                    SweepRing(color: color).allowsHitTesting(false)
                } else {
                    Circle()
                        .strokeBorder(ringColor, lineWidth: run.isRunning ? 1.3 : 1.0)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(Drop.mono(size * 0.26, .bold))
                        .foregroundStyle(Self.ink)
                        .padding(.horizontal, size * 0.12)
                        .frame(height: size * 0.38)
                        .background(Capsule().fill(Self.bed))
                        .overlay(Capsule().strokeBorder(color.opacity(0.7), lineWidth: 0.8))
                        .offset(x: size * 0.12, y: size * 0.08)
                } else if !run.isRunning, run.failed {
                    Circle()
                        .fill(Self.failColor)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
                        .offset(x: size * 0.06, y: size * 0.06)
                }
            }
            // No shadow under the sweep: its halo passes are the glow, and a
            // live filter over an animating ring re-renders per frame.
            .shadow(color: color.opacity(sweeps ? 0 : (hovering ? 0.55 : 0.22)),
                    radius: hovering ? 7 : 3)
            .scaleEffect(hovering ? 1.08 : 1.0)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
        .onReceive(SystemPressure.shared.$wantsLowAnimation) { systemLite = $0 }
        .help(help)
    }

    private var help: String {
        let state: String
        if run.isRunning { state = count > 1 ? "\(count) running" : "running" }
        else if run.failed { state = "failed" }
        else { state = "done" }
        return "\(run.kind.displayName) · \(state)\n\(run.title)"
    }
}

/// The pane's record of finished calls, as one capsule leading the agent
/// pill's cluster: a count and the way in to the panel. No mark of its own —
/// a session runs many kinds of thing, and one logo would misname the rest.
/// Same flat bed as the pill and the bubbles, so the row reads as one set.
/// A call that finishes merges into the pill on the far side of the row;
/// the count rolling over, with one small swell, is where it lands.
struct AgentToolHistoryButton: View {
    let count: Int
    /// Matched to the agent pill it sits beside.
    var height: CGFloat = 26
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var swell = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PanePill.ink.opacity(hovering ? 1 : 0.7))
                Text("History")
                    .font(Drop.display(12, .semibold))
                    .foregroundStyle(PanePill.ink.opacity(hovering ? 1 : 0.85))
                Text("\(count)")
                    .font(Drop.mono(10, .medium))
                    .foregroundStyle(PanePill.ink.opacity(0.85))
                    .contentTransition(.numericText(value: Double(count)))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(PanePill.ink.opacity(0.12)))
                    .scaleEffect(swell ? 1.18 : 1)
            }
            .padding(.leading, 12).padding(.trailing, 8)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(PanePill.bed))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(PanePill.edge, lineWidth: 0.75)
                .allowsHitTesting(false))
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.22),
                    radius: hovering ? 8 : 4, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.04 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
        .animation(Theme.Spring.snappy, value: count)
        .onHover { hovering = $0 }
        .onChange(of: count) { old, new in
            guard new > old, !reduceMotion else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { swell = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { swell = false }
            }
        }
        .help("What the agent did in this pane")
    }
}

// MARK: - Budding and merging

/// The liquid between the agent pill and a chip leaving or rejoining it.
///
/// The cluster is a centred row, so when a chip is inserted the pill does
/// not stand still: it starts overlapping the chip's place and slides off
/// it by half the chip's width plus the gap. Drawn in the chip's own frame,
/// that is the pill's end cap — a circle of the row's height — travelling
/// from inside the chip to its rest position beyond the gap. The shape is
/// the chip's bed growing out from that side plus the neck surface tension
/// holds between the two, which thins to a filament and lets go before the
/// chip comes to rest. Removal runs the same thing backwards.
///
/// `progress` rides the row's own spring, so the cap drawn here stays glued
/// to the real pill through the overshoot. At rest the path is empty.
struct GooBridge: Shape {
    /// 0 joined with the pill, 1 free.
    var progress: CGFloat
    /// The side of this chip the pill is on.
    let pillEdge: HorizontalEdge
    let gap: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// How much of its size the chip has at `progress`; the chip's content
    /// scales by the same figure so bed and content stay one object.
    static func growth(_ progress: CGFloat) -> CGFloat {
        0.3 + 0.7 * min(max(progress, 0), 1)
    }

    func path(in rect: CGRect) -> Path {
        guard progress < 0.995, rect.height > 0 else { return Path() }
        let r = rect.height / 2
        let grow = Self.growth(progress)
        let leading = pillEdge == .leading

        // The pill's end cap, displaced by what remains of the row's shift.
        let shift = (rect.width + gap) / 2 * (1 - progress)
        let capX = leading ? rect.minX - gap - r + shift
                           : rect.maxX + gap + r - shift
        let cap = CGPoint(x: capX, y: rect.midY)

        // The chip's bed, grown out from the side facing the pill.
        let rb = r * grow
        let bodyWidth = rect.width * grow
        let body = CGRect(x: leading ? rect.minX : rect.maxX - bodyWidth,
                          y: rect.midY - rb, width: bodyWidth, height: rb * 2)
        let near = CGPoint(x: leading ? rect.minX + rb : rect.maxX - rb, y: rect.midY)

        var path = Path(roundedRect: body, cornerRadius: rb, style: .continuous)

        // The neck loses its spread over the back half of the travel.
        let t = min(max((progress - 0.62) / 0.36, 0), 1)
        let spread = 0.66 * (1 - t * t * (3 - 2 * t))
        if spread > 0.01,
           let neck = Self.neck(from: cap, radius: r, to: near, radius: rb, spread: spread) {
            // A true union: the neck and the bed overlap, and subpaths wound
            // in opposite directions would cancel where they do.
            path = path.union(neck)
        }

        // The pill draws its own cap, ring and glow; only what lies outside
        // it belongs to this shape.
        let capCircle = Path(ellipseIn: CGRect(x: cap.x - r, y: cap.y - r,
                                               width: r * 2, height: r * 2))
        return path.subtracting(capCircle)
    }

    /// Connector between two circles: tangent points spread around each by
    /// `spread`, joined by curves whose handles pull toward the far circle.
    /// Nil when the circles are too far apart to hold a neck or one lies
    /// inside the other.
    private static func neck(from c1: CGPoint, radius r1: CGFloat,
                             to c2: CGPoint, radius r2: CGFloat,
                             spread v: CGFloat) -> Path? {
        let d = hypot(c2.x - c1.x, c2.y - c1.y)
        guard r1 > 0, r2 > 0, d > abs(r1 - r2), d < r1 + r2 * 2.6 else { return nil }

        var u1: CGFloat = 0, u2: CGFloat = 0
        if d < r1 + r2 {
            u1 = acos(min(max((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d), -1), 1))
            u2 = acos(min(max((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d), -1), 1))
        }
        let between = atan2(c2.y - c1.y, c2.x - c1.x)
        let maxSpread = acos(min(max((r1 - r2) / d, -1), 1))

        let a1 = between + u1 + (maxSpread - u1) * v
        let a2 = between - u1 - (maxSpread - u1) * v
        let a3 = between + .pi - u2 - (.pi - u2 - maxSpread) * v
        let a4 = between - .pi + u2 + (.pi - u2 - maxSpread) * v

        func point(_ c: CGPoint, _ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
        }
        let p1 = point(c1, a1, r1), p2 = point(c1, a2, r1)
        let p3 = point(c2, a3, r2), p4 = point(c2, a4, r2)

        let reach = min(v * 3.0, hypot(p1.x - p3.x, p1.y - p3.y) / (r1 + r2))
            * min(1, d * 2 / (r1 + r2))
        let h1 = point(p1, a1 - .pi / 2, r1 * reach)
        let h2 = point(p2, a2 + .pi / 2, r1 * reach)
        let h3 = point(p3, a3 + .pi / 2, r2 * reach)
        let h4 = point(p4, a4 - .pi / 2, r2 * reach)

        var path = Path()
        path.move(to: p1)
        path.addCurve(to: p3, control1: h1, control2: h3)
        path.addLine(to: p4)
        path.addCurve(to: p2, control1: h4, control2: h2)
        path.closeSubpath()
        return path
    }
}

/// A chip's state partway between joined with the pill and free: its
/// content grown from the pill's side and faded up, on the `GooBridge` bed.
/// Driven as a transition, so it animates only while a chip arrives or
/// leaves; the identity state draws the content untouched over an empty
/// shape.
private struct GooBud: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    let pillEdge: HorizontalEdge
    let gap: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        // The bed leads and the content follows, so what buds off the pill
        // is dark liquid first and a labelled chip second.
        let ink = min(max((p - 0.2) / 0.45, 0), 1)
        content
            .scaleEffect(GooBridge.growth(progress),
                         anchor: pillEdge == .leading ? .leading : .trailing)
            .opacity(ink)
            .background {
                GooBridge(progress: progress, pillEdge: pillEdge, gap: gap)
                    .fill(PanePill.bed)
                    .allowsHitTesting(false)
            }
    }
}

extension AnyTransition {
    /// Buds off the agent pill on insertion, merges back into it on removal
    /// (see `GooBridge`). `pillEdge` is the side of the view the pill is on.
    static func gooBud(pillEdge: HorizontalEdge, gap: CGFloat) -> AnyTransition {
        .modifier(active: GooBud(progress: 0, pillEdge: pillEdge, gap: gap),
                  identity: GooBud(progress: 1, pillEdge: pillEdge, gap: gap))
    }
}

/// Calls in flight as the chrome shows them: one bubble per kind, in order
/// of first appearance, each held on screen at least `minimumShow` so a
/// call that returns in milliseconds still registers as a pop rather than
/// a flicker.
@MainActor
final class LiveToolBubbles: ObservableObject {
    struct Item: Identifiable, Equatable {
        let kind: AgentToolKind
        var count: Int
        /// The call the bubble stands for: the earliest one running, or
        /// the last one that ran while the bubble is held.
        var run: AgentToolRun
        var id: String { kind.rawValue }
    }

    @Published private(set) var items: [Item] = []
    static let minimumShow: TimeInterval = 1.2

    private var shownAt: [AgentToolKind: Date] = [:]
    private var latest: [AgentToolRun] = []
    private var generation = 0

    func sync(_ runs: [AgentToolRun]) {
        latest = runs
        let now = Date()
        var byKind: [AgentToolKind: [AgentToolRun]] = [:]
        for r in runs where r.isRunning { byKind[r.kind, default: []].append(r) }

        var next: [Item] = []
        var soonest: TimeInterval?
        for item in items {
            if let live = byKind[item.kind] {
                next.append(Item(kind: item.kind, count: live.count, run: live[0]))
                byKind[item.kind] = nil
            } else if let at = shownAt[item.kind], now.timeIntervalSince(at) < Self.minimumShow {
                // Ended before its time: keep it, showing how it ended.
                var held = item
                held.count = 1
                if let done = runs.first(where: { $0.id == item.run.id }) { held.run = done }
                next.append(held)
                let remaining = Self.minimumShow - now.timeIntervalSince(at)
                soonest = min(soonest ?? remaining, remaining)
            } else {
                shownAt[item.kind] = nil
            }
        }
        for (kind, live) in byKind.sorted(by: { $0.value[0].startedAt < $1.value[0].startedAt }) {
            next.append(Item(kind: kind, count: live.count, run: live[0]))
            shownAt[kind] = now
        }
        if next != items { items = next }
        if let soonest { resync(after: soonest + 0.05) }
    }

    private func resync(after delay: TimeInterval) {
        generation &+= 1
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.generation == gen else { return }
            self.sync(self.latest)
        }
    }
}
