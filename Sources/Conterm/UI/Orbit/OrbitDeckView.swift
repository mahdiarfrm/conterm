import AppKit
import Combine
import SwiftUI

/// The always-on bottom timeline deck. The track is centered on *now* — a fixed
/// playhead in the middle, past to the left, upcoming to the right — so the
/// cursor never runs off and both history and what's queued stay in view. Time
/// gridlines mark the passing minutes; actions are lane-packed blocks sized by
/// duration. Hovering a block previews it on the canvas; a click widens the
/// window (30 min ↔ 4 h).
/// A Claude-session activity item placed on the timeline — a shell command the
/// agent ran or a sub-agent it spawned — so you see what it's doing, in order.
struct AgentDeckItem: Identifiable {
    let id: String
    let label: String
    let at: Date
    /// When it finished, when that is known. A running command has no end yet,
    /// and a sub-agent's activity is a point rather than a span.
    var endedAt: Date? = nil
    let isSubagent: Bool
    /// The full text, for the hover report — `label` is shortened to fit a
    /// block and a block is often narrower than the command that made it.
    var detail: String = ""
    var output: String? = nil

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(at) } }
}

struct TimelineDeckView: View {
    let actions: [OrbitScheduler.Action]
    let agentItems: [AgentDeckItem]
    let light: Bool
    @Binding var expanded: Bool
    /// Total visible time range, in seconds. Continuous rather than two fixed
    /// stops: how far apart the gridlines sit is the whole point of the deck,
    /// and the useful span differs between a burst of commands and a plan that
    /// stretches over an afternoon.
    @Binding var span: Double
    @Binding var hovered: UUID?
    let selected: UUID?
    let caption: (OrbitScheduler.Action) -> String
    let tint: (OrbitScheduler.Status) -> Color
    let onCancel: (UUID) -> Void
    let onOpen: (UUID) -> Void
    let onSelect: (UUID) -> Void
    let schedule: (OrbitScheduler.Action) -> String
    let onClearDone: () -> Void
    /// Opening one of the agent's own commands — its full output.
    let onOpenAgent: (String) -> Void

    /// The agent block under the cursor. Its own state rather than the task
    /// hover, so pointing at a command cannot leave a task's card behind.
    @State var hoveredAgent: String?

    struct Laid { let a: OrbitScheduler.Action; let lane: Int }
    let laneH: CGFloat = 20, laneGap: CGFloat = 5, axisH: CGFloat = 14

    /// Half-window in seconds each side of now.
    var half: TimeInterval { span / 2 }

    static let minSpan: Double = 300          // 5 minutes
    static let maxSpan: Double = 12 * 3600    // 12 hours

    /// Slider position ↔ span, on a log scale so the low end (where a burst of
    /// commands lives) gets as much travel as the long tail.
    var spanSlider: Binding<Double> {
        Binding(get: { log(span / Self.minSpan) / log(Self.maxSpan / Self.minSpan) },
                set: { span = Self.minSpan * pow(Self.maxSpan / Self.minSpan, min(max($0, 0), 1)) })
    }

    var spanLabel: String {
        if span < 3600 { return "\(Int((span / 60).rounded()))m" }
        let h = span / 3600
        return h < 10 && h != h.rounded() ? String(format: "%.1fh", h) : "\(Int(h.rounded()))h"
    }

    func start(_ a: OrbitScheduler.Action) -> Date { a.startedAt ?? a.runAt ?? a.createdAt }
    func end(_ a: OrbitScheduler.Action, _ now: Date) -> Date {
        switch a.status {
        case .running:       return now
        case .done, .failed: return a.finishedAt ?? a.startedAt ?? now
        case .pending:       return (a.runAt ?? now).addingTimeInterval(90)
        }
    }

    /// A tick spacing that lands ~5–9 gridlines across the window.
    func gridStep(_ window: TimeInterval) -> TimeInterval {
        for s in [60.0, 120, 300, 600, 900, 1800, 3600, 7200, 14400] where window / s <= 9 { return s }
        return 14400
    }

