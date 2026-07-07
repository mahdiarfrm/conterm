import SwiftUI

/// Shared chrome for the briefing cards (Host Overview, Cluster
/// Overview, Ansible cockpit): real Liquid Glass panel, hairline
/// stroke, iridescent rim, top sheen, drop shadow. `glassLive` mounts
/// the material at rest only — an NSGlassEffectView ignores SwiftUI's
/// animated blur/opacity, so the materialize animation plays against
/// the solid bed and the material swaps in once settled (see
/// `BriefingPresenter`).
struct BriefingCard<Content: View>: View {
    let glassLive: Bool
    var width: CGFloat = 680
    let content: Content
    @EnvironmentObject private var prefs: Preferences

    init(glassLive: Bool, width: CGFloat = 680,
         @ViewBuilder content: () -> Content) {
        self.glassLive = glassLive
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            .background(panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1)
            )
            .overlay(
                // Iridescent rim — a faint static spectrum, additive so
                // it reads as light caught in the glass edge rather than
                // a painted border. Additive blend disappears against a
                // light backdrop, so the light tint draws it normally.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        AngularGradient(gradient: Gradient(colors: Theme.iridescent),
                                        center: .center, angle: .degrees(-40)),
                        lineWidth: 1.2)
                    .blendMode(prefs.lightGlass ? .normal : .plusLighter)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [Color.white.opacity(0.30), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.5), radius: 26, x: 0, y: 12)
            .frame(width: width)
    }

    /// The real material on macOS 26, mounted only at rest; while
    /// animating — and on older systems — a near-opaque solid tuned to
    /// read like the frosted material, so the swap at settle is barely
    /// perceptible.
    @ViewBuilder
    private var panelBackground: some View {
        if glassLive, #available(macOS 26, *) {
            PaneLiquidGlass(cornerRadius: 18, frostiness: 0.55,
                            light: prefs.lightGlass)
        } else {
            (prefs.lightGlass
                ? Color(red: 0.94, green: 0.95, blue: 0.97)
                : Color(red: 0.06, green: 0.065, blue: 0.08))
                .opacity(0.96)
        }
    }
}

/// Presents a briefing card centered over a soft dim, by explicit
/// animated state rather than a transition — the card must condense
/// out of a blur, and blur only animates reliably while everything on
/// screen is SwiftUI-drawn. The card builder receives the shown item
/// and a `glassLive` flag that flips true once the spawn settles.
struct BriefingPresenter<Item: Equatable, Card: View>: View {
    let item: Item?
    let onDismiss: () -> Void
    @ViewBuilder let card: (Item, Bool) -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Item?
    @State private var visible = false
    @State private var glass = false
    /// Bumped on every open/close; deferred closures compare against it
    /// so a rapid close→reopen can't apply a stale settle or teardown.
    @State private var generation = 0

    var body: some View {
        Group {
            if let shown {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture(perform: onDismiss)
                        .opacity(visible ? 1 : 0)
                    VStack {
                        Spacer(minLength: 44)
                        card(shown, glass)
                            .scaleEffect(visible ? 1.0 : 1.05)
                            .blur(radius: visible || reduceMotion ? 0 : 16)
                            .opacity(visible ? 1 : 0)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: item) { _, new in
            generation += 1
            let gen = generation
            if let new {
                shown = new
                glass = false
                // Let the dissolved state render one frame so there's
                // something to animate FROM.
                DispatchQueue.main.async {
                    withAnimation(reduceMotion
                                  ? .easeOut(duration: 0.20)
                                  : .spring(response: 0.50, dampingFraction: 0.85)) {
                        visible = true
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    if gen == generation { glass = true }
                }
            } else {
                glass = false
                withAnimation(.easeIn(duration: 0.22)) { visible = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                    if gen == generation { shown = nil }
                }
            }
        }
    }
}
