import AppKit
import SwiftUI

/// "Since you looked away" — the first thing Orbit says on entry.
///
/// The graph draws the present, which is the answer to a question nobody has:
/// you left this mode knowing what was true, and you come back to find out what
/// changed. Each row is a way back to the thing it names.
extension OrbitOverlay {

    /// The phase names written into a snapshot. Spelled out rather than derived
    /// so a rename of the enum can't silently change what an old snapshot means.
    static func phaseName(_ phase: AgentStatus.Phase) -> String {
        switch phase {
        case .idle:        return "idle"
        case .ready:       return "ready"
        case .working:     return "working"
        case .attention:   return "attention"
        case .interrupted: return "interrupted"
        }
    }

    func currentSnapshot() -> OrbitSnapshot {
        var snap = OrbitSnapshot(at: Date())
        for row in allSessions() {
            let id = "pane:\(row.pane.id.uuidString)"
            snap.sessions[id] = Self.phaseName(row.pane.agent.phase)
            snap.names[id] = OrbitModel.paneLabel(row.pane)
        }
        snap.hosts = model.nodes.compactMap {
            if case .host(let t, let active) = $0.kind, active { return t }
            return nil
        }
        return snap
    }

    /// Gather the two endpoints and hand them to the diff.
    func changesSinceLastVisit() -> [OrbitChange] {
        guard let seen = OrbitSeen.load() else { return [] }
        let finished = scheduler.actions.compactMap { a -> OrbitChange.FinishedTask? in
            guard a.isTerminal, let at = a.finishedAt else { return nil }
            return OrbitChange.FinishedTask(id: a.id, label: a.label, targets: a.targets,
                                            failed: a.status == .failed, at: at)
        }
        return OrbitChange.diff(from: seen, to: currentSnapshot(), finished: finished,
                                hostName: { HostNameStore.name(for: $0) ?? $0 })
    }

    /// Computed a beat after entry: the model rebuilds on its own clock, and
    /// asking the instant the view mounts reports an empty fleet as though
    /// everything had disconnected.
    func loadChangesSinceLastVisit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let changes = changesSinceLastVisit()
            guard !changes.isEmpty else { return }
            withAnimation(Theme.Spring.soft) { since = changes }
        }
    }

    func openChange(_ change: OrbitChange) {
        if let paneID = change.paneID,
           let node = model.nodes.first(where: { $0.id == "pane:\(paneID.uuidString)" }) {
            focusSession(node)
        } else if let actionID = change.actionID {
            withAnimation(Theme.Spring.snappy) { pinnedActionID = actionID }
        }
        withAnimation(Theme.Spring.snappy) { since = [] }
    }

    /// Shown once per visit, under the header. It is news, not state: reading it
    /// is the point, so it goes away when you act on it or dismiss it, and never
    /// comes back for the same visit.
    @ViewBuilder
    var sincePanel: some View {
        if !since.isEmpty {
            let shown = Array(since.prefix(4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    OrbitText(text: "SINCE YOU LOOKED AWAY", size: 8, tracking: 1.2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    Spacer(minLength: 12)
                    Button { withAnimation(Theme.Spring.snappy) { since = [] } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                }
                .padding(.leading, 16).padding(.trailing, 8)
                .padding(.top, 12).padding(.bottom, 4)

                ForEach(shown) { c in
                    Button { openChange(c) } label: { sinceRow(c) }
                        .buttonStyle(.plain)
                }
                if since.count > shown.count {
                    Text("and \(since.count - shown.count) more")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .padding(.leading, 16).padding(.top, 3)
                }
            }
            .padding(.bottom, 12)
            .frame(width: 340, alignment: .leading)
            .modifier(PaletteBubble(cornerRadius: 18))
            // Inside the panel, not on the slot: an empty slot must take no
            // room at all, or the header carries a gap on every quiet entry.
            .padding(.top, 10)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    func sinceRow(_ c: OrbitChange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: c.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sinceTint(c.kind))
                .frame(width: 16)
            Text(c.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if let d = c.detail {
                Text(d)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    func sinceTint(_ kind: OrbitChange.Kind) -> Color {
        switch kind {
        case .needsYou:   return Theme.warning
        case .taskFailed: return Color(red: 0.95, green: 0.42, blue: 0.42)
        case .finished, .taskOk: return Color(red: 0.40, green: 0.86, blue: 0.56)
        case .hostNew, .hostGone: return Theme.textSecondary
        }
    }
}
