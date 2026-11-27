import AppKit
import SwiftUI

/// The welcome's motion, in the chrome's own terms: content rolls up into
/// place on arrival, controls answer the pointer with the kit's hover
/// springs, and the colour behind drifts once per step. Nothing loops.
enum WelcomeMotion {
    /// Things travelling between places: the wordmark, the preview.
    static let glide = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// The card and the preview settling in, as `rollUp` does.
    static let arrive = Animation.spring(response: 0.5, dampingFraction: 0.78)
    /// The site's ease, for fades and reveals.
    static let ease = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)
    static let depart = Animation.easeOut(duration: 0.14)
    /// The colour fields moving to a step's arrangement.
    static let drift = Animation.spring(response: 1.3, dampingFraction: 0.86)
    /// The preview window growing into the real one at Finish.
    static let grow = Animation.spring(response: 0.55, dampingFraction: 0.88)
}

/// Brand colours the chrome palette doesn't carry.
enum WelcomeColor {
    /// The page under everything: the site's ink (#080A0E), or the light
    /// backdrop the glass tints share.
    static func ground(_ light: Bool) -> Color {
        light ? Color(red: 0.925, green: 0.935, blue: 0.96)
              : Color(red: 0.031, green: 0.039, blue: 0.055)
    }

    /// The wordmark: warm cream (#F4F2EC to sand), never a cold white, or
    /// ink on a light page.
    static func wordmark(_ light: Bool) -> AnyShapeStyle {
        light ? AnyShapeStyle(Color(red: 0.08, green: 0.09, blue: 0.12))
              : AnyShapeStyle(LinearGradient(
                    colors: [Color(red: 0.97, green: 0.95, blue: 0.90),
                             Color(red: 0.90, green: 0.86, blue: 0.78)],
                    startPoint: .top, endPoint: .bottom))
    }

    static func tagline(_ light: Bool) -> Color {
        light ? Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.5)
              : Color(red: 0.95, green: 0.91, blue: 0.82).opacity(0.55)
    }

    // The site's accents.
    static let cyan = Color(red: 0.486, green: 0.780, blue: 0.910)     // #7CC7E8
    static let violet = Color(red: 0.765, green: 0.608, blue: 0.949)   // #C39BF2
    static let mint = Color(red: 0.357, green: 0.831, blue: 0.604)     // #5BD49A
    static let amber = Color(red: 0.961, green: 0.710, blue: 0.267)    // #F5B544
    static let blue = Color(red: 0.26, green: 0.42, blue: 0.88)
    static let pink = Color(red: 1.00, green: 0.55, blue: 0.72)
    static let coral = Color(red: 1.00, green: 0.42, blue: 0.34)
    static let red = Color(red: 1.00, green: 0.22, blue: 0.24)         // #FF383C
}

/// An arrangement of soft colour fields in the brand's accents: the full
/// spectrum for the launch and the hero, a quieter set for each step.
struct WelcomeAurora: Equatable {
    /// Each field's colour, with its strength in the alpha.
    let colors: [Color]
    /// Each field's centre, in unit coordinates of the stage.
    let spots: [CGPoint]
    /// Each field's diameter, as a share of the stage's longer side.
    let sizes: [CGFloat]

    /// The launch and the welcome's hero: every accent at once.
    static let spectrum = aurora(
        [(WelcomeColor.cyan, 0.44), (WelcomeColor.violet, 0.42), (WelcomeColor.pink, 0.34),
         (WelcomeColor.amber, 0.30), (WelcomeColor.mint, 0.30)],
        [(0.20, 0.30), (0.60, 0.20), (0.86, 0.60), (0.48, 0.86), (0.10, 0.76)],
        [0.48, 0.52, 0.44, 0.42, 0.40])