    var body: some View {
        let now = Date()
        let lo = now.addingTimeInterval(-half), window = half * 2
        // Lane-pack by start so overlapping tasks stack. Reserve a minimum slot
        // per block — instant/near-instant tasks otherwise collapse to a point,
        // so two fired at the same moment would share a lane and overlap.
        let minSlot: TimeInterval = 120
        let slotEnd: (OrbitScheduler.Action) -> Date = {
            max(end($0, now), start($0).addingTimeInterval(minSlot))
        }
        let maxLanes = expanded ? 5 : 3
        // Only tasks whose span intersects the visible window — persisted history
        // from earlier sessions sits far in the past and must not pile at the edge.
        let hi = now.addingTimeInterval(half)
        let sorted = actions
            .filter { end($0, now) >= lo && start($0) <= hi }
            .sorted { start($0) < start($1) }
        var laneEnds: [Date] = []
        var laid: [Laid] = []
        for a in sorted {
            let s = start(a)
            var lane = laneEnds.firstIndex { $0 <= s } ?? -1
            if lane == -1 {
                if laneEnds.count < maxLanes { laneEnds.append(slotEnd(a)); lane = laneEnds.count - 1 }
                else { lane = 0; laneEnds[0] = max(laneEnds[0], slotEnd(a)) }
            } else { laneEnds[lane] = slotEnd(a) }
            laid.append(Laid(a: a, lane: lane))
        }
        let actionLanes = laneEnds.count

        // Agent activity (shell commands, sub-agents) in a band below the tasks.
        // Lane assignment happens in the GeometryReader by pixel extent — a
        // fixed time slot can't prevent overlap because each block's width is
        // its (variable) label, not its 0-length instant.
        let agMaxLanes = expanded ? 4 : 2
        let agSorted = agentItems.filter { $0.at >= lo && $0.at <= hi }.sorted { $0.at < $1.at }

        let step = gridStep(window)
        let firstTick = (lo.timeIntervalSinceReferenceDate / step).rounded(.up) * step
        let ticks = stride(from: firstTick, through: lo.timeIntervalSinceReferenceDate + window, by: step)
            .map { Date(timeIntervalSinceReferenceDate: $0) }
        // Fainter minor lines subdivide each major interval (the passing minutes).
        let minorStep = step / 5
        let firstMinor = (lo.timeIntervalSinceReferenceDate / minorStep).rounded(.up) * minorStep
        let minorTicks = stride(from: firstMinor, through: lo.timeIntervalSinceReferenceDate + window, by: minorStep)
            .map { Date(timeIntervalSinceReferenceDate: $0) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("Timeline").font(OrbitFont.face(12)).tracking(-0.3)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if actions.contains(where: { $0.isTerminal }) {
                    Button(action: onClearDone) {
                        Text("Clear done").font(OrbitFont.face(9))
                            .foregroundStyle(Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    Slider(value: spanSlider, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 86)
                        .help("How much time the deck shows — drag to spread or tighten the gridlines")
                    Text(spanLabel).font(OrbitFont.face(9))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Button { withAnimation(Theme.Spring.snappy) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain).help("Taller or shorter deck")
            }
            .padding(.horizontal, 6)   // clears the corner arc at the top row
            GeometryReader { geo in
                let W = geo.size.width, H = geo.size.height
                // now sits at the middle; map time → x around it.
                let x: (Date) -> CGFloat = { W / 2 + CGFloat($0.timeIntervalSince(now) / window) * W }
                // Agent markers packed into lanes by real pixel
                // footprint. Newest first, so a dense burst keeps its most recent
                // commands; anything that can't fit a lane without overlapping is
                // dropped rather than drawn on top of another block.
                // A block spans the time its command actually took, so a run
                // that held the agent for two minutes reads as two minutes.
                // Below a floor it would be unclickable and unreadable, so
                // short work draws at the floor and the hover card carries the
                // real duration. Anything with no recorded end — still running,
                // or a sub-agent, whose activity is a point — gets the floor.
                let agFloor: CGFloat = 132, agGap: CGFloat = 6
                let agPlaced: [(item: AgentDeckItem, lane: Int, px: CGFloat, w: CGFloat)] = {
                    var laneLeft = [CGFloat](repeating: .greatestFiniteMagnitude, count: agMaxLanes)
                    var out: [(AgentDeckItem, Int, CGFloat, CGFloat)] = []
                    for it in agSorted.reversed() {
                        let px = max(x(it.at), 0)
                        let w = it.endedAt.map { max(x($0) - x(it.at), agFloor) } ?? agFloor
                        // First lane whose current content sits fully to the right.
                        guard let lane = (0..<agMaxLanes).first(where: { px + w + agGap <= laneLeft[$0] })
                        else { continue }   // no lane free here → drop this one
                        laneLeft[lane] = px
                        out.append((it, lane, px, w))
                    }
                    return out
                }()
                let agDropped = agSorted.count - agPlaced.count
                ZStack(alignment: .topLeading) {
                    // Click empty track for a taller or shorter deck.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(Theme.Spring.snappy) { expanded.toggle() } }
                    // Minor (minute) gridlines — faint, between the labelled ones.
                    ForEach(minorTicks, id: \.self) { t in
                        Rectangle().fill((light ? Color.black : Color.white).opacity(0.035))
                            .frame(width: 1, height: H - axisH).offset(x: x(t), y: axisH)
                    }
                    // Time gridlines + little numbers along the top.
                    ForEach(ticks, id: \.self) { t in
                        let gx = x(t)
                        Rectangle().fill((light ? Color.black : Color.white).opacity(0.08))
                            .frame(width: 1, height: H - axisH).offset(x: gx, y: axisH)
                        Text(hm(t)).font(OrbitFont.face(8))
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                            .fixedSize().offset(x: gx + 3, y: 0)
                    }
                    // now playhead, fixed in the middle.
                    Rectangle().fill(Theme.accent).frame(width: 1.5, height: H - axisH + 3)
                        .offset(x: W / 2, y: axisH - 3)
                    Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(x: W / 2 - 2.5, y: axisH - 4)
                    // Blocks.
                    ForEach(laid, id: \.a.id) { item in
                        block(item.a, x0: max(x(start(item.a)), 0), x1: min(x(end(item.a, now)), W),
                              y: axisH + 2 + CGFloat(item.lane) * (laneH + laneGap))
                    }
                    // Agent activity band below the tasks.
                    ForEach(agPlaced, id: \.item.id) { entry in
                        agentBlock(entry.item, width: entry.w, x: entry.px,
                                   y: axisH + 2 + CGFloat(actionLanes + entry.lane) * (laneH + laneGap))
                    }
                    if let id = hoveredAgent,
                       let entry = agPlaced.first(where: { $0.item.id == id }) {
                        agentReport(entry.item)
                            // Above its own block, clamped inside the track so a
                            // command near either edge is still readable.
                            .offset(x: min(max(entry.px - 40, 4), max(W - 300, 4)),
                                    y: axisH + 2)
                    }
                    if agDropped > 0 {
                        Text("+\(agDropped)").font(OrbitFont.face(8))
                            .foregroundStyle(Color(red: 0.38, green: 0.78, blue: 0.86))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color(red: 0.38, green: 0.78, blue: 0.86).opacity(0.16)))
                            .offset(x: W - 30, y: H - 16)
                            .help("\(agDropped) more command\(agDropped == 1 ? "" : "s") this window")
                    }
                    if actions.isEmpty && agSorted.isEmpty {
                        Text("No tasks yet — select hosts, then Run or Schedule")
                            .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Hover a block → its detail + result floats above, in Orbit.
                    if let hid = hovered, let a = actions.first(where: { $0.id == hid }) {
                        ActionDetailCard(action: a, dep: actions.first { $0.id == a.dependsOn },
                                         tint: tint(a.status), schedule: schedule(a))
                            .frame(width: 240)
                            .offset(x: min(max(x(start(a)) - 8, 0), max(W - 240, 0)), y: -104)
                            .allowsHitTesting(false).transition(.opacity)
                    }
                }
            }
        }
        // The deck's corner radius is large, so content inset only to the
        // background's bounding box runs off the material where the corner
        // curves away — the header and the first/last time labels sit exactly
        // there. Inset past the arc instead.
        .padding(.horizontal, 30).padding(.top, 15).padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 38, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 38, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 18, y: 6)
    }

