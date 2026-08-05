import AppKit
import Combine
import SwiftUI

/// Everything the `Canvas` draws — edges, wires, notes, glows — plus the
/// node cards and chips positioned over it, and the camera that frames them.
extension OrbitOverlay {

    func screen(_ id: String, center: CGPoint) -> CGPoint {
        let w = sim.position(id)
        return CGPoint(x: center.x + w.x * z + pan.width, y: center.y + w.y * z + pan.height)
    }

    func draw(_ ctx: inout GraphicsContext, graph: Graph,
                      now: TimeInterval, center: CGPoint) {
        let hood = hoveredID.map { neighborhood(of: $0, in: graph) }
        func p(_ id: String) -> CGPoint { screen(id, center: center) }

        // Group halos + label pills, behind everything.
        for g in graph.nodes where isGroup(g) {
            let pts = graph.edges.filter { $0.from == g.id }.map { p($0.to) } + [p(g.id)]
            guard pts.count > 1 else { continue }
            let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
            let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
            let cen = CGPoint(x: cx, y: cy)
            let rad = (pts.map { hypot($0.x - cx, $0.y - cy) }.max() ?? 40) + 34 * z
            let col = groupColor(g.id)
            var a = 1.0
            if let h = hood, !hoodTouchesGroup(g, hood: h, graph: graph) { a = 0.35 }
            ctx.fill(Path(ellipseIn: CGRect(x: cx - rad, y: cy - rad, width: 2 * rad, height: 2 * rad)),
                     with: .radialGradient(Gradient(colors: [col.opacity(0.12 * a), col.opacity(0.02 * a), .clear]),
                                           center: cen, startRadius: rad * 0.15, endRadius: rad))
            // The label is drawn in `groupChips`, above the node cards — on the
            // canvas it sat under them and a member card would land on top of
            // its own group's name.
            _ = col
        }

        // Edges — curved, dimmed outside the hovered neighborhood.
        for e in graph.edges {
            let a = p(e.from), b = p(e.to)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1)
            let ctrl = CGPoint(x: mid.x - dy / len * 13 * z, y: mid.y + dx / len * 13 * z)
            var path = Path(); path.move(to: a); path.addQuadCurve(to: b, control: ctrl)
            let inHood = hood?.contains(e.from) == true && hood?.contains(e.to) == true
            let dim: Double = hood == nil ? 1 : (inHood ? 1 : 0.1)
            if e.flowing {
                ctx.stroke(path, with: .color(Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.85 * dim)),
                           style: .init(lineWidth: 1.6 * z, lineCap: .round,
                                        dash: [6 * z, 6 * z], dashPhase: CGFloat(now * -36)))
            } else {
                ctx.stroke(path, with: .color(ink.opacity(0.16 * dim)),
                           style: .init(lineWidth: max(0.6, 0.9 * z), lineCap: .round))
            }
        }

        // Links you drew on a board. They read as connections, not as controls:
        // a permanent delete handle on every one turned an arrangement into a
        // row of buttons. The handle appears on the one you're pointing at.
        for link in spaces.current?.links ?? [] {
            let a = p(link.from), b = p(link.to)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1)
            let ctrl = CGPoint(x: mid.x - dy / len * 13 * z, y: mid.y + dx / len * 13 * z)
            var path = Path(); path.move(to: a); path.addQuadCurve(to: b, control: ctrl)
            let live = hoveredLinkID == link.id
            ctx.stroke(path, with: .color(Theme.accent.opacity(live ? 0.75 : 0.4)),
                       style: .init(lineWidth: max(0.9, (live ? 1.8 : 1.3) * z), lineCap: .round))
            guard live else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: mid.x - 7, y: mid.y - 7, width: 14, height: 14)),
                     with: .color(Theme.accent.opacity(0.95)))
            ctx.draw(Text("\(Image(systemName: "xmark"))").font(.system(size: 8, weight: .bold))
                .foregroundColor(prefs.lightGlass ? .white : .black), at: mid)
        }

        // Tethers from a docked terminal up to the node it belongs to. Drawn
        // here, under the cards, rather than in the dock's own layer — a line
        // crossing over a card reads as a scratch on it.
        for (rank, pane) in previewPanes.enumerated() {
            let slot = previewSlot(rank, of: previewPanes.count)
            let anchor = p("pane:\(pane.id.uuidString)")
            var path = Path()
            path.move(to: anchor)
            path.addLine(to: CGPoint(x: slot.midX, y: slot.minY))
            ctx.stroke(path, with: .color(Theme.accent.opacity(0.4)),
                       style: .init(lineWidth: 1.5, dash: [5, 4]))
        }

        // Action-connections behind the nodes: each planned/running action is a
        // wire from the Mac to its targets, carrying its state.
        drawActionWires(&ctx, graph: graph, now: now, center: center)

        // Nodes themselves are real glass (`.ultraThinMaterial`), rendered over
        // the Canvas in `nodeCards` — a Canvas can't blur, and a card carrying
        // its own label is what makes a dense graph readable. Only the anchor
        // glow stays here, under the wires, to seat each card on the map.
        for n in graph.nodes.filter({ !isGroup($0) && !isNote($0) }).sorted(by: { layer($0) > layer($1) }) {
            drawNodeGlow(&ctx, n, at: p(n.id), now: now, hood: hood)
        }
        for n in graph.nodes where isNote(n) {
            drawNote(&ctx, n, at: p(n.id))
        }

        // Dependency arrows between action chips. The chips themselves are real
        // glass (SwiftUI `.ultraThinMaterial`), rendered over the Canvas in
        // `actionChips` — a Canvas can't blur.
        drawDependencyArrows(&ctx, graph: graph, now: now, center: center)
    }

    /// A curved, arrow-headed connector from a task to the task that depends on
    /// it ("run B after A") — drawn between their mid-wire chips so the ordering
    /// is visible on the map, not just in the caption.
    func drawDependencyArrows(_ ctx: inout GraphicsContext, graph: Graph,
                                      now: TimeInterval, center: CGPoint) {
        let violet = Color(red: 0.62, green: 0.52, blue: 0.96)
        for a in scheduler.actions {
            guard let depID = a.dependsOn, let dep = scheduler.action(depID),
                  liveOnCanvas(a, now: now) || liveOnCanvas(dep, now: now),
                  let from = actionPillCenter(dep, graph: graph, center: center),
                  let to = actionPillCenter(a, graph: graph, center: center) else { continue }
            // A pending link (dep not yet done) flows; a satisfied one is static.
            let flowing = a.status == .pending
            drawDepArrow(&ctx, from: from, to: to, color: violet, now: now, flowing: flowing)
        }
    }

    func drawDepArrow(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint,
                              color: Color, now: TimeInterval, flowing: Bool) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        guard len > 40 else { return }
        let ux = dx / len, uy = dy / len
        let inset: CGFloat = 26          // clear the chips at both ends
        let start = CGPoint(x: a.x + ux * inset, y: a.y + uy * inset)
        let end = CGPoint(x: b.x - ux * inset, y: b.y - uy * inset)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let ctrl = CGPoint(x: mid.x - dy / len * 16 * z, y: mid.y + dx / len * 16 * z)
        var path = Path(); path.move(to: start); path.addQuadCurve(to: end, control: ctrl)
        ctx.stroke(path, with: .color(color.opacity(0.75)),
                   style: .init(lineWidth: 1.5 * z, lineCap: .round,
                                dash: [2 * z, 4 * z], dashPhase: flowing ? CGFloat(now * -26) : 0))
        // Arrowhead pointing into the dependent task, along the curve's tangent.
        let adx = end.x - ctrl.x, ady = end.y - ctrl.y
        let al = max(hypot(adx, ady), 1)
        let ex = adx / al, ey = ady / al
        let h: CGFloat = 6 * z, w: CGFloat = 3.6 * z
        let left = CGPoint(x: end.x - ex * h - ey * w, y: end.y - ey * h + ex * w)
        let right = CGPoint(x: end.x - ex * h + ey * w, y: end.y - ey * h - ex * w)
        var head = Path()
        head.move(to: left); head.addLine(to: end); head.addLine(to: right)
        ctx.stroke(head, with: .color(color), style: .init(lineWidth: 1.5 * z, lineCap: .round, lineJoin: .round))
    }

    /// True while an action's connection should still be shown — everything not
    /// yet finished, finished ones for a short afterglow, and any action the
    /// cursor is over (in the timeline or on its wire), so hovering a finished
    /// task re-draws its connection on the map.
    func liveOnCanvas(_ a: OrbitScheduler.Action, now: TimeInterval) -> Bool {
        if hoverFocus.id == a.id || pinnedActionID == a.id { return true }
        if !a.isTerminal { return true }
        guard let f = a.finishedAt else { return false }
        return Date().timeIntervalSince(f) < 12
    }

    func hostsOnCanvas(_ a: OrbitScheduler.Action, graph: Graph) -> [String] {
        a.targets.filter { t in graph.nodes.contains { $0.id == "host:\(t)" } }
    }

    /// The curved Mac→host wire, matching the edge curvature so action wires and
    /// topology edges read as the same family.
    func wirePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let ctrl = CGPoint(x: mid.x - dy / len * 16 * z, y: mid.y + dx / len * 16 * z)
        var path = Path(); path.move(to: a); path.addQuadCurve(to: b, control: ctrl)
        return path
    }

    func wirePoint(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let c = CGPoint(x: mid.x - dy / len * 16 * z, y: mid.y + dx / len * 16 * z)
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    func drawActionWires(_ ctx: inout GraphicsContext, graph: Graph,
                                 now: TimeInterval, center: CGPoint) {
        let mac = screen("mac", center: center)
        for a in scheduler.actions where liveOnCanvas(a, now: now) {
            let col = actionColor(a.status)
            for t in hostsOnCanvas(a, graph: graph) {
                let b = screen("host:\(t)", center: center)
                let path = wirePath(mac, b)
                switch a.status {
                case .pending:
                    ctx.stroke(path, with: .color(col.opacity(0.55)),
                               style: .init(lineWidth: 1.4 * z, lineCap: .round, dash: [3 * z, 5 * z]))
                case .running:
                    ctx.stroke(path, with: .color(col.opacity(0.9)),
                               style: .init(lineWidth: 2 * z, lineCap: .round,
                                            dash: [7 * z, 7 * z], dashPhase: CGFloat(now * -46)))
                    let tt = CGFloat(now.truncatingRemainder(dividingBy: 1.3) / 1.3)
                    let pt = wirePoint(mac, b, tt)
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3.2 * z, y: pt.y - 3.2 * z,
                                                    width: 6.4 * z, height: 6.4 * z)),
                             with: .color(col))
                case .done, .failed:
                    ctx.stroke(path, with: .color(col.opacity(0.45)),
                               style: .init(lineWidth: 1.4 * z, lineCap: .round))
                }
            }
        }
    }

    func actionShown(_ a: OrbitScheduler.Action) -> Bool {
        !a.isTerminal
            || (a.finishedAt.map { Date().timeIntervalSince($0) < 12 } ?? false)
            || hoverFocus.id == a.id || pinnedActionID == a.id
    }

    /// Screen midpoint of an action's wire bundle — where its chip sits and its
    /// hover target lives. Shared by drawing and hit-testing so they never drift.
    /// Actions sharing the same wire (same targets) fan out along its
    /// perpendicular so their chips + dependency arrows don't stack on one spot.
    func actionPillCenter(_ a: OrbitScheduler.Action, graph: Graph, center: CGPoint) -> CGPoint? {
        let pts = hostsOnCanvas(a, graph: graph).map { screen("host:\($0)", center: center) }
        guard !pts.isEmpty else { return nil }
        let mac = screen("mac", center: center)
        let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
        let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        var p = CGPoint(x: (mac.x + cx) / 2, y: (mac.y + cy) / 2)
        let key = a.targets.sorted().joined(separator: ",")
        let siblings = scheduler.actions.filter {
            actionShown($0) && $0.targets.sorted().joined(separator: ",") == key
        }
        if siblings.count > 1, let idx = siblings.firstIndex(where: { $0.id == a.id }) {
            let dx = cx - mac.x, dy = cy - mac.y
            let len = max(hypot(dx, dy), 1)
            let off = (CGFloat(idx) - CGFloat(siblings.count - 1) / 2) * 30
            p.x += -dy / len * off; p.y += dx / len * off
        }
        return p
    }

    /// The node layer: one glass card per node, positioned at its point on the
    /// map. Click-through — the Canvas underneath keeps owning hit-testing, so
    /// drag, tap and hover behave exactly as they did when nodes were drawn.
    func nodeCards(graph: Graph, center: CGPoint, now: TimeInterval) -> some View {
        let hood = hoveredID.map { neighborhood(of: $0, in: graph) }
        let ordinals = kindOrdinals(graph)
        return ForEach(graph.nodes.filter { !isGroup($0) && !isNote($0) }, id: \.id) { n in
            let (cr, cg, cb) = rgb(n)
            // A card only gets the clock if it actually animates. SwiftUI diffs
            // these by value, so a still card whose inputs never change is not
            // re-evaluated at all — without this every card in the graph rebuilt
            // its material and glow on every frame of the render loop.
            // Only the pulse needs the canvas clock now — the travelling light
            // carries its own — so a still card stays out of the render pass.
            let animated = n.status == .working || n.status == .attention
            let tag = kindTag(n, ordinals: ordinals)
            NodeCard(label: n.label,
                     subtitle: cardSubtitle(n),
                     contentWidth: contentWidth(n, tag: tag),
                     kindTag: tag,
                     glyph: glyph(n),
                     distro: hostDistro(n),
                     tint: Color(red: cr, green: cg, blue: cb),
                     status: n.status,
                     now: animated ? now : 0,
                     zoom: z,
                     hovered: hoveredID == n.id,
                     // Whatever the bar is aimed at is selected, whatever its
                     // kind — the glow and the tick are how you know which card
                     // the verbs at the bottom belong to, and a session needed
                     // that as much as a host.
                     selected: isFleetSelected(n) || barNode?.id == n.id
                            || pendingLinkFrom == n.id,
                     dimmed: hood.map { !$0.contains(n.id) } ?? false,
                     faded: isFadedHost(n),
                     light: prefs.lightGlass,
                     phase: Double(abs(n.id.hashValue) % 100))
                .position(screen(n.id, center: center))
        }
        .allowsHitTesting(false)
    }


    /// Frame the whole graph on entry. Nodes sit far apart by design — a card
    /// needs the room a gem didn't — so at 1:1 a large fleet would open partly
    /// off-screen. Only ever zooms *out* to fit: opening pre-magnified would
    /// hide the very thing this is for.
    func scheduleFit(_ graph: Graph) {
        guard !didFit else { return }
        didFit = true
        // The sim seeds on its first step, so measure a beat later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { fitToContent(graph) }
    }

    func fitToContent(_ graph: Graph) {
        let pts = graph.nodes.filter { !isGroup($0) }.map { sim.position($0.id) }
        guard pts.count > 1, viewport.width > 100, viewport.height > 100 else { return }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        // Pad by roughly a card, so edge nodes aren't clipped at their labels.
        let w = (maxX - minX) + 260, h = (maxY - minY) + 140
        guard w > 0, h > 0 else { return }
        let fit = min(viewport.width / w, (viewport.height - 150) / h)
        withAnimation(Theme.Spring.soft) {
            zoom = min(max(fit, 0.45), 1.0)
            pan = CGSize(width: -((minX + maxX) / 2) * zoom,
                         height: -((minY + maxY) / 2) * zoom)
        }
    }

    func resetView() {
        sim.releaseAll()
        didFit = false
        pan = .zero
        zoom = 1
        // Let the released layout settle, then frame it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            fitToContent(liveGraph())
        }
    }

    /// The card's approximate on-screen size. Interaction still happens on the
    /// Canvas beneath the cards, so it has to know how big the thing the user
    /// is actually aiming at is — an orb-sized target under a 190pt card reads
    /// as a dead click along its edges.
    /// Width of a card's text column: what its longest line needs, capped so a
    /// long name wraps instead of stretching the card across the map. The kind
    /// tag only sets a modest floor — it must not decide the width outright.
    func contentWidth(_ n: MapNode, tag: String?) -> CGFloat {
        let titleW = TabPill.textWidth(n.label, size: 12)
        let subW = cardSubtitle(n).map { TabPill.textWidth($0, size: 9.5) } ?? 0
        // Tracking adds a little beyond the glyph run. The tag is never
        // compressed (it is `fixedSize`), so this only has to stop the card
        // being narrower than its own identity line.
        let tagW = tag.map { OrbitFont.width($0, size: 7.5) + 6 } ?? 0
        return min(150, max(max(titleW, subW), tagW))
    }

    /// The card's rect, which is also its hit target — the cards are
    /// click-through and the `Canvas` tests this. It has to track `NodeCard`'s
    /// own metrics; a stale number here means clicking a card does nothing near
    /// its edges.
    func cardSize(_ n: MapNode) -> CGSize {
        let sub = cardSubtitle(n)
        let titleW = TabPill.textWidth(n.label, size: 12)
        let tag = kindOrdinalTag(n)
        let textW = contentWidth(n, tag: tag)
        let w = 22 + 24 + 10 + textW         // padding + glyph well + gap + text
        // Vertical padding + the title line, plus the tag, a wrapped title and
        // any subtitle.
        var h: CGFloat = 31 + (tag == nil ? 0 : 13)
        if titleW > textW { h += 15 }
        if sub?.isEmpty == false { h += 14 }
        let scale = max(min(z, 1.0), 0.55)   // matches NodeCard
        return CGSize(width: w * scale, height: h * scale)
    }

    /// The tag a card would show, without rebuilding the whole ordinal map —
    /// hit-testing only needs to know whether there is one.
    func kindOrdinalTag(_ n: MapNode) -> String? {
        if case .mac = n.kind { return nil }
        return kindName(n) + " 1"
    }

    /// A constellation's name, parked above the *cards* of its members rather
    /// than above their centre points — a card is far taller than the point it
    /// hangs on, so a centre-relative label ends up underneath one of them.
    @ViewBuilder
    func groupChips(graph: Graph, center: CGPoint) -> some View {
        let hood = hoveredID.map { neighborhood(of: $0, in: graph) }
        ForEach(groupPlacements(graph: graph, center: center), id: \.id) { g in
            HStack(spacing: 5) {
                Image(systemName: g.icon).font(.system(size: 9, weight: .semibold))
                Text(g.label).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(g.color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(g.color.opacity(0.45), lineWidth: 1))
            .opacity(hood.map { hoodTouchesGroup(g.node, hood: $0, graph: graph) ? 1 : 0.35 } ?? 1)
            .position(g.at)
            .allowsHitTesting(false)
        }
    }

    struct GroupPlacement: Identifiable {
        let id: String
        let label: String
        let icon: String
        let color: Color
        let at: CGPoint
        let node: MapNode
    }

    func groupPlacements(graph: Graph, center: CGPoint) -> [GroupPlacement] {
        graph.nodes.filter { isGroup($0) }.compactMap { g in
            let members = graph.edges.filter { $0.from == g.id }.map(\.to)
            let boxes = members.compactMap { id -> CGRect? in
                guard let n = graph.nodes.first(where: { $0.id == id }) else { return nil }
                let p = screen(id, center: center)
                let s = cardSize(n)
                return CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2,
                              width: s.width, height: s.height)
            }
            guard boxes.count > 1 else { return nil }
            let top = boxes.map(\.minY).min()!
            let cx = boxes.map(\.midX).reduce(0, +) / CGFloat(boxes.count)
            return GroupPlacement(id: g.id, label: g.label, icon: groupIcon(g),
                                  color: groupColor(g.id),
                                  at: CGPoint(x: cx, y: top - 16), node: g)
        }
    }

    /// Each node's number within its own kind — "HOST 3". Numbered in id order
    /// so a node keeps its mark between rebuilds rather than being renumbered
    /// every time the graph is rebuilt.
    /// A number only earns its place on a card when it tells two of them apart:
    /// same kind, same name. Numbering unique names — HOST 1, HOST 3 — reads as
    /// information and carries none, and the number moves as the graph changes.
    /// Several remote shells, on the other hand, are all called `shell`.
    func kindOrdinals(_ graph: Graph) -> [String: Int] {
        let shown = graph.nodes.filter { !isGroup($0) && !isNote($0) }
        var ambiguous: [String: Int] = [:]
        for n in shown { ambiguous[ordinalKey(n), default: 0] += 1 }
        var counters: [String: Int] = [:]
        var out: [String: Int] = [:]
        for n in shown.sorted(by: { $0.id < $1.id }) {
            let key = ordinalKey(n)
            guard kindName(n) != "MAC", ambiguous[key, default: 0] > 1 else { continue }
            counters[key, default: 0] += 1
            out[n.id] = counters[key]!
        }
        return out
    }

    func ordinalKey(_ n: MapNode) -> String { kindName(n) + "\u{1}" + n.label }

    /// The card's identity line: what it is, and — only when that isn't enough
    /// — which one. The Mac is the exception; there is only ever one.
    func kindTag(_ n: MapNode, ordinals: [String: Int]) -> String? {
        guard kindName(n) != "MAC" else { return nil }
        if let i = ordinals[n.id] { return "\(kindName(n)) \(i)" }
        return kindName(n)
    }

    func kindName(_ n: MapNode) -> String {
        switch n.kind {
        case .mac:        return "MAC"
        case .host:       return "HOST"
        // A pane only earns "AGENT" while something is actually running in it;
        // otherwise it is just a shell you have open.
        case .pane:       return n.status == .neutral ? "SHELL" : "AGENT"
        case .agent:      return "BG"
        case .cluster:    return "CTX"
        case .container:  return "CTR"
        case .vm:         return "VM"
        case .kubeNode:   return "NODE"
        case .pod:        return "POD"
        case .podContainer: return "CTR"
        case .k8s:        return "K8S"
        case .subagent:   return "SUB"
        case .shellCmd:   return "CMD"
        case .note:       return "NOTE"
        case .project:    return "PROJ"
        case .network:    return "NET"
        }
    }

    /// A known-but-unconnected SSH endpoint — present on the map, but not
    /// something you're currently talking to.
    func isFadedHost(_ n: MapNode) -> Bool {
        if case .host(_, let active) = n.kind { return !active }
        return false
    }

    /// The card's second line: what the node *is*, when its label doesn't
    /// already say so. Kept short — the card is an identity, not a report.
    func cardSubtitle(_ n: MapNode) -> String? {
        switch n.kind {
        case .mac:                  return "this Mac"
        case .host(let target, _):
            // The label is the hostname, so two logins to the same machine draw
            // identical cards — the user is the only thing telling them apart.
            let user = target.contains("@") ? String(target.split(separator: "@")[0]) : nil
            var parts: [String] = []
            if let user { parts.append(user) }
            if isExpanded(target), case .loaded(let info)? = probes["host:\(target)"]?.phase {
                let c = info.containers?.count ?? 0
                let v = info.vms?.count ?? 0
                if c > 0 { parts.append("\(c) container\(c == 1 ? "" : "s")") }
                if v > 0 { parts.append("\(v) VM\(v == 1 ? "" : "s")") }
                if c == 0 && v == 0 { parts.append(info.kubelet ? "kubelet" : "nothing running") }
            } else if let sub = n.subtitle {
                parts.append(sub)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .pane:                 return n.subtitle ?? n.pane?.remoteHost
        case .agent:                return n.subtitle ?? "background"
        case .cluster(let ctx, _):  return ctx
        case .container:            return n.subtitle ?? "container"
        case .vm:                   return n.subtitle ?? "vm"
        case .kubeNode:             return n.subtitle ?? "node"
        case .pod:                  return n.subtitle ?? "pod"
        case .podContainer:         return n.subtitle ?? "container"
        case .k8s(let nodes):       return nodes.map { "\($0) nodes" } ?? "kubelet"
        case .subagent:             return "sub-agent"
        case .shellCmd:             return "command"
        case .note, .project, .network: return nil
        }
    }

    /// What a host runs, once anything has probed it. Cached per target, so the
    /// mark survives a relaunch and doesn't wait on a fresh round trip.
    func hostDistro(_ n: MapNode) -> Distro? {
        guard case .host(let target, _) = n.kind else { return nil }
        return HostDistroStore.distro(for: target)
    }

    /// One glyph per kind, so a card says what it is before you read it.
    func glyph(_ n: MapNode) -> String {
        switch n.kind {
        case .mac:        return "laptopcomputer"
        case .host:       return "externaldrive.connected.to.line.below.fill"
        // A plain shell shouldn't wear the agent mark — only a session with
        // something running in it has earned that.
        case .pane:       return n.status == .neutral ? "terminal" : "sparkle"
        case .agent:      return "moon.zzz.fill"
        case .kubeNode:   return "square.stack.3d.up.fill"
        case .pod:        return "circle.grid.2x2.fill"
        case .podContainer: return "shippingbox.fill"
        case .cluster:    return "cube.transparent"
        case .container:  return "shippingbox.fill"
        case .vm:         return "macwindow.on.rectangle"
        case .k8s:        return "cube.fill"
        case .subagent:   return "arrow.triangle.branch"
        case .shellCmd:   return "chevron.left.forwardslash.chevron.right"
        case .note:       return "note.text"
        case .project:    return "folder.fill"
        case .network:    return "network"
        }
    }

    /// Real frosted-glass chips riding each wire — one per live action at its
    /// mid-wire point. SwiftUI (not Canvas) so they can use `.ultraThinMaterial`.
    /// Each chip is a drag handle: pull it onto another task to chain them, or
    /// onto a host to add that target; a plain click opens its output.
    func actionChips(graph: Graph, center: CGPoint, now: TimeInterval) -> some View {
        ForEach(scheduler.actions.filter { liveOnCanvas($0, now: now) }) { a in
            if let c = actionPillCenter(a, graph: graph, center: center) {
                ActionChip(label: a.label, caption: actionCaption(a),
                           tint: a.held ? Color(red: 0.62, green: 0.52, blue: 0.96) : actionColor(a.status),
                           hovered: hoverFocus.id == a.id || chainFrom == a.id
                                    || pinnedActionID == a.id,
                           light: prefs.lightGlass)
                    // Gesture on the chip itself (before .position, which would
                    // otherwise stretch the hit area to the whole canvas).
                    .gesture(chipDrag(a, graph: graph, center: center))
                    .position(c)
                    .transition(.opacity)
            }
        }
    }

    /// Drag a task chip to author a flow: onto another task chains them (⌥ =
    /// continue on failure), onto a host adds it as a target. A tap opens output.
    func chipDrag(_ a: OrbitScheduler.Action, graph: Graph, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(orbitCanvasSpace))
            .onChanged { g in
                if hypot(g.translation.width, g.translation.height) > 3 {
                    chainFrom = a.id; chainCursor = g.location; sim.wake()
                }
            }
            .onEnded { g in
                let moved = hypot(g.translation.width, g.translation.height) > 3
                if moved, let dst = actionAt(g.location, graph: graph, center: center),
                   dst != a.id, let da = scheduler.action(dst), !da.isTerminal {
                    scheduler.chain(dst, after: a.id,
                                    onFailureToo: NSEvent.modifierFlags.contains(.option))
                } else if moved, let nid = node(at: g.location, in: graph, center: center),
                          nid.hasPrefix("host:") {
                    scheduler.addTarget(a.id, host: String(nid.dropFirst("host:".count)))
                } else if !moved {
                    withAnimation(Theme.Spring.snappy) { modal = .output(a.id) }
                }
                chainFrom = nil; chainCursor = nil; sim.wake()
            }
    }

    /// The dashed wire that follows the cursor while dragging one task chip
    /// toward another to chain them.
    @ViewBuilder
    func chainRubberBand(graph: Graph, center: CGPoint) -> some View {
        if let src = chainFrom, let a = scheduler.action(src),
           let from = actionPillCenter(a, graph: graph, center: center), let to = chainCursor {
            let violet = Color(red: 0.62, green: 0.52, blue: 0.96)
            Path { p in p.move(to: from); p.addLine(to: to) }
                .stroke(violet, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                .allowsHitTesting(false)
            Circle().fill(violet).frame(width: 7, height: 7)
                .position(to).allowsHitTesting(false)
        }
    }

    func drawNote(_ ctx: inout GraphicsContext, _ n: MapNode, at c: CGPoint) {
        guard case .note(let text) = n.kind else { return }
        let editing = editingNote == n.id
        let font = Font.system(size: 11 * min(max(z, 0.9), 1.4), weight: .medium, design: .rounded)
        let resolved = ctx.resolve(Text(text.isEmpty ? "Note" : text).font(font).foregroundColor(Theme.textPrimary))
        let ts = resolved.measure(in: CGSize(width: 170, height: 260))
        let w = min(max(ts.width + 20, 54), 200)
        let h = ts.height + 16
        let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let card = Path(roundedRect: rect, cornerRadius: 9)
        let note = Color(red: 0.98, green: 0.80, blue: 0.34)
        // Fully opaque bed: a note is a piece of paper on the board, and a link
        // running visibly through one reads as a mistake. Anything short of
        // solid still shows the wire underneath.
        ctx.fill(card, with: .color(prefs.lightGlass
                                    ? Color(red: 0.97, green: 0.97, blue: 0.98)
                                    : Color(red: 0.09, green: 0.10, blue: 0.12)))
        ctx.fill(card, with: .color(note.opacity(prefs.lightGlass ? 0.32 : 0.16)))
        ctx.stroke(card, with: .color(note.opacity(editing ? 0.9 : 0.5)), lineWidth: editing ? 2 : 1)
        if !editing { ctx.draw(resolved, at: c) }
    }

    /// The seat a node card sits on: a soft tinted glow plus a small core, so
    /// the wires visibly land somewhere and a working node breathes even before
    /// you read its card. The card itself is a SwiftUI view above the Canvas.
    func drawNodeGlow(_ ctx: inout GraphicsContext, _ n: MapNode, at c: CGPoint,
                              now: TimeInterval, hood: Set<String>?) {
        let (cr, cg, cb) = rgb(n)
        var a = 1 - 0.06 * Double(layer(n))
        if let h = hood, !h.contains(n.id) { a *= 0.2 }
        if case .host(_, let active) = n.kind, !active { a *= 0.55 }
        let hovered = hoveredID == n.id
        let r = radius(n) * z

        // A selected node keeps its seat lit whether or not the cursor is on it:
        // selection is a state you chose and left, so it can't be something you
        // only see while pointing at it.
        let picked = isFleetSelected(n) || barNode?.id == n.id
        let base = picked ? Theme.accent : Color(red: cr, green: cg, blue: cb)
        var glowA = (picked ? 0.26 : (n.status != .neutral ? 0.18 : 0.08)) * a
        var glowR = r * (picked ? 2.4 : (hovered ? 2.2 : 1.7))
        if n.status == .working {
            let f = 0.5 + 0.5 * sin(now * 2.6 + Double(abs(n.id.hashValue) % 100))
            glowA *= 0.7 + 0.5 * f; glowR *= 1 + 0.1 * f
        }
        func rect(_ p: CGPoint, _ rad: CGFloat) -> CGRect {
            CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)
        }
        // Only the bloom: a core dot sits under the card's centre and peeks past
        // its edges, reading as a smudge across the label.
        ctx.fill(Path(ellipseIn: rect(c, glowR)),
                 with: .radialGradient(Gradient(colors: [base.opacity(glowA), .clear]),
                                       center: c, startRadius: 0, endRadius: glowR))
    }

    /// A designed label pill for a group halo (project folder / network).
    func drawGroupPill(_ ctx: inout GraphicsContext, label: String, icon: String,
                               color: Color, at top: CGPoint, alpha: Double) {
        let font = Font.system(size: 11 * min(max(z, 0.9), 1.2), weight: .semibold, design: .rounded)
        let text = ctx.resolve(Text(label).font(font).foregroundColor(color.opacity(0.95 * alpha)))
        let ts = text.measure(in: CGSize(width: 400, height: 40))
        let iconW: CGFloat = 12, gap: CGFloat = 5, padH: CGFloat = 9
        let w = ts.width + iconW + gap + padH * 2
        let h = ts.height + 8
        let rect = CGRect(x: top.x - w / 2, y: top.y - h, width: w, height: h)
        let pill = Path(roundedRect: rect, cornerRadius: h / 2)
        ctx.fill(pill, with: .color((prefs.lightGlass ? Color.white : Color.black).opacity(0.4 * alpha)))
        ctx.fill(pill, with: .color(color.opacity(0.16 * alpha)))
        ctx.stroke(pill, with: .color(color.opacity(0.55 * alpha)), lineWidth: 1)
        ctx.draw(Text("\(Image(systemName: icon))").font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(color.opacity(0.95 * alpha)),
            at: CGPoint(x: rect.minX + padH + iconW / 2, y: rect.midY))
        ctx.draw(text, at: CGPoint(x: rect.minX + padH + iconW + gap, y: rect.midY), anchor: .leading)
    }

    // MARK: - Hover preview

    @ViewBuilder
    func hoverCard(graph: Graph, center: CGPoint, canvas: CGSize) -> some View {
        if let id = hoveredID, let n = graph.nodes.first(where: { $0.id == id }), !isGroup(n), !isNote(n) {
            let sp = screen(id, center: center)
            let w: CGFloat = 230
            let x = min(max(sp.x, w / 2 + 12), canvas.width - w / 2 - 12)
            let y = max(sp.y - radius(n) * z - 60, 78)
            PreviewCard(node: n, probe: hostProbe(for: n), paneCount: paneCount(for: n, in: graph))
                .frame(width: w).position(x: x, y: y).allowsHitTesting(false).transition(.opacity)
        }
    }

    @ViewBuilder
    func actionHoverCard(graph: Graph, center: CGPoint, canvas: CGSize) -> some View {
        // A hovered wire, or a timeline block clicked to pin, keeps its detail up.
        if let id = hoverFocus.wireID ?? pinnedActionID, let a = scheduler.action(id),
           let c = actionPillCenter(a, graph: graph, center: center) {
            let w: CGFloat = 244
            let x = min(max(c.x, w / 2 + 12), canvas.width - w / 2 - 12)
            let y = max(c.y - 78, 84)
            ActionDetailCard(action: a, dep: a.dependsOn.flatMap { scheduler.action($0) },
                             tint: actionColor(a.status), schedule: scheduleLine(a))
                .frame(width: w).position(x: x, y: y).allowsHitTesting(false).transition(.opacity)
        }
    }

    /// One-line human schedule for the detail card.
    func scheduleLine(_ a: OrbitScheduler.Action) -> String {
        if a.held {
            if let dep = a.dependsOn, let d = scheduler.action(dep) {
                return a.afterAnyOutcome ? "Staged · after \(d.label) (even if it fails)"
                                         : "Staged · after \(d.label)"
            }
            return "Staged · flow start"
        }
        if let t = a.agentTrigger, a.status == .pending {
            return t.phase == "attention" ? "When \(t.label) needs you" : "When \(t.label) finishes"
        }
        if let dep = a.dependsOn, let d = scheduler.action(dep) { return "Runs after \(d.label)" }
        if let t = a.runAt, a.status == .pending { return "Runs at \(hhmm(t))" }
        switch a.status {
        case .pending: return "Runs now"
        case .running: return "Running now"
        case .done:    return "Finished"
        case .failed:  return "Failed"
        }
    }

    func hostProbe(for n: MapNode) -> HostProbeModel? {
        if case .host = n.kind { return probes[n.id] }
        return nil
    }
    func paneCount(for n: MapNode, in graph: Graph) -> Int {
        graph.edges.filter { $0.from == n.id && $0.to.hasPrefix("pane:") }.count
    }
}
