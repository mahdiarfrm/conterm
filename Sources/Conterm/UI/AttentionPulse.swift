import AppKit
import SwiftUI

/// A "needs you" pulse run by Core Animation: the amber rim on a waiting
/// pane, the dot on its tab, the agent pill's ring.
///
/// A SwiftUI-driven loop (`TimelineView(.animation)`, `repeatForever`)
/// re-renders its hosting view's graph every frame on macOS, and an agent
/// can wait for input for hours, in several panes at once. Here each pulse
/// is a layer animation the render server plays by itself, so the app does
/// no work per frame. The glow is cast from a fixed shadow path (the
/// outline's own shape) rather than from the layer's alpha, which would
/// cost an offscreen pass every frame. Pulses start on a clock-aligned
/// cycle, so the ones on screen together stay in step.
struct AttentionPulse: NSViewRepresentable {
    struct Layer: Equatable {
        enum Shape: Equatable {
            case roundedRect(cornerRadius: CGFloat)
            case capsule
            case circle
        }
        var shape: Shape
        var color: NSColor
        /// Outline width, drawn inside the bounds; 0 fills the shape.
        var lineWidth: CGFloat = 0
        /// The layer's opacity at the dim and bright ends of the cycle.
        var opacity: ClosedRange<Float>
        /// Glow opacity and radius at the two ends; nil for no glow. The
        /// glow is scaled by `opacity` as well.
        var glowOpacity: ClosedRange<Float>? = nil
        var glowRadius: ClosedRange<CGFloat>? = nil
    }

    var layers: [Layer]
    /// Seconds for one dim → bright → dim cycle.
    var period: Double

    func makeNSView(context: Context) -> AttentionPulseView {
        let view = AttentionPulseView()
        view.configure(layers, period: period)
        return view
    }

    func updateNSView(_ view: AttentionPulseView, context: Context) {
        view.configure(layers, period: period)
    }
}

final class AttentionPulseView: NSView {
    private var specs: [AttentionPulse.Layer] = []
    private var period: Double = 1
    private var shapeLayers: [CAShapeLayer] = []
    private var lastBounds: CGRect = .null

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Decoration only: clicks go to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ specs: [AttentionPulse.Layer], period: Double) {
        guard specs != self.specs || period != self.period else { return }
        self.specs = specs
        self.period = period
        shapeLayers.forEach { $0.removeFromSuperlayer() }
        shapeLayers = specs.map { _ in CAShapeLayer() }
        for shape in shapeLayers { layer?.addSublayer(shape) }
        lastBounds = .null
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if bounds != lastBounds {
            lastBounds = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (spec, shape) in zip(specs, shapeLayers) { draw(spec, into: shape) }
            CATransaction.commit()
        }
        startPulses()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startPulses()
    }

    private func draw(_ spec: AttentionPulse.Layer, into shape: CAShapeLayer) {
        shape.frame = bounds
        let inset = spec.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path: CGPath
        switch spec.shape {
        case .roundedRect(let radius):
            path = RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous)
                .path(in: rect).cgPath
        case .capsule:
            path = Capsule(style: .continuous).path(in: rect).cgPath
        case .circle:
            path = Circle().path(in: rect).cgPath
        }
        shape.path = path
        if spec.lineWidth > 0 {
            shape.fillColor = nil
            shape.strokeColor = spec.color.cgColor
            shape.lineWidth = spec.lineWidth
            shape.shadowPath = path.copy(strokingWithWidth: spec.lineWidth, lineCap: .butt,
                                         lineJoin: .round, miterLimit: 1)
        } else {
            shape.fillColor = spec.color.cgColor
            shape.strokeColor = nil
            shape.shadowPath = path
        }
        shape.shadowColor = spec.color.cgColor
        shape.shadowOffset = .zero
        // Model values at the dim end; the animation swings from there.
        shape.opacity = spec.opacity.lowerBound
        shape.shadowOpacity = spec.glowOpacity?.lowerBound ?? 0
        shape.shadowRadius = spec.glowRadius?.lowerBound ?? 0
    }

    private func startPulses() {
        guard window != nil else { return }
        for (spec, shape) in zip(specs, shapeLayers) where shape.animation(forKey: "pulse") == nil {
            let half = period / 2
            func swing(_ key: String, _ from: Any, _ to: Any) -> CABasicAnimation {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from
                a.toValue = to
                a.duration = half
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return a
            }
            var parts = [swing("opacity", spec.opacity.lowerBound, spec.opacity.upperBound)]
            if let o = spec.glowOpacity {
                parts.append(swing("shadowOpacity", o.lowerBound, o.upperBound))
            }
            if let r = spec.glowRadius {
                parts.append(swing("shadowRadius", r.lowerBound, r.upperBound))
            }
            let group = CAAnimationGroup()
            group.animations = parts
            group.duration = half
            group.autoreverses = true
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            // A slow fade reads the same at 30 fps and costs the
            // compositor half as much as 60.
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30,
                                                             preferred: 30)
            // Aligned to the cycle on the shared clock, so pulses started at
            // different moments run in step.
            let now = shape.convertTime(CACurrentMediaTime(), from: nil)
            group.beginTime = now - fmod(now, period)
            shape.add(group, forKey: "pulse")
        }
    }
}
