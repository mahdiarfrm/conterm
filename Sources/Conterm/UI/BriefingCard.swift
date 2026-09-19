import SwiftUI

/// Shared chrome for the briefing cards (away briefing, Host / Cluster
/// Overview, Ansible and Terraform cockpits, worktree review, agent tools):
/// the content sits on a `LiquidDrop`, which supplies the material, the rim
/// optics, the shadow and the open/close morph. The card itself only clips
/// its content to the drop's rest shape.
struct BriefingCard<Content: View>: View {
    var width: CGFloat = 680
    let content: Content
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.liquidDropOpen) private var dropOpen
    @Environment(\.liquidRevealed) private var revealed
    @StateObject private var a11y = ReduceTransparencyObserver()

    /// Wider than the drop's bevel, so the silhouette and the refracting
    /// rim turn the corner on the same curve.
    static var cornerRadius: CGFloat { 44 }

    init(width: CGFloat = 680, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            // Unstaggered pieces (rules, scroll chrome) come and go with
            // the body; `rollUp` pieces add their own stagger on top.
            .opacity(revealed ? 1 : 0)
            .animation(revealed ? .easeOut(duration: 0.28) : .easeIn(duration: 0.10),
                       value: revealed)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .background(surface)
            .frame(width: width)
    }

    @ViewBuilder
    private var surface: some View {
        if LiquidDrop.isAvailable {
            LiquidDrop(open: dropOpen, cornerRadius: Self.cornerRadius,
                       light: prefs.lightGlass, flat: a11y.reduced)
                .padding(-LiquidDropView.bleed)
                .transaction { $0.animation = nil }
        } else {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(prefs.lightGlass
                      ? Color(red: 0.94, green: 0.95, blue: 0.97)
                      : Color(red: 0.06, green: 0.065, blue: 0.08))
                .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 26, x: 0, y: 12)
                .opacity(dropOpen ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: dropOpen)
        }
    }
}

// MARK: - Working surfaces

/// A `LiquidDrop` for working chrome — palettes, search, small panels —
/// rather than an arrival: calm motion, low dispersion, any corner radius.
/// The content holds back until the drop under it has formed, both on the
/// presenter's open and when a surface mounts later, so it never sits on
/// bare terminal. Present it inside a `BriefingPresenter` (or anything else
/// that sets `liquidDropOpen` / `liquidRevealed`).
struct DropSurface<Content: View>: View {
    let cornerRadius: CGFloat
    /// Bevel cap for the drop; a thin surface needs a narrow rim.
    var bevel: CGFloat = 16
    var calm = true
    var dispersion: Float = 0.35
    /// The dim the presenter lays over the scene.
    var sceneDim: Float = 0.25
    var formDelay: Double = 0.16
    /// Scrolling content dissolves at the top and bottom instead of being
    /// cut by the rim.
    var fadesEdges = false
    @ViewBuilder var content: Content

    @EnvironmentObject private var prefs: Preferences
    @Environment(\.liquidDropOpen) private var dropOpen
    @Environment(\.liquidRevealed) private var revealed
    @StateObject private var a11y = ReduceTransparencyObserver()
    @State private var formed = false

    var body: some View {
        let shown = revealed && formed
        content
            .mask {
                if fadesEdges {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.035),
                        .init(color: .black, location: 0.95),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                } else {
                    Color.black
                }
            }
            .opacity(shown ? 1 : 0)
            .animation(shown ? .easeOut(duration: 0.22) : .easeIn(duration: 0.08), value: shown)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(surface)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + formDelay) { formed = true }
            }
    }

    @ViewBuilder
    private var surface: some View {
        if LiquidDrop.isAvailable {
            LiquidDrop(open: dropOpen, cornerRadius: cornerRadius,
                       light: prefs.lightGlass, flat: a11y.reduced,
                       bevel: bevel, calm: calm, dispersion: dispersion,
                       sceneDim: sceneDim)
                .padding(-LiquidDropView.bleed)
                // A surface inserted inside an animated transaction would
                // have its NSView's frame animated in from the window's
                // origin. The drop has its own arrival; it lands in place.
                .transaction { $0.animation = nil }
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.panelBed)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 12)
                .opacity(dropOpen ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: dropOpen)
        }
    }
}

// MARK: - Presentation state

private struct LiquidDropOpenKey: EnvironmentKey {
    static let defaultValue = true
}

private struct LiquidRevealedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the presenting drop is collapsing.
    var liquidDropOpen: Bool {
        get { self[LiquidDropOpenKey.self] }
        set { self[LiquidDropOpenKey.self] = newValue }
    }

    /// True once the drop has formed enough to carry content. `rollUp`
    /// reveals hold until then; defaults to true so they run on appearance
    /// anywhere else.
    var liquidRevealed: Bool {
        get { self[LiquidRevealedKey.self] }
        set { self[LiquidRevealedKey.self] = newValue }
    }
}

// MARK: - Content motion

extension AnyTransition {
    /// Content swapped inside a drop — a loaded state replacing a spinner, a
    /// section changing under a filter — rises in and dissolves out instead
    /// of cutting.
    static var liquidSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: LiquidSwapState(progress: 0),
                                 identity: LiquidSwapState(progress: 1))
                .animation(.spring(response: 0.50, dampingFraction: 0.82)),
            removal: .opacity.animation(.easeIn(duration: 0.10)))
    }
}

private struct LiquidSwapState: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        // Opacity and travel only — this wraps whole card bodies, and an
        // animated blur that size costs the frames the swap is meant to use.
        content
            .opacity(progress)
            .offset(y: (1 - progress) * 10)
    }
}

// MARK: - Presenter

/// Presents a briefing card centered over a soft dim. The drop animates
/// itself (see `LiquidDropView`); the presenter only sequences the phases:
/// mount, reveal the content once the body has formed, then on dismissal
/// hide the content, let the drop collapse, and unmount.
struct BriefingPresenter<Item: Equatable, Card: View>: View {
    let item: Item?
    /// Where the card sits in the window — centred unless the caller
    /// anchors it — and the margins it keeps from the window's edges. The
    /// margins are equal top and bottom so "centre" is the window's centre.
    var alignment: Alignment = .center
    var insets = EdgeInsets(top: 44, leading: 0, bottom: 44, trailing: 0)
    /// Scene dim under the card. A surface's `sceneDim` should match it.
    var dim: Double = 0.25
    let onDismiss: () -> Void
    @ViewBuilder let card: (Item) -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Item?
    @State private var open = false
    @State private var revealed = false
    /// Bumped on every open/close; deferred closures compare against it
    /// so a rapid close→reopen can't apply a stale reveal or teardown.
    @State private var generation = 0

    var body: some View {
        Group {
            if let shown {
                ZStack {
                    Color.black.opacity(dim)
                        .ignoresSafeArea()
                        .onTapGesture(perform: onDismiss)
                        .opacity(open ? 1 : 0)
                        .animation(.easeOut(duration: 0.30), value: open)
                    card(shown)
                        .environment(\.liquidDropOpen, open)
                        .environment(\.liquidRevealed, revealed)
                        .padding(insets)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: alignment)
                }
            }
        }
        .onChange(of: item) { _, new in
            generation += 1
            let gen = generation
            if let new {
                shown = new
                revealed = false
                // Mount closed for one frame so the dim has a state to
                // fade from.
                DispatchQueue.main.async {
                    if gen == generation { open = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.24)) {
                    if gen == generation { revealed = true }
                }
            } else {
                revealed = false
                open = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    if gen == generation { shown = nil }
                }
            }
        }
    }
}