    /// Where `spectrum` drifts to while the launch or the hero plays.
    static let spectrumDrift = aurora(
        [(WelcomeColor.cyan, 0.44), (WelcomeColor.violet, 0.42), (WelcomeColor.pink, 0.34),
         (WelcomeColor.amber, 0.30), (WelcomeColor.mint, 0.30)],
        [(0.34, 0.20), (0.80, 0.34), (0.66, 0.80), (0.24, 0.72), (0.06, 0.38)],
        [0.50, 0.50, 0.46, 0.40, 0.42])

    static func of(_ step: WelcomeFlow.Step) -> WelcomeAurora {
        switch step {
        case .hero:
            return spectrum
        case .config:
            return aurora([(WelcomeColor.cyan, 0.34), (WelcomeColor.blue, 0.30),
                           (WelcomeColor.violet, 0.24), (WelcomeColor.mint, 0.16)],
                          [(0.80, 0.26), (0.62, 0.78), (0.96, 0.62), (0.08, 0.92)],
                          [0.50, 0.52, 0.40, 0.42])
        case .look:
            return aurora([(WelcomeColor.violet, 0.32), (WelcomeColor.pink, 0.22),
                           (WelcomeColor.cyan, 0.26), (WelcomeColor.blue, 0.22)],
                          [(0.74, 0.20), (0.92, 0.70), (0.56, 0.90), (0.04, 0.10)],
                          [0.50, 0.44, 0.44, 0.40])
        case .layout:
            return aurora([(WelcomeColor.mint, 0.26), (WelcomeColor.cyan, 0.30),
                           (WelcomeColor.blue, 0.26), (WelcomeColor.violet, 0.18)],
                          [(0.78, 0.32), (0.60, 0.84), (0.98, 0.76), (0.06, 0.86)],
                          [0.48, 0.50, 0.40, 0.40])
        case .keys:
            return aurora([(WelcomeColor.amber, 0.24), (WelcomeColor.coral, 0.20),
                           (WelcomeColor.violet, 0.24), (WelcomeColor.cyan, 0.20)],
                          [(0.74, 0.24), (0.90, 0.72), (0.56, 0.92), (0.06, 0.18)],
                          [0.46, 0.44, 0.44, 0.38])
        case .finish:
            return aurora([(WelcomeColor.red, 0.28), (WelcomeColor.cyan, 0.28),
                           (WelcomeColor.violet, 0.26), (WelcomeColor.amber, 0.18)],
                          [(0.34, 0.30), (0.76, 0.30), (0.72, 0.80), (0.28, 0.82)],
                          [0.48, 0.48, 0.48, 0.44])
        }
    }

    /// The same fields flung outward from the centre, each past its
    /// nearest edge: the colour leaving the screen.
    func runaway() -> WelcomeAurora {
        WelcomeAurora(
            colors: colors,
            spots: spots.map { p in
                let dx = p.x - 0.5, dy = p.y - 0.5
                let length = max((dx * dx + dy * dy).squareRoot(), 0.05)
                return CGPoint(x: p.x + dx / length, y: p.y + dy / length)
            },
            sizes: sizes.map { $0 * 1.2 })
    }

    private static func aurora(_ fields: [(Color, Double)],
                               _ spots: [(CGFloat, CGFloat)],
                               _ sizes: [CGFloat]) -> WelcomeAurora {
        WelcomeAurora(colors: fields.map { $0.0.opacity($0.1) },
                      spots: spots.map { CGPoint(x: $0.0, y: $0.1) },
                      sizes: sizes)
    }
}

/// The colour fields behind the stage. Light adds on a dark page, so the
/// fields glow; on a light page they tint it. Still unless the
/// arrangement, the bloom or the softness changes.
struct WelcomeAuroraView: View {
    let aurora: WelcomeAurora
    let light: Bool
    /// Scale of the whole arrangement: below 1 while it blooms in, above 1
    /// as it swells away.
    var bloom: CGFloat = 1
    /// Blur radius as a share of the stage's longer side; raised as the
    /// fields leave, so they soften on the way out.
    var softness: CGFloat = 0.08

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ZStack {
                ForEach(aurora.colors.indices, id: \.self) { i in
                    Circle()
                        .fill(aurora.colors[i])
                        .frame(width: side * aurora.sizes[i], height: side * aurora.sizes[i])
                        .position(x: geo.size.width * aurora.spots[i].x,
                                  y: geo.size.height * aurora.spots[i].y)
                }
            }
            .scaleEffect(bloom)
            .blur(radius: side * softness)
            .opacity(light ? 0.75 : 1)
            .blendMode(light ? .normal : .plusLighter)
        }
        .allowsHitTesting(false)
    }
}

