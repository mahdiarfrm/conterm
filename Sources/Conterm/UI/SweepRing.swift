import AppKit
import SwiftUI

/// The agent pill's working sweep as a pure Core Animation construction.
///
/// Two costs shaped this design. App-side: animating a SwiftUI
/// `AngularGradient`'s angle (or any SwiftUI `repeatForever`) re-renders
/// the hosting view's graph every frame on macOS — so the motion lives
/// entirely in CA, driven by one `transform.rotation.z` animation.
/// Compositor-side: procedural gradient layers and stacked masks made
/// WindowServer re-render several offscreen passes per frame — so the
/// conic gradient is pre-rendered ONCE into a static texture, and the
/// capsule ring with its whole glow falloff is baked into ONE feathered
/// mask image. Per frame the render server rotates one unchanged
/// texture through one unchanged mask.
struct SweepRing: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> SweepRingView {
        let v = SweepRingView()
        v.glowColor = NSColor(color)
        return v
    }

    func updateNSView(_ v: SweepRingView, context: Context) {
        v.glowColor = NSColor(color)
    }
}

final class SweepRingView: NSView {
    var glowColor: NSColor = .orange {
        didSet { if glowColor != oldValue { rebuild() } }
    }

    /// Ring passes baked into the mask alpha: tight bright stroke plus
    /// two soft halos standing in for a blur glow.
    private static let passes: [(width: CGFloat, alpha: CGFloat)] = [
        (2.2, 1.0), (5.0, 0.34), (9.0, 0.15),
    ]

    private let rotor = CALayer()
    private let ringMask = CALayer()
    private var lastSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = ringMask
        layer?.addSublayer(rotor)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize, bounds.width > 0, bounds.height > 0 else { return }
        lastSize = bounds.size
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // CA strips animations when the layer leaves a window; re-arm on
        // every attach so the sweep survives chrome refreshes.
        if window != nil { restartAnimation() }
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2

        // The rotating texture must cover the bounds at any angle.
        let side = hypot(bounds.width, bounds.height)
        rotor.frame = CGRect(x: bounds.midX - side / 2,
                             y: bounds.midY - side / 2,
                             width: side, height: side)
        rotor.contents = Self.conicImage(color: glowColor, side: side, scale: scale)

        ringMask.frame = bounds
        ringMask.contents = Self.ringImage(size: bounds.size, scale: scale)

        restartAnimation()
    }

    private func restartAnimation() {
        rotor.removeAnimation(forKey: "sweep")
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.5
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        // Sustained compositing is priced per frame: a continuous 60 fps
        // animation holds WindowServer at ~25-30 points no matter how
        // cheap each frame is. 30 fps still reads fluid for a glow sweep
        // and halves that floor.
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 24,
                                                        maximum: 30,
                                                        preferred: 30)
        rotor.add(spin, forKey: "sweep")
    }

    /// Conic sweep texture, rendered once. Mirrors the old
    /// AngularGradient stops: dark tail → glow → white bead → glow → dark.
    private static func conicImage(color: NSColor, side: CGFloat,
                                   scale: CGFloat) -> CGImage? {
        let g = CAGradientLayer()
        g.type = .conic
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1.0, y: 0.5)
        g.colors = [color.withAlphaComponent(0).cgColor,
                    color.withAlphaComponent(0).cgColor,
                    color.cgColor,
                    NSColor.white.cgColor,
                    color.cgColor,
                    color.withAlphaComponent(0).cgColor]
        g.locations = [0, 0.55, 0.78, 0.84, 0.90, 1.0]
        let px = Int(side * scale)
        g.frame = CGRect(x: 0, y: 0, width: px, height: px)
        guard let ctx = CGContext(data: nil, width: px, height: px,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        g.render(in: ctx)
        return ctx.makeImage()
    }

    /// The capsule ring with its glow falloff baked into one alpha image
    /// (used as a layer mask): a single offscreen pass per frame instead
    /// of one per glow stroke.
    private static func ringImage(size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let capsule = CGPath(roundedRect: rect,
                             cornerWidth: rect.height / 2,
                             cornerHeight: rect.height / 2,
                             transform: nil)
        for pass in passes {
            ctx.addPath(capsule)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(pass.alpha).cgColor)
            ctx.setLineWidth(pass.width)
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}
