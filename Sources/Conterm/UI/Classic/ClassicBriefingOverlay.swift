import SwiftUI

/// Classic interface style.
/// The "while you were away" card: everything the app noticed during an
/// absence, in one read, ordered by what deserves the eye first. Dismissing
/// marks it read — this is a summary, not an inbox, and it does not come
/// back for the same events.
struct ClassicBriefingOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var briefing = Briefing.shared
    let glassLive: Bool

    var body: some View {
        ClassicBriefingCard(glassLive: glassLive, width: 620) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                content
                Divider().opacity(0.4)
                footer
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("While you were away")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if briefing.awaySpan >= 60 {
                Text(awayLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
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

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let groups = briefing.grouped
        let work = briefing.outstandingWork
        if groups.isEmpty && work.isEmpty {
            Text("No agents finished, nothing failed, nothing changed.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.kind) { group in
                        band(group.kind, group.events)
                        hairline
                    }
                    if !work.isEmpty { workBand(work) }
                }
                .padding(.bottom, 6)
            }
            .frame(height: min(CGFloat(briefing.pending.count + work.count) * 34 + 90, 420))
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.stroke).frame(height: 0.5)
    }

    private func band(_ kind: Briefing.Kind, _ events: [Briefing.Event]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: kind.glyph)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color(kind))
                Text(kind.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(1.3)
                    .foregroundStyle(color(kind))
                Text("\(events.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.stroke))
            }
            ForEach(events) { event in eventRow(event) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func eventRow(_ event: Briefing.Event) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                    .lineLimit(1)
                Text(event.message)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Self.relative.localizedString(for: event.at, relativeTo: Date()))
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .fixedSize()
        }
    }

    /// What the agents left behind, read live. The events say an agent
    /// finished; this says whether its work is still sitting uncommitted.
    private func workBand(_ work: [WorktreeWatch.Snapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("UNREVIEWED CHANGES")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(1.3)
                    .foregroundStyle(Theme.accent)
            }
            ForEach(work, id: \.root) { snap in
                Button { state.openWorktreeReview(root: snap.root) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((snap.root as NSString).lastPathComponent)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                            Text("\(snap.branch) · \(snap.summary)")
                                .font(.system(size: 10.5, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func color(_ kind: Briefing.Kind) -> Color {
        switch kind {
        case .alert:   return Color(red: 0.93, green: 0.42, blue: 0.42)
        case .plan:    return Color(red: 0.95, green: 0.72, blue: 0.32)
        case .agent:   return Theme.accent
        default:       return Theme.textSecondary.opacity(0.75)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                Briefing.shared.markSeen()
                state.closeBriefing()
            } label: {
                Text("Got it")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.selectionFill))
                    .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
