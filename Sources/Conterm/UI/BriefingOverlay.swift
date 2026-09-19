import SwiftUI

/// The "while you were away" card: everything the app noticed during an
/// absence, in one read, ordered by what deserves the eye first. Dismissing
/// marks it read — this is a summary, not an inbox, and it does not come
/// back for the same events.
struct BriefingOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var briefing = Briefing.shared

    var body: some View {
        BriefingCard(width: 680) {
            VStack(spacing: 0) {
                header
                content
                footer
            }
        }
    }

    // MARK: Header

    private var header: some View {
        DropHeader(eyebrow: "Briefing", title: "While you were away",
                   onClose: dismiss) {
            DropContext(subtitle)
        } controls: {
            if briefing.awaySpan >= 60 {
                DropChip(text: awayLabel, symbol: "moon.fill",
                         tint: Drop.tones[1])
            }
        }
    }

    private var subtitle: String {
        let n = briefing.pending.count
        if n == 0 { return "Nothing happened worth reporting." }
        return "\(n) thing\(n == 1 ? "" : "s") happened"
    }

    private var awayLabel: String {
        let s = briefing.awaySpan
        if s < 3600 { return "\(Int(s / 60))m away" }
        if s < 86400 { return "\(Int(s / 3600))h away" }
        return "\(Int(s / 86400))d away"
    }

    private func dismiss() {
        Briefing.shared.markSeen()
        state.closeBriefing()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let groups = briefing.grouped
        let work = briefing.outstandingWork
        if groups.isEmpty && work.isEmpty {
            DropStatement(symbol: "moon.stars", title: "All quiet",
                          message: "No agents finished, nothing failed, nothing changed.")
        } else {
            DropBody(maxHeight: 480) {
                tally(groups)
                ForEach(Array(groups.enumerated()), id: \.element.kind) { i, group in
                    band(group.kind, group.events, order: i + 1)
                }
                if !work.isEmpty { workBand(work, order: groups.count + 1) }
            }
        }
    }

    /// The absence in numbers: one large figure per kind of event.
    private func tally(_ groups: [(kind: Briefing.Kind, events: [Briefing.Event])]) -> some View {
        HStack(alignment: .top, spacing: 34) {
            ForEach(groups, id: \.kind) { group in
                VStack(alignment: .leading, spacing: 2) {
                    DropFigure(value: Double(group.events.count), color: color(group.kind))
                    Text(group.kind.label.uppercased())
                        .font(Drop.mono(8.5, .medium))
                        .kerning(1.6)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
        }
        .rollUp(delay: 0.08)
    }

    private func band(_ kind: Briefing.Kind, _ events: [Briefing.Event],
                      order: Int) -> some View {
        DropSection(label: kind.label, tint: color(kind), count: events.count, order: order) {
            DropWell {
                ForEach(Array(events.enumerated()), id: \.element.id) { i, event in
                    DropRow(index: i) { eventRow(event, kind: kind) }
                }
            }
        }
    }

    private func eventRow(_ event: Briefing.Event, kind: Briefing.Kind) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: kind.glyph)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color(kind))
                .frame(width: 24, height: 24)
                .background(Circle().fill(color(kind).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(Drop.display(12.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(event.message)
                    .font(Drop.display(11, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Self.relative.localizedString(for: event.at, relativeTo: Date()))
                .font(Drop.mono(9.5))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .fixedSize()
        }
    }

    /// What the agents left behind, read live. The events say an agent
    /// finished; this says whether its work is still sitting uncommitted.
    private func workBand(_ work: [WorktreeWatch.Snapshot], order: Int) -> some View {
        DropSection(label: "Unreviewed changes", count: work.count, order: order) {
            DropWell {
                ForEach(Array(work.enumerated()), id: \.element.root) { i, snap in
                    DropRow(index: i, action: { state.openWorktreeReview(root: snap.root) }) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.pull")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Drop.sheen)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                            VStack(alignment: .leading, spacing: 2) {
                                Text((snap.root as NSString).lastPathComponent)
                                    .font(Drop.display(12.5, .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(snap.branch) · \(snap.summary)")
                                    .font(Drop.mono(10))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        }
                    }
                }
            }
        }
    }

    private func color(_ kind: Briefing.Kind) -> Color {
        switch kind {
        case .alert:   return Drop.bad
        case .plan:    return Drop.warn
        case .agent:   return Drop.tones[0]
        default:       return Theme.textSecondary
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            DropButton(title: "Got it", symbol: "checkmark", prominent: true, action: dismiss)
        }
        .padding(.horizontal, Drop.inset)
        .padding(.bottom, 34)
        .rollUp(delay: 0.34)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
