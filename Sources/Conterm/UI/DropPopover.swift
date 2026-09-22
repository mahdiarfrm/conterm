import AppKit
import SwiftUI

// A toolbar or sidebar popover in Liquid Drop: drawn on a drop in the
// window, under the view that opened it, rather than in a popover window —
// a drop can only refract the panes of the window it is in. The content
// travels up as a preference value, so it stays in the opener's hierarchy
// and follows the opener's state the way a native popover's does; the root
// view draws it with `DropPopoverLayer`. Classic keeps the native popover.

/// Whether a drop popover is open, and Esc on its way to one. The key
/// monitor reads `openCount`; only the popovers observe `escTick`.
@MainActor
final class DropPopoverBus: ObservableObject {
    static let shared = DropPopoverBus()
    var openCount = 0
    var isOpen: Bool { openCount > 0 }
    @Published var escTick = 0
}

struct DropPopoverItem {
    let id: UUID
    let anchor: Anchor<CGRect>
    let open: Bool
    let panel: AnyView
    let dismiss: () -> Void
}

struct DropPopoverKey: PreferenceKey {
    static var defaultValue: [DropPopoverItem] { [] }
    static func reduce(value: inout [DropPopoverItem], nextValue: () -> [DropPopoverItem]) {
        value.append(contentsOf: nextValue())
    }
}

/// Closes the popover a view sits in, in either style. Stands in for
/// `\.dismiss`, which only reaches a native presentation.
struct ClosePopoverAction {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

private struct ClosePopoverKey: EnvironmentKey {
    static var defaultValue: ClosePopoverAction { ClosePopoverAction {} }
}

private struct OnDropPopoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var closePopover: ClosePopoverAction {
        get { self[ClosePopoverKey.self] }
        set { self[ClosePopoverKey.self] = newValue }
    }

    /// True inside a popover drawn on a drop, for content that styles
    /// itself differently there.
    var onDropPopover: Bool {
        get { self[OnDropPopoverKey.self] }
        set { self[OnDropPopoverKey.self] = newValue }
    }
}

extension View {
    /// A popover anchored to this view: on a drop in Liquid Drop, native in
    /// Classic. The panel closes itself with `\.closePopover`.
    func dropPopover<Panel: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .top,
                                  @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(DropPopoverModifier(isPresented: isPresented, arrowEdge: arrowEdge,
                                     panel: panel))
    }
}

private struct DropPopoverModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let panel: () -> Panel

    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var bus = DropPopoverBus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var id = UUID()
    /// Mounted in the layer; outlasts `open` by the collapse.
    @State private var shown = false
    @State private var open = false
    @State private var counted = false
    /// Bumped on every open/close so a deferred step can't act on a later one.
    @State private var generation = 0

    func body(content: Content) -> some View {
        let close = ClosePopoverAction { isPresented = false }
        if prefs.liquidDrop {
            content
                .anchorPreference(key: DropPopoverKey.self, value: .bounds) { anchor in
                    guard shown else { return [] }
                    return [DropPopoverItem(
                        id: id, anchor: anchor, open: open,
                        panel: AnyView(panel().environment(\.closePopover, close)),
                        dismiss: { isPresented = false })]
                }
                .onChange(of: isPresented) { _, now in now ? present() : dismiss() }
                .onChange(of: bus.escTick) { _, _ in if isPresented { isPresented = false } }
                .onAppear { if isPresented { present() } }
                .onDisappear(perform: release)
        } else {
            content.popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                panel().environment(\.closePopover, close)
            }
        }
    }

    private func present() {
        generation += 1
        let gen = generation
        if !counted { counted = true; bus.openCount += 1 }
        let wasShown = shown
        shown = true
        guard !(wasShown && open) else { return }
        // Mounted closed for a frame so the drop has a state to grow from.
        DispatchQueue.main.async {
            if gen == generation { open = true }
        }
    }

    private func dismiss() {
        generation += 1
        let gen = generation
        release()
        open = false
        // A field inside the panel may have held the keyboard.
        (NSApp.delegate as? AppDelegate)?.state?.focusActiveSurface()
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.26)) {
            if gen == generation { shown = false }
        }
    }

    private func release() {
        guard counted else { return }
        counted = false
        bus.openCount = max(0, bus.openCount - 1)
    }
}

/// Draws the open drop popovers over the whole window, each under its
/// opener (over it when there is no room below). A click anywhere else
/// closes them, as a transient popover does.
struct DropPopoverLayer: View {
    let items: [DropPopoverItem]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if items.contains(where: \.open) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { items.forEach { $0.dismiss() } }
                }
                ForEach(items, id: \.id) { item in
                    AnchoredPlacement(anchor: proxy[item.anchor]) {
                        DropSurface(cornerRadius: 22, bevel: 12, calm: true,
                                    dispersion: 0.35, sceneDim: 0, formDelay: 0.08) {
                            item.panel
                                .environment(\.onDropPopover, true)
                                .padding(6)
                        }
                        .environment(\.liquidDropOpen, item.open)
                        .environment(\.liquidRevealed, item.open)
                        .disabled(!item.open)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Places one panel beside an anchor: under it when it fits or the anchor
/// is in the top half, over it otherwise; centred on it, and kept inside
/// the bounds.
private struct AnchoredPlacement: Layout {
    let anchor: CGRect
    var gap: CGFloat = 8
    var margin: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let a = anchor.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let ideal = panel.sizeThatFits(.unspecified)
        let size = CGSize(width: min(ideal.width, bounds.width - 2 * margin),
                          height: min(ideal.height, bounds.height - 2 * margin))
        let fitsBelow = a.maxY + gap + size.height <= bounds.maxY - margin
        let below = fitsBelow || a.midY < bounds.midY
        var x = a.midX - size.width / 2
        var y = below ? a.maxY + gap : a.minY - gap - size.height
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - size.width)
        y = min(max(y, bounds.minY + margin), bounds.maxY - margin - size.height)
        panel.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
    }
}