/// A fine, still film grain over the colour, so it reads as a surface.
struct WelcomeGrain: View {
    let light: Bool

    private static let tile: NSImage = {
        let n = 128
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            let v = UInt8.random(in: 0...255)
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return NSImage(size: .zero) }
        return NSImage(cgImage: image, size: NSSize(width: n, height: n))
    }()

    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            .opacity(light ? 0.03 : 0.05)
            .blendMode(light ? .multiply : .overlay)
            .allowsHitTesting(false)
    }
}

/// The main action: a capsule in the ink colour with the bed colour for
/// its label, the same pairing as an on switch.
struct WelcomePrimaryButton: View {
    let title: String
    var symbol: String = "arrow.right"
    /// Bumped by a key press, so Return gets the same dip as a click.
    var pressTick = 0
    let action: () -> Void
    @State private var hovering = false
    @State private var dip = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .id(title)
                    .transition(.opacity.animation(.easeInOut(duration: 0.16)))
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
            }
            .font(Drop.display(13.5, .semibold))
            .foregroundStyle(Theme.panelBed)
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background(Capsule().fill(Theme.textPrimary))
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
            .scaleEffect(dip ? 0.95 : (hovering ? 1.03 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(WelcomePressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovering)
        .onChange(of: pressTick) { _, _ in
            withAnimation(.easeOut(duration: 0.08)) { dip = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { dip = false }
            }
        }
    }
}

/// A slight sink while held.
struct WelcomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// One answer among several, as a row in a well: a ring that fills with
/// the sheen when picked, a title, a line on what it does, and a chip.
struct WelcomeOptionRow: View {
    let title: String
    let detail: String
    var badge: String? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? AnyShapeStyle(Drop.sheen)
                                                   : AnyShapeStyle(Theme.strokeStrong),
                                          lineWidth: selected ? 1.2 : 1)
                    Circle().fill(Drop.sheen).padding(4).opacity(selected ? 1 : 0)
                        .scaleEffect(selected ? 1 : 0.4)
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(Drop.display(13, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let badge { DropChip(text: badge, tint: Theme.textPrimary) }
                    }
                    Text(detail)
                        .font(Drop.display(11.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(shape.fill(Theme.selectionFill.opacity(selected ? 1 : (hovering ? 0.7 : 0))))
            .overlay(shape.strokeBorder(Drop.sheen, lineWidth: 0.75).opacity(selected ? 0.55 : 0))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A labelled switch row for a well.
struct WelcomeSwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Drop.display(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(Drop.display(11.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
            }
        }
        .toggleStyle(.drop)
        .disabled(!enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// A key as the site prints it: an 8 pt cap in the mono face. Lit, it
/// presses down and takes the sheen rim.
struct WelcomeKeycap: View {
    let text: String
    var lit = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Text(text)
            .font(Drop.mono(12, .medium))
            .foregroundStyle(lit ? Theme.textPrimary : Theme.textPrimary.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 26)
            .background(shape.fill(lit ? Theme.strokeStrong : Theme.selectionFill))
            .overlay(shape.strokeBorder(lit ? AnyShapeStyle(Drop.sheen) : AnyShapeStyle(Theme.stroke),
                                        lineWidth: lit ? 1 : 0.75))
            .shadow(color: .black.opacity(lit ? 0 : 0.25), radius: 0, y: lit ? 0 : 2)
            .offset(y: lit ? 1.5 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.68), value: lit)
    }
}
