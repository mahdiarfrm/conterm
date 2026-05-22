import SwiftUI

/// Launch overlay. Keeps the no-logo, big-Big-Caslon-wordmark design,
/// but **the background gradient does not move** during the active
/// phase — it's a still, painted glass page. On exit, the entire
/// overlay fades AND blurs out together.
///
/// Choreography (~3.2 s):
///   0.00 s   black backdrop fades up
///   0.20 s   color gradient page fades in (static — no drift)
///   0.40 s   wordmark blurs in
///   0.85 s   tagline fades in
///   1.10 s   ambient chord plays
///   2.40 s   the whole overlay fades + blurs out together
///   3.20 s   removed
struct LaunchOverlay: View {
    var playSound: Bool = true
    var onFinish: () -> Void

    @State private var backdropOpacity: Double = 0.0
    @State private var washOpacity:     Double = 0.0
    @State private var wordIn:          Bool   = false
    @State private var taglineIn:       Bool   = false
    @State private var exitBlur:        Double = 0.0
    @State private var overlayOpacity:  Double = 1.0
    /// One-shot guard. `.onAppear` can fire more than once for this
    /// view (its ZStack slot shifts whenever a sibling overlay toggles
    /// or SystemStats republishes). Without this guard each re-fire
    /// restarted + compounded the choreography, pinning the main
    /// thread at ~50% CPU indefinitely (looked like a freeze at the
    /// "loading animation"). The actual teardown is now owned by
    /// AppState; this view just plays its intro exactly once.
    @State private var started = false

    var body: some View {
        ZStack {
            // Black scrim
            Color.black
                .opacity(backdropOpacity * 0.78)
            // Still color gradient page
            colorWash
                .opacity(washOpacity)
            // Wordmark
            VStack(spacing: 10) {
                wordmark
                tagline
            }
        }
        .blur(radius: exitBlur)
        .opacity(overlayOpacity)
        .ignoresSafeArea()
        .onAppear(perform: runSequence)
        .allowsHitTesting(overlayOpacity > 0.3)
    }

    // MARK: - Layers

    /// Static, painted-once gradient page (no motion, no drift).
    /// Rasterized via `.drawingGroup()` so it composes cheaply.
    private var colorWash: some View {
        GeometryReader { geo in
            LinearGradient(
                stops: [
                    .init(color: .clear,                                                  location: 0.00),
                    .init(color: Color(red: 0.45, green: 0.75, blue: 1.00).opacity(0.42), location: 0.30),
                    .init(color: Color(red: 0.85, green: 0.65, blue: 1.00).opacity(0.46), location: 0.50),
                    .init(color: Color(red: 1.00, green: 0.80, blue: 0.70).opacity(0.42), location: 0.65),
                    .init(color: Color(red: 0.65, green: 1.00, blue: 0.85).opacity(0.38), location: 0.80),
                    .init(color: .clear,                                                  location: 1.00),
                ],
                startPoint: .topLeading,
                endPoint:   .bottomTrailing
            )
            .frame(width: geo.size.width, height: geo.size.height)
            .blendMode(.plusLighter)
            .drawingGroup()
        }
        .allowsHitTesting(false)
    }

    private var wordmark: some View {
        Text("Conterm")
            .font(.custom("Big Caslon", size: 96))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.96),
                        Color.white.opacity(0.78),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .blur(radius: wordIn ? 0 : 22)
            .opacity(wordIn ? 1 : 0)
            .scaleEffect(wordIn ? 1.0 : 0.96)
            .shadow(color: Color.white.opacity(0.20), radius: 30)
    }

    private var tagline: some View {
        Text("a modern way to connect")
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .tracking(3)
            .foregroundStyle(Color.white.opacity(0.55))
            .opacity(taglineIn ? 1 : 0)
    }

    // MARK: - Choreography

    private func runSequence() {
        // Idempotent: a re-fired onAppear must NOT restart the
        // choreography (that was the perpetual-redraw bug).
        guard !started else { return }
        started = true
        // 0.00 — backdrop in
        withAnimation(.easeOut(duration: 0.30)) {
            backdropOpacity = 1
        }
        // 0.20 — color page fades in (static thereafter)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            withAnimation(.easeOut(duration: 0.7)) {
                washOpacity = 1
            }
        }
        // 0.40 — wordmark blur-in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            withAnimation(.easeOut(duration: 1.0)) {
                wordIn = true
            }
        }
        // 0.85 — tagline fades in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation(.easeOut(duration: 0.6)) {
                taglineIn = true
            }
        }
        // 1.10 — chord
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.10) {
            if playSound { LaunchChime.shared.play() }
        }
        // 2.40 — fade + blur out together
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.40) {
            withAnimation(.easeIn(duration: 0.80)) {
                overlayOpacity = 0
                exitBlur = 18
            }
        }
        // 3.20 — gone
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.20) {
            onFinish()
        }
    }
}