    @ViewBuilder
    func block(_ a: OrbitScheduler.Action, x0: CGFloat, x1: CGFloat, y: CGFloat) -> some View {
        let col = tint(a.status)
        let w = max(x1 - x0, 46)
        let pending = a.status == .pending
        let hot = hovered == a.id || selected == a.id
        let fg: Color = pending ? col : (light ? .black.opacity(0.85) : .white)
        HStack(spacing: 4) {
            Image(systemName: a.kind == .ansible ? "play.fill" : "chevron.right.circle.fill")
                .font(.system(size: 8, weight: .bold))
            // A command is shell text, so it is set as shell text. The mode's
            // display face is for its own labels — times, headings — and turns
            // `pwd && ls -1` into something you have to decipher.
            Text(a.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .frame(width: w, height: laneH, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(col.opacity(pending ? 0.18 : 0.9)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(col.opacity(hot ? 1 : (pending ? 0.65 : 0)),
                          style: StrokeStyle(lineWidth: hot ? 1.5 : 1, dash: pending ? [3, 3] : [])))
        .overlay(alignment: .trailing) {
            if !a.isTerminal, w > 40 {
                Button { onCancel(a.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(fg.opacity(0.8)).padding(4)
                }.buttonStyle(.plain)
            }
        }
        .help(caption(a) + " · " + a.targets.joined(separator: ", "))
        .onHover { inside in hovered = inside ? a.id : (hovered == a.id ? nil : hovered) }
        // Single click pins its detail + wire on the canvas; double-click opens
        // the captured output.
        .onTapGesture(count: 2) { if a.isTerminal { onOpen(a.id) } }
        .onTapGesture(count: 1) { onSelect(a.id) }
        .offset(x: x0, y: y)
    }

    /// What a block could not fit: the whole command, how long it took, and the
    /// first of what it returned. The block itself is sized by time, so a fast
    /// command is narrow however long its text is.
    func agentReport(_ it: AgentDeckItem) -> some View {
        let tint = it.isSubagent ? Color(red: 0.62, green: 0.52, blue: 0.96)
                                 : Color(red: 0.38, green: 0.78, blue: 0.86)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: it.isSubagent ? "person.2.fill"
                                                : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 8.5, weight: .bold)).foregroundStyle(tint)
                Text(hm(it.at)).font(OrbitFont.face(8))
                    .foregroundStyle(Theme.textSecondary)
                if let d = it.duration {
                    Text("· \(Self.durationLabel(d))").font(OrbitFont.face(8))
                        .foregroundStyle(Theme.textSecondary)
                } else if !it.isSubagent {
                    Text("· running").font(OrbitFont.face(8)).foregroundStyle(tint)
                }
                Spacer(minLength: 0)
            }
            Text(it.detail.isEmpty ? it.label : it.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let out = it.output, !out.isEmpty {
                Text(out.prefix(280))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                Text("Click for all of it")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
        }
        .padding(10)
        .frame(width: 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(light ? Color.white.opacity(0.95) : Color.black.opacity(0.9)))
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(tint.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .allowsHitTesting(false)
    }

    /// Seconds as something you read at a glance.
    static func durationLabel(_ d: TimeInterval) -> String {
        if d < 1 { return String(format: "%.0fms", d * 1000) }
        if d < 60 { return String(format: "%.1fs", d) }
        return String(format: "%dm %02ds", Int(d) / 60, Int(d) % 60)
    }

    /// A small marker for one agent activity — a sub-agent (violet) or a shell
    /// command (teal) — sat at its moment on the same time axis as the tasks.
    func agentBlock(_ it: AgentDeckItem, width: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        let tint = it.isSubagent ? Color(red: 0.62, green: 0.52, blue: 0.96)
                                 : Color(red: 0.38, green: 0.78, blue: 0.86)
        return HStack(spacing: 5) {
            Image(systemName: it.isSubagent ? "person.2.fill" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
            Text(it.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            // How long it took, in words. At a twelve-hour span a five-second
            // command is a fraction of a pixel wide, so width alone can only
            // answer the question at close range — this answers it at any.
            if let d = it.duration, width > 90 {
                Text(Self.durationLabel(d))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
        }
        // The glyph carries the colour; the command itself is read, so it takes
        // the full-strength ink rather than a tint at a fifth of it.
        .foregroundStyle(Theme.textPrimary.opacity(0.92))
        .padding(.horizontal, 7)
        .frame(width: width, height: laneH - 1, alignment: .leading)
        .background(Capsule().fill(tint.opacity(hoveredAgent == it.id ? 0.24 : 0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(hoveredAgent == it.id ? 0.9 : 0.5),
                                        lineWidth: 1))
        // A block is usually narrower than the command that made it, so the
        // full text and what it returned live in a card rather than in a
        // tooltip nobody waits for.
        .onHover { inside in
            hoveredAgent = inside ? it.id : (hoveredAgent == it.id ? nil : hoveredAgent)
        }
        .onTapGesture { onOpenAgent(it.id) }
        .offset(x: x, y: y)
    }

    func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}
