import AppKit
import SwiftUI

/// Where you are in the graph, and the way back.
///
/// The canvas pans and zooms without limit, so it is entirely possible to be
/// looking at empty space with the whole fleet somewhere off the edge and no
/// clue which edge. The minimap holds the whole graph in one rectangle, draws
/// the viewport inside it, and takes a click to go anywhere in it.
extension OrbitOverlay {

    /// World-space bounds of everything drawn, padded. Falls back to a small
    /// box around the origin when nothing has been placed yet, so the map never
    /// divides by zero on the first frame.
    func graphBounds(_ graph: Graph) -> CGRect {
        let pts = graph.nodes.filter { !isGroup($0) }.map { sim.position($0.id) }
        guard let first = pts.first else {
            return CGRect(x: -200, y: -200, width: 400, height: 400)
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad: CGFloat = 120
        return CGRect(x: minX - pad, y: minY - pad,
                      width: max(maxX - minX + pad * 2, 200),
                      height: max(maxY - minY + pad * 2, 200))
    }

    /// The slice of world the canvas is currently showing. `screen = center +
    /// world * z + pan`, so the visible world is the inverse of that over the
    /// viewport's own rectangle.
    var visibleWorld: CGRect {
        guard viewport.width > 0, viewport.height > 0, z > 0 else { return .zero }
        let w = viewport.width / z, h = viewport.height / z
        return CGRect(x: -pan.width / z - w / 2, y: -pan.height / z - h / 2,
                      width: w, height: h)
    }

    /// Put `world` in the middle of the canvas.
    func lookAt(_ world: CGPoint) {
        withAnimation(Theme.Spring.soft) {
            pan = CGSize(width: -world.x * z, height: -world.y * z)
        }
        sim.wake()
    }

    var minimapSize: CGSize { CGSize(width: 168, height: 108) }

    @ViewBuilder
    var minimap: some View {
        if showMinimap {
            let graph = liveGraph()
            // The frame has to hold both the graph and where you are looking,
            // or panning off into empty space walks the viewport rectangle
            // straight off the edge of the very thing meant to find it again.
            let bounds = graphBounds(graph).union(visibleWorld.insetBy(dx: -40, dy: -40))
            VStack(alignment: .leading, spacing: 0) {
                Canvas { ctx, size in
                    drawMinimap(&ctx, size: size, graph: graph, bounds: bounds)
                }
                .frame(width: minimapSize.width, height: minimapSize.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            lookAt(minimapToWorld(g.location, bounds: bounds))
                        }
                )
                Divider().opacity(0.25)
                HStack(spacing: 5) {
                    Text("\(Int((z * 100).rounded()))%")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                        .frame(width: 34, alignment: .leading)
                    Spacer(minLength: 0)
                    // Frames everything without disturbing where the nodes are.
                    // The reset beside the zoom buttons releases every pin,
                    // which is a different and much larger thing to ask for.
                    Button { fitToContent(graph) } label: {
                        Image(systemName: "scope").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 22, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Bring the whole graph back into view")
                    Button { withAnimation(Theme.Spring.snappy) { showMinimap = false } } label: {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 20, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide the minimap")
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
            }
            // The footer row carries a Spacer, which without this takes every
            // point the surrounding HStack will give it — stretching the panel
            // across the whole foot of the canvas.
            .frame(width: minimapSize.width)
            .orbitGlass(RoundedRectangle(cornerRadius: 12, style: .continuous),
                        bed: prefs.lightGlass ? 0.82 : 0.72)
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomLeading)))
        } else {
            Button { withAnimation(Theme.Spring.snappy) { showMinimap = true } } label: {
                Image(systemName: "map").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 24)
                    .orbitChip(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show the minimap")
        }
    }

    /// A point on the minimap, in world coordinates.
    func minimapToWorld(_ p: CGPoint, bounds: CGRect) -> CGPoint {
        let s = minimapScale(bounds)
        let ox = (minimapSize.width - bounds.width * s) / 2
        let oy = (minimapSize.height - bounds.height * s) / 2
        return CGPoint(x: bounds.minX + (p.x - ox) / s,
                       y: bounds.minY + (p.y - oy) / s)
    }

    /// Uniform, so the graph keeps its shape rather than being stretched to fit
    /// a panel whose proportions have nothing to do with it.
    func minimapScale(_ bounds: CGRect) -> CGFloat {
        min(minimapSize.width / max(bounds.width, 1),
            minimapSize.height / max(bounds.height, 1))
    }

    func drawMinimap(_ ctx: inout GraphicsContext, size: CGSize,
                     graph: Graph, bounds: CGRect) {
        let s = minimapScale(bounds)
        let ox = (size.width - bounds.width * s) / 2
        let oy = (size.height - bounds.height * s) / 2
        func p(_ w: CGPoint) -> CGPoint {
            CGPoint(x: ox + (w.x - bounds.minX) * s, y: oy + (w.y - bounds.minY) * s)
        }

        // Edges first, faint: the shape of the graph is what makes a cluster of
        // dots readable as a fleet rather than a scatter.
        var wires = Path()
        for e in graph.edges {
            wires.move(to: p(sim.position(e.from)))
            wires.addLine(to: p(sim.position(e.to)))
        }
        ctx.stroke(wires, with: .color(Theme.textSecondary.opacity(0.18)), lineWidth: 0.5)

        for n in graph.nodes where !isGroup(n) {
            let c = p(sim.position(n.id))
            let (r, g, b) = rgb(n)
            let picked = selection.contains(n.id) || barNode?.id == n.id
            // The Mac and anything live are worth finding at this size; the
            // rest is context.
            let radius: CGFloat = {
                if case .mac = n.kind { return 3.4 }
                return n.status == .neutral ? 2 : 2.8
            }()
            let dot = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius,
                                             width: radius * 2, height: radius * 2))
            ctx.fill(dot, with: .color(picked ? Theme.accent
                                              : Color(red: r, green: g, blue: b)
                                                    .opacity(n.status == .neutral ? 0.55 : 0.95)))
        }

        // Where you are looking.
        let v = visibleWorld
        guard v != .zero else { return }
        let rect = CGRect(x: ox + (v.minX - bounds.minX) * s,
                          y: oy + (v.minY - bounds.minY) * s,
                          width: v.width * s, height: v.height * s)
        let box = Path(roundedRect: rect, cornerRadius: 2)
        ctx.fill(box, with: .color(Theme.accent.opacity(0.10)))
        ctx.stroke(box, with: .color(Theme.accent.opacity(0.75)), lineWidth: 1)
    }
}
