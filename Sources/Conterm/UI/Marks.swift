import SwiftUI

/// Brand marks used by chrome outside the feature that introduced them —
/// the layout switcher carries `OrbitMark`, so the glyphs live here rather
/// than inside a feature view.
///
/// Each loads a bundled template image through `MarkImage` and falls back to
/// an SF Symbol when the asset is missing.

/// The Ansible brand mark — the bundled `ansible-mark` template, tinted; the
/// same glyph the Ansible widget uses.
struct AnsibleMark: View {
    var color: Color = Theme.textPrimary
    var size: CGFloat = 12
    var body: some View {
        if let img = MarkImage.load("ansible-mark", template: true) {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size).foregroundStyle(color)
        } else {
            Image(systemName: "play.fill").font(.system(size: size * 0.85, weight: .semibold)).foregroundStyle(color)
        }
    }
}

/// A distribution's mark, at the size a node card gives its glyph. Monochrome
/// throughout: it takes the colour of whatever chrome it sits in, so a wall of
/// hosts stays one surface instead of twenty logos competing for the eye.
///
/// Four sources, in order: bundled art under `Resources` named `<distro>-mark`
/// (drop in `ubuntu-mark.png` to override), the real logo `DistroArt` fetches
/// and caches, a drawn mark for the logos that survive being a silhouette at
/// 15pt, and the host glyph for the rest. The drawn marks are what shows before
/// the first fetch lands and on a machine that never reaches the network.
struct DistroMark: View {
    let distro: Distro
    var size: CGFloat = 15

    @ObservedObject private var art = DistroArt.shared

    var body: some View {
        content.frame(width: size, height: size)
    }

    @ViewBuilder
    private var content: some View {
        if let img = MarkImage.load("\(distro.rawValue)-mark", template: true) {
            Image(nsImage: img)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else if let img = art.mark(for: distro) {
            Image(nsImage: img)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            switch distro {
            case .ubuntu:  ubuntu
            case .arch:    ArchMark()
            case .alpine:  AlpineMark()
            case .fedora:  FedoraMark().fill(style: FillStyle(eoFill: true))
            case .debian:  DebianMark().stroke(style: StrokeStyle(lineWidth: size * 0.155,
                                                                  lineCap: .round))
            case .nixos:   NixMark()
            case .macos:   symbol("apple.logo")
            default:       symbol("externaldrive.connected.to.line.below.fill")
            }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.86, weight: .medium))
            .frame(width: size, height: size)
    }

    /// The circle of friends: a ring with three heads on it.
    private var ubuntu: some View {
        ZStack {
            Circle()
                .strokeBorder(lineWidth: size * 0.11)
                .frame(width: size * 0.68, height: size * 0.68)
            ForEach([-90.0, 30.0, 150.0], id: \.self) { deg in
                let a = deg * .pi / 180
                Circle()
                    .frame(width: size * 0.29, height: size * 0.29)
                    .offset(x: cos(a) * size * 0.34, y: sin(a) * size * 0.34)
            }
        }
    }
}

/// Unit-square point inside a shape's rect, so a mark's geometry reads as the
/// proportions of the logo rather than arithmetic on a frame.
private func unit(_ r: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
}

/// Arch's hollow peak. The inner triangle winds the other way, so the default
/// non-zero fill leaves it as a hole.
private struct ArchMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: unit(r, 0.50, 0.02))
        p.addLine(to: unit(r, 0.99, 0.98))
        p.addLine(to: unit(r, 0.01, 0.98))
        p.closeSubpath()
        p.move(to: unit(r, 0.50, 0.42))
        p.addLine(to: unit(r, 0.25, 0.90))
        p.addLine(to: unit(r, 0.75, 0.90))
        p.closeSubpath()
        return p
    }
}

/// Alpine's range: two peaks traced as one outline, so nothing overlaps.
private struct AlpineMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: unit(r, 0.02, 0.92))
        p.addLine(to: unit(r, 0.34, 0.10))
        p.addLine(to: unit(r, 0.53, 0.58))
        p.addLine(to: unit(r, 0.68, 0.34))
        p.addLine(to: unit(r, 0.98, 0.92))
        p.closeSubpath()
        return p
    }
}

/// Fedora's disc with the "f" cut out of it. Filled even-odd, so the letter
/// falls out as a hole whichever way its outline happens to wind.
private struct FedoraMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height))
        // The letter: stem up the right, hook over the top, crossbar to the left.
        p.move(to: unit(r, 0.62, 0.88))
        p.addLine(to: unit(r, 0.46, 0.88))
        p.addLine(to: unit(r, 0.46, 0.62))
        p.addLine(to: unit(r, 0.30, 0.62))
        p.addLine(to: unit(r, 0.30, 0.48))
        p.addLine(to: unit(r, 0.46, 0.48))
        p.addLine(to: unit(r, 0.46, 0.36))
        p.addCurve(to: unit(r, 0.74, 0.16),
                   control1: unit(r, 0.46, 0.20), control2: unit(r, 0.60, 0.12))
        p.addLine(to: unit(r, 0.74, 0.30))
        p.addCurve(to: unit(r, 0.62, 0.40),
                   control1: unit(r, 0.66, 0.30), control2: unit(r, 0.62, 0.33))
        p.closeSubpath()
        return p
    }
}

/// Debian's swirl, drawn open: radius tightens as the arc comes round, stroked
/// rather than filled so the curl keeps an even weight.
private struct DebianMark: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let steps = 48
        let sweep = 1.85 * CGFloat.pi
        var p = Path()
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let a = -0.45 * CGFloat.pi + t * sweep
            let rad = (0.40 - 0.26 * t) * min(r.width, r.height)
            let pt = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// The Nix snowflake as six arms off a clear centre — separated so they don't
/// fill into a blob at this size.
private struct NixMark: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let s = min(r.width, r.height)
        var p = Path()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            let inner = CGPoint(x: c.x + 0.17 * s * cos(a), y: c.y + 0.17 * s * sin(a))
            let outer = CGPoint(x: c.x + 0.48 * s * cos(a), y: c.y + 0.48 * s * sin(a))
            let n = CGPoint(x: -sin(a) * 0.075 * s, y: cos(a) * 0.075 * s)
            p.move(to: CGPoint(x: inner.x + n.x, y: inner.y + n.y))
            p.addLine(to: CGPoint(x: outer.x + n.x, y: outer.y + n.y))
            p.addLine(to: CGPoint(x: outer.x - n.x, y: outer.y - n.y))
            p.addLine(to: CGPoint(x: inner.x - n.x, y: inner.y - n.y))
            p.closeSubpath()
        }
        return p
    }
}

/// The Orbit brand mark — the bundled template glyph, tinted.
struct OrbitMark: View {
    var color: Color = Theme.textSecondary
    var size: CGFloat = 16
    var body: some View {
        if let img = MarkImage.load("orbit-mark", template: true) {
            Image(nsImage: img)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size).foregroundStyle(color)
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: size * 0.85, weight: .semibold)).foregroundStyle(color)
        }
    }
}
