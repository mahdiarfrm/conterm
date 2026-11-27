import SwiftUI

/// The launch animation, the same in both interface styles and set like
/// the welcome's hero: the brand's colour fields bloom over the ink page
/// and drift while it plays, and the cream wordmark comes out of a blur at
/// the lower left with the branded eyebrow above and the tagline below.
/// To leave, the words blur away, the colour fields run off past the
/// edges, and the page fades onto the window. About 2.2 seconds, played
/// once per mount; nothing in it repeats, and nothing draws once it's
/// gone.
struct LaunchIntro: View {
    let light: Bool
    let playSound: Bool
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bloom: CGFloat = 0.7
    @State private var auroraIn = false
    @State private var drifted = false
    @State private var markIn = false
    @State private var linesIn = false
    /// The words blur and fade first…
    @State private var wordsOut = false
    /// …then the colour runs off the screen…
    @State private var colorsOut = false
    /// …and the page fades onto the window.
    @State private var groundOut = false

    private let markHeight: CGFloat = 72
    private let margin: CGFloat = 56

    private var aurora: WelcomeAurora {
        let base: WelcomeAurora = drifted ? .spectrumDrift : .spectrum
        return colorsOut ? base.runaway() : base
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let mark = WelcomeWordmark(style: WelcomeColor.wordmark(light), height: markHeight)
            let top = size.height - 206
            ZStack(alignment: .topLeading) {
                WelcomeColor.ground(light)
                    .opacity(groundOut ? 0 : 1)
                WelcomeAuroraView(aurora: aurora, light: light, bloom: bloom,
                                  softness: colorsOut ? 0.14 : 0.08)
                    .opacity(auroraIn && !colorsOut ? 1 : 0)
                WelcomeGrain(light: light)
                    .opacity(groundOut ? 0 : 1)
                ZStack(alignment: .topLeading) {
                    DropEyebrow("Conterm", branded: true)
                        .opacity(linesIn ? 1 : 0)
                        .offset(x: margin + 2, y: top - 40 + (linesIn ? 0 : 9))
                    mark
                        .blur(radius: markIn ? 0 : 22)
                        .opacity(markIn ? 1 : 0)
                        .offset(x: margin, y: top)
                    WelcomeTagline(light: light)
                        .opacity(linesIn ? 1 : 0)
                        .offset(x: margin + 4, y: top + markHeight + 22 + (linesIn ? 0 : 9))
                }
                .blur(radius: wordsOut ? 18 : 0)
                .opacity(wordsOut ? 0 : 1)
                .offset(y: wordsOut ? -16 : 0)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .allowsHitTesting(!groundOut)
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                auroraIn = true; bloom = 1; markIn = true; linesIn = true
            }
            if playSound { LaunchChime.shared.play() }
            guard await pause(1100) else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                wordsOut = true; groundOut = true; auroraIn = false
            }
            guard await pause(380) else { return }
            onFinish()
            return
        }
        withAnimation(.easeOut(duration: 0.7)) { auroraIn = true }
        withAnimation(.spring(response: 1.3, dampingFraction: 0.86)) { bloom = 1 }
        withAnimation(.timingCurve(0.45, 0, 0.35, 1, duration: 2.4)) { drifted = true }
        guard await pause(200) else { return }
        withAnimation(.easeOut(duration: 0.9)) { markIn = true }
        if playSound { LaunchChime.shared.play() }
        guard await pause(350) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { linesIn = true }
        guard await pause(850) else { return }
        withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: 0.45)) { wordsOut = true }
        guard await pause(60) else { return }
        // Outward and accelerating, softening as they go; they fade only
        // late, so most of each field leaves past the edge.
        withAnimation(.timingCurve(0.5, 0, 0.75, 0.4, duration: 0.75)) { colorsOut = true }
        guard await pause(150) else { return }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.6)) { groundOut = true }
        guard await pause(640) else { return }
        onFinish()
    }

    private func pause(_ milliseconds: Int) async -> Bool {
        (try? await Task.sleep(for: .milliseconds(milliseconds))) != nil
    }
}

/// Mounts the launch animation with the tint latched, so changing it while
/// the intro plays can't restyle it mid-sequence.
struct LaunchOverlayHost: View {
    let playSound: Bool
    let onFinish: () -> Void
    @State private var light: Bool

    init(light: Bool, playSound: Bool, onFinish: @escaping () -> Void) {
        _light = State(initialValue: light)
        self.playSound = playSound
        self.onFinish = onFinish
    }

    var body: some View {
        LaunchIntro(light: light, playSound: playSound, onFinish: onFinish)
    }
}
