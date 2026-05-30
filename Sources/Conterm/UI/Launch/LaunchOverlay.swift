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
            // Static page-spanning color gradient (kept as a soft base).
            colorWash
                .opacity(washOpacity)
            // Animated coloured blobs drifting through the backdrop
            // for the full duration of the overlay. Layered over the
            // wash + under the wordmark; opacity fades with the rest.
            movingColors
                .opacity(washOpacity * 0.95)
            // Film grain on top of the colour layers — animated so it
            // shimmers instead of reading as a still texture.
            grain
                .opacity(washOpacity * 0.55)
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

    /// Four large, blurred colour blobs that drift on independent sine
    /// orbits. TimelineView keeps them animating smoothly without a
    /// SwiftUI value-based animation that would have to re-evaluate
    /// the whole view tree on every frame.
    private var movingColors: some View {
        GeometryReader { geo in
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let palette: [Color] = [
                    Color(red: 0.45, green: 0.75, blue: 1.00),
                    Color(red: 0.85, green: 0.65, blue: 1.00),
                    Color(red: 1.00, green: 0.80, blue: 0.70),
                    Color(red: 0.65, green: 1.00, blue: 0.85),
                ]
                let w = geo.size.width, h = geo.size.height
                Canvas { ctx, size in
                    for i in 0..<palette.count {
                        let phase = Double(i) * 1.7
                        let dx = (sin(t * 0.18 + phase) * 0.30 + 0.50) * w
                        let dy = (cos(t * 0.13 + phase * 1.4) * 0.30 + 0.50) * h
                        let radius = min(w, h) * 0.55
                        let blob = Path(ellipseIn: CGRect(
                            x: dx - radius / 2,
                            y: dy - radius / 2,
                            width: radius, height: radius))
                        var blurredCtx = ctx
                        blurredCtx.addFilter(.blur(radius: 110))
                        blurredCtx.fill(blob, with: .color(palette[i].opacity(0.55)))
                    }
                }
                .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }

    /// Film-grain layer. Canvas re-renders each frame so dots shift
    /// per frame and read as live grain rather than a fixed dither.
    private var grain: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Deterministic-but-shifting noise: seed from t.
                var rng = SeededRandom(seed: UInt64(t * 60))
                let count = 5500
                for _ in 0..<count {
                    let x = CGFloat(rng.next01()) * size.width
                    let y = CGFloat(rng.next01()) * size.height
                    let a = Double(rng.next01()) * 0.18
                    ctx.fill(
                        Path(CGRect(x: x, y: y, width: 1, height: 1)),
                        with: .color(Color.white.opacity(a))
                    )
                }
            }
            .blendMode(.overlay)
        }
        .allowsHitTesting(false)
    }

    private var wordmark: some View {
        // The bundled text-logo PNG is a white-on-transparent wordmark
        // (see docs/assets/text-logo.png). Treated as a template so
        // the foreground gradient tints it the same way the old
        // Big Caslon text did.
        Image(nsImage: Self.textLogo)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: 96)
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

    /// Cheap deterministic PRNG. Avoids a per-frame `Int.random` syscall
    /// for the grain layer (4–5k points per frame is enough to feel
    /// the system jitter otherwise).
    private struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func next01() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }
    }

    /// One-shot bundle load of the wordmark PNG. Template mode lets
    /// SwiftUI's foreground tint take over so the same asset reads
    /// on dark and light backgrounds.
    private static let textLogo: NSImage = {
        if let url = Bundle.main.url(forResource: "text-logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        return NSImage(size: .zero)
    }()

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
