import AppKit
import SwiftUI

/// The agent pill's working sweep as a pure Core Animation construction.
///
/// The SwiftUI version animated an `AngularGradient`'s angle, which
/// changes the layer's CONTENTS every frame — CoreGraphics re-shades the
/// conic per frame even under `drawingGroup()`, and that re-render was
/// the dominant app-side cost while an agent works. Here the conic
/// gradient is STATIC content on a `CAGradientLayer`, and only its
/// `transform.rotation.z` animates — a compositor-side transform of
/// unchanged pixels, the same trick that makes the mark spin free. The
/// glow is baked as stacked stroke masks at growing widths and falling
/// opacities instead of a live blur filter, so nothing re-renders while
/// the ring sweeps.
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
        didSet { if glowColor != oldValue { rebuildColors() } }
    }

    /// Ring pass widths/opacities: the tight bright stroke plus two
    /// soft halos standing in for the old blur glow.
    private static let passes: [(width: CGFloat, opacity: Float)] = [
        (2.2, 1.0), (5.0, 0.34), (9.0, 0.15),
    ]

    private var wrappers: [CALayer] = []
    private var gradients: [CAGradientLayer] = []
    private var masks: [CAShapeLayer] = []
    private var lastSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for pass in Self.passes {
            let wrapper = CALayer()
            let mask = CAShapeLayer()
            mask.fillColor = NSColor.clear.cgColor
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = pass.width
            wrapper.mask = mask
            wrapper.opacity = pass.opacity

            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
            wrapper.addSublayer(gradient)

            layer?.addSublayer(wrapper)
            wrappers.append(wrapper)
            gradients.append(gradient)
            masks.append(mask)
        }
        rebuildColors()
    }

    required init?(coder: NSCoder) { nil }

    /// Mirrors the old AngularGradient stops: dark tail → glow → white
    /// bead → glow → dark.
    private func rebuildColors() {
        let g = glowColor.cgColor
        let clear = glowColor.withAlphaComponent(0).cgColor
        for gradient in gradients {
            gradient.colors = [clear, clear, g, NSColor.white.cgColor, g, clear]
            gradient.locations = [0, 0.55, 0.78, 0.84, 0.90, 1.0]
        }
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize, bounds.width > 0, bounds.height > 0 else { return }
        lastSize = bounds.size

        let capsule = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                             cornerWidth: (bounds.height - 2) / 2,
                             cornerHeight: (bounds.height - 2) / 2,
                             transform: nil)
        // The gradient square must cover the bounds at any rotation.
        let side = hypot(bounds.width, bounds.height)
        let gradientFrame = CGRect(x: bounds.midX - side / 2,
                                   y: bounds.midY - side / 2,
                                   width: side, height: side)
        for i in wrappers.indices {
            wrappers[i].frame = bounds
            masks[i].frame = bounds
            masks[i].path = capsule
            gradients[i].frame = gradientFrame
        }
        restartAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // CA strips animations when the layer leaves a window; re-arm on
        // every attach so the sweep survives chrome refreshes.
        if window != nil { restartAnimation() }
    }

    private func restartAnimation() {
        for gradient in gradients {
            gradient.removeAnimation(forKey: "sweep")
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.5
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            gradient.add(spin, forKey: "sweep")
        }
    }
}
