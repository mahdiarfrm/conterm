import SwiftUI

/// Slowly drifting blobs painted into a Canvas. Visually it reads like a
/// gradient mesh that breathes; cheap because we redraw at ~30 fps with
/// trivial geometry. Sits behind the glass for a colored halo.
struct GradientMesh: View {
    var tint: Color = Theme.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let blobs = makeBlobs(at: t, in: size)
                for blob in blobs {
                    var path = Path()
                    path.addEllipse(in: blob.rect)
                    ctx.fill(path, with: .color(blob.color))
                }
            }
            .blur(radius: 80)
            .opacity(0.55)
        }
        .allowsHitTesting(false)
    }

    private struct Blob {
        var rect: CGRect
        var color: Color
    }

    private func makeBlobs(at t: TimeInterval, in size: CGSize) -> [Blob] {
        // Three blobs orbiting their anchor points at incommensurate periods
        // so the composition never visibly repeats.
        let w = size.width, h = size.height
        let r: CGFloat = min(w, h) * 0.65
        func orbit(period: Double, phase: Double, anchor: CGPoint, mag: CGFloat) -> CGPoint {
            let theta = (t / period + phase) * 2 * .pi
            return CGPoint(
                x: anchor.x + cos(theta) * mag,
                y: anchor.y + sin(theta * 0.7) * mag
            )
        }
        let c1 = orbit(period: 19.0, phase: 0.0, anchor: CGPoint(x: w*0.30, y: h*0.30), mag: w*0.10)
        let c2 = orbit(period: 23.0, phase: 0.3, anchor: CGPoint(x: w*0.75, y: h*0.40), mag: w*0.12)
        let c3 = orbit(period: 31.0, phase: 0.7, anchor: CGPoint(x: w*0.50, y: h*0.85), mag: w*0.14)
        func make(_ p: CGPoint, _ c: Color) -> Blob {
            Blob(rect: CGRect(x: p.x - r/2, y: p.y - r/2, width: r, height: r),
                 color: c.opacity(0.65))
        }
        return [
            make(c1, tint),
            make(c2, Theme.highlight),
            make(c3, Theme.surfaceTint),
        ]
    }
}
