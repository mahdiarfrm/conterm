import AppKit
import Combine
import SwiftUI

/// The timeline deck at the foot of the canvas — what ran, what is running
/// and what is due, against a clock.
extension OrbitOverlay {

    /// Deck height (collapsed vs. click-expanded) and how far it floats off the
    /// bottom — it rises above the action toolbar when a selection is present.
    var deckHeight: CGFloat {
        if deckExpanded { return 250 }
        return agentDeckItems.isEmpty ? 118 : 158   // room for the agent band
    }
    /// The deck sits above the action bar whenever the bar is up — for a host
    /// selection *or* a node the bar is aimed at. Keyed on the selection alone,
    /// it stayed low and covered the bar for every other kind of node, which
    /// read as the bar simply not opening.
    var barIsUp: Bool { !selectedHosts.isEmpty || barNode != nil }
    var deckBottom: CGFloat { barIsUp ? 74 : 16 }
    /// The deck shares the foot of the canvas with the preview dock, and two
    /// stacked surfaces there read as a mess — so it steps aside while you're
    /// working in the bar or watching a terminal.
    var deckHidden: Bool { (commandOpen && barNode != nil) || !previewPanes.isEmpty }
    /// How far the bottom-right controls and the side panels have to sit off the
    /// bottom edge. With the deck away they belong in the corner — held up by a
    /// deck that isn't drawn, they read as floating in the middle of nothing.
    var deckClearance: CGFloat { deckHidden ? 18 : deckBottom + deckHeight + 12 }
    /// The zoom / space controls belong in the corner. The deck is centred and
    /// capped at 600pt, so the corner is free unless the window is too narrow
    /// for the two to sit side by side.
    var controlsBottom: CGFloat {
        deckHidden || viewport.width > 1060 ? 18 : deckBottom + deckHeight + 12
    }

    /// The plan as an always-on bottom time-track centered on *now*: past to the
    /// left, upcoming to the right, a fixed playhead in the middle. Time
    /// gridlines mark the passing minutes; each action is a lane-packed block
    /// sized by its duration. Hovering a block previews it on the canvas; a
    /// click on the track makes the deck taller. The slider in its header sets
    /// how much time is in view.
    var timelineDeck: some View {
        VStack {
            Spacer()
            TimelineDeckView(actions: scheduler.actions, agentItems: agentDeckItems,
                             light: prefs.lightGlass,
                             expanded: $deckExpanded, span: $deckSpan,
                             hovered: deckHoverBinding,
                             selected: pinnedActionID,
                             caption: { actionCaption($0) }, tint: { actionColor($0) },
                             onCancel: { scheduler.cancel($0) },
                             onOpen: { id in withAnimation(Theme.Spring.snappy) { modal = .output(id) } },
                             onSaveRoutine: { captureRoutine(from: $0) },
                             onSelect: { id in
                                 withAnimation(Theme.Spring.snappy) {
                                     pinnedActionID = (pinnedActionID == id) ? nil : id
                                 }
                             },
                             schedule: { scheduleLine($0) },
                             onClearDone: { scheduler.clearFinished() },
                             // A command's id is its tool_use id, which is what
                             // the shell-output modal keys on.
                             onOpenAgent: { id in
                                 guard id.hasPrefix("cmd:") else { return }
                                 withAnimation(Theme.Spring.snappy) {
                                     modal = .shell(String(id.dropFirst("cmd:".count)))
                                 }
                             })
                .frame(maxWidth: 600)
                .frame(height: deckHidden ? 0 : deckHeight)
                .opacity(deckHidden ? 0 : 1)
                .allowsHitTesting(!deckHidden)
                .padding(.bottom, deckBottom)
                .animation(Theme.Spring.snappy, value: deckExpanded)
                .animation(Theme.Spring.snappy, value: selectedHosts.isEmpty)
        }
    }

    /// Short state caption for an action — schedule while pending, live word
    /// while running, result note when finished.
    func actionCaption(_ a: OrbitScheduler.Action) -> String {
        switch a.status {
        case .pending:
            if a.held { return a.dependsOn != nil ? "staged →" : "staged" }
            if let t = a.agentTrigger { return t.phase == "attention" ? "waits: needs you" : "waits: finishes" }
            if let dep = a.dependsOn, let d = scheduler.action(dep) { return "after \(d.label)" }
            if let t = a.runAt { return "at \(hhmm(t))" }
            return "queued"
        case .running: return "running…"
        case .done:    return "done"
        case .failed:  return "failed"
        }
    }

    func actionColor(_ s: OrbitScheduler.Status) -> Color {
        switch s {
        case .pending: return Theme.accent
        case .running: return Color(red: 0.45, green: 0.85, blue: 1.0)
        case .done:    return Color(red: 0.35, green: 0.82, blue: 0.45)
        case .failed:  return Color(red: 1, green: 0.42, blue: 0.42)
        }
    }

    func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    /// Space switcher: the automatic views, and saved hand-arranged boards.
    var spacesMenu: some View {
        Menu {
            // Two automatic views: what's happening, and everything you can
            // reach. Neither is curated — the boards below are.
            Button {
                state.orbitFocusSession = nil; spaces.currentID = nil; autoView = "live"
            } label: {
                Label("Live", systemImage: isLiveView ? "checkmark" : "dot.radiowaves.left.and.right")
            }
            Button {
                state.orbitFocusSession = nil; spaces.currentID = nil; autoView = "fleet"
            } label: {
                Label("Fleet", systemImage: isFleetView ? "checkmark"
                                                        : "externaldrive.connected.to.line.below")
            }
            // Live Claude sessions — pin Orbit to one to see & steer just it.
            if !agents.entries.isEmpty {
                Divider()
                Text("Sessions")
                ForEach(agents.entries) { e in
                    Button {
                        state.orbitFocusSession = e.id; spaces.currentID = nil
                    } label: {
                        Label(sessionName(e.id),
                              systemImage: state.orbitFocusSession == e.id ? "checkmark" : sessionIcon(e.phase))
                    }
                }
            }
            if !spaces.spaces.isEmpty { Divider() }
            ForEach(spaces.spaces) { s in
                Button { state.orbitFocusSession = nil; spaces.currentID = s.id } label: {
                    Label(s.name, systemImage: spaces.currentID == s.id ? "checkmark" : "square.on.square")
                }
            }
            Divider()
            Button { state.orbitFocusSession = nil; spaces.create() } label: { Label("New space", systemImage: "plus") }
            if let cur = spaces.current {
                Button { spaceNameInput = cur.name; renamingSpace = true } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { spaces.delete(cur.id) } label: { Label("Delete space", systemImage: "trash") }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: menuIcon).font(.system(size: 10, weight: .semibold))
                Text(menuLabel).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(state.orbitFocusSession != nil ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 11)
            // Match the mode switcher's pill height so the two sit on one line.
            .frame(height: 30)
            .background(Capsule().fill(state.orbitFocusSession != nil ? Theme.accent.opacity(0.14) : chromeFill(prefs)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    var menuLabel: String {
        if let sid = state.orbitFocusSession { return sessionName(sid) }
        return spaces.current?.name ?? (isFleetView ? "Fleet" : "Live")
    }
    var menuIcon: String {
        state.orbitFocusSession != nil ? "sparkles" : "square.on.square"
    }
    func sessionIcon(_ phase: AgentStatus.Phase) -> String {
        switch phase {
        case .working:   return "circle.dotted"
        case .attention: return "exclamationmark.circle"
        default:         return "circle"
        }
    }
}
