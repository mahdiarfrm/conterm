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
    private static let failColor = Color(red: 1.0, green: 0.42, blue: 0.42)
    private static let bed = Color(red: 0.05, green: 0.055, blue: 0.07)
    /// Pinned light like the pill's label: the bubble floats over the dark
    /// terminal in both appearances.
    private static let ink = Color(white: 0.96)

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
                Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
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
                        .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                        .monospacedDigit()
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

/// The pane's record of finished calls, as one glass capsule at its
/// top-left: a count and the way in to the panel. No mark of its own — a
/// session runs many kinds of thing, and one logo would misname the rest.
/// Real Liquid Glass on macOS 26; the system thin material before that.
struct AgentToolHistoryButton: View {
    let count: Int
    var action: () -> Void
    @EnvironmentObject var prefs: Preferences
    @State private var hovering = false

    private static let height: CGFloat = 26

    private var ink: Color {
        prefs.lightGlass ? Color.black.opacity(0.82) : Color.white.opacity(0.92)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ink)
                Text("History")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(ink.opacity(0.14)))
            }
            .padding(.leading, 10).padding(.trailing, 7)
            .frame(height: Self.height)
            .background(glass)
            .glassPill()
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.22),
                    radius: hovering ? 8 : 4, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.04 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
        .onHover { hovering = $0 }
        .help("What the agent did in this pane")
    }

    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26, *) {
            PaneLiquidGlass(cornerRadius: Self.height / 2, frostiness: 0.35,
                            light: prefs.lightGlass)
                .clipShape(Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
        }
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
