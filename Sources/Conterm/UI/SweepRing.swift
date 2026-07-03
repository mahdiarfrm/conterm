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
        didSet {
            guard glowColor != oldValue else { return }
            conicTexture = nil
            rebuild()
        }
    }

    /// Ring passes baked into the mask alpha: tight bright stroke plus
    /// two soft halos standing in for a blur glow.
    private static let passes: [(width: CGFloat, alpha: CGFloat)] = [
        (2.2, 1.0), (5.0, 0.34), (9.0, 0.15),
    ]
    /// Half the widest pass overhangs the capsule stroke path; the mask
    /// and rotor extend this far past bounds so the outward bloom
    /// renders instead of clipping at the view edge (the pill carries
    /// no shadow while working — these halo passes ARE the glow).
    private static let haloPad: CGFloat = 4
    /// Fixed pixel size for the conic texture. The gradient is smooth,
    /// so CA scaling it into any rotor frame is visually free — and the
    /// texture then never re-renders on a size change (the pill's width
    /// tracks its label, which changes with every progress bucket).
    private static let conicPx = 512

    private let rotor = CALayer()
    private let ringMask = CALayer()
    private var lastSize: CGSize = .zero
    private var lastScale: CGFloat = 0
    /// Rendered once per accent color at `conicPx`.
    private var conicTexture: CGImage?

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
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let w = window, w.backingScaleFactor != lastScale else { return }
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // A rebuild that ran before the first window attach used the
        // fallback scale; redo it against the real display.
        if window.backingScaleFactor != lastScale { rebuild() }
        // CA strips animations when the layer leaves a window; re-arm on
        // every attach so the sweep survives chrome refreshes.
        ensureAnimation()
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        lastSize = bounds.size
        lastScale = scale
        let pad = Self.haloPad

        if conicTexture == nil { conicTexture = Self.conicImage(color: glowColor) }

        // Manually-added sublayers get CA's default implicit actions;
        // without the guard each reframe animates 0.25 s behind the pill.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The rotating texture must cover the mask at any angle.
        let side = hypot(bounds.width, bounds.height) + pad * 2
        rotor.frame = CGRect(x: bounds.midX - side / 2,
                             y: bounds.midY - side / 2,
                             width: side, height: side)
        rotor.contents = conicTexture
        ringMask.frame = bounds.insetBy(dx: -pad, dy: -pad)
        ringMask.contents = Self.ringImage(size: bounds.size, pad: pad, scale: scale)
        CATransaction.commit()

        ensureAnimation()
    }

    /// The spin is added once and kept: re-adding it on a relayout would
    /// snap the bead back to its start angle every time the pill's label
    /// changes width.
    private func ensureAnimation() {
        guard rotor.animation(forKey: "sweep") == nil else { return }
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

    /// Conic sweep texture: dark tail → glow → white bead → glow → dark.
    private static func conicImage(color: NSColor) -> CGImage? {
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
        let px = conicPx
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
    /// of one per glow stroke. The image is `pad` larger than the view on
    /// every side so the outer half of the widest halo pass survives.
    private static func ringImage(size: CGSize, pad: CGFloat,
                                  scale: CGFloat) -> CGImage? {
        let w = Int((size.width + pad * 2) * scale)
        let h = Int((size.height + pad * 2) * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
            .insetBy(dx: 1, dy: 1)
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
