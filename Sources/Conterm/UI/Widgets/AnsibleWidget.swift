import SwiftUI

/// Playbook runs at a glance, across every pane and window. Hidden
/// until a run exists; the pill shows the live count (or the latest
/// verdict once idle), and the popover lists runs with a jump into
/// each one's cockpit.
struct AnsibleWidget: View {
    @ObservedObject private var center = AnsibleCenter.shared
    @EnvironmentObject private var state: AppState
    var compact: Bool
    @State private var showingPopover = false

    private var active: Int { center.runs.values.filter { !$0.finished }.count }
    private var latest: AnsibleCenter.Run? {
        center.runs.values.max { $0.updatedAt < $1.updatedAt }
            ?? center.lastReport
    }

    var body: some View {
        Group {
            if !center.runs.isEmpty || center.lastReport != nil {
                WidgetShell(compact: compact,
                            help: help,
                            onTap: {
                                showingPopover.toggle()
                                SoundEffects.shared.play(.toggle)
                            }) {
                    HStack(spacing: compact ? 4 : 5) {
                        if let mark = CommandRow.bundledTemplateImage(named: "ansible-mark") {
                            Image(nsImage: mark)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: compact ? 9 : 10,
                                       height: compact ? 9 : 10)
                                .foregroundStyle(pillTint)
                        } else {
                            Image(systemName: "circle.grid.3x3")
                                .font(.system(size: compact ? 8.5 : 9.5,
                                              weight: .medium))
                                .foregroundStyle(pillTint)
                        }
                        // With only the persisted last report left, the
                        // pill quiets down to the bare mark — no count,
                        // no verdict.
                        if !center.runs.isEmpty {
                            Text(pillText)
                                .font(.system(size: compact ? 10 : 11,
                                              weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                        }
                    }
                }
                .popover(isPresented: $showingPopover, arrowEdge: .top) {
                    AnsibleRunsPopover(center: center, state: state)
                }
            }
        }
    }

    private var pillTint: Color {
        if active > 0 { return Theme.accent }
        // Live verdict colors only while runs are listed; the bare
        // last-report mark stays neutral.
        guard !center.runs.isEmpty else { return Theme.textPrimary }
        if let latest, latest.failedTotal > 0 { return Color.red.opacity(0.95) }
        return Color(red: 0.45, green: 0.85, blue: 0.55)
    }

    private var pillText: String {
        active > 0 ? "\(active)" : (latest?.failedTotal ?? 0) > 0 ? "✗" : "✓"
    }

    private var help: String {
        if active > 0 {
            return "ansible · \(active) playbook\(active == 1 ? "" : "s") running — click for runs"
        }
        if let latest {
            return "ansible · last run \(latest.playbook): \(latest.summary) — click for runs"
        }
        return "ansible"
    }
}

private struct AnsibleRunsPopover: View {
    @ObservedObject var center: AnsibleCenter
    let state: AppState
    @Environment(\.dismiss) private var dismiss

    private var ordered: [(paneID: UUID, run: AnsibleCenter.Run)] {
        center.runs.map { ($0.key, $0.value) }
            .sorted { $0.run.updatedAt > $1.run.updatedAt }
    }

    var body: some View {
        WidgetPopoverChrome(title: "Ansible", width: 300, trailing: {
            widgetPopoverChip("\(center.runs.count) run\(center.runs.count == 1 ? "" : "s")")
        }) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ordered, id: \.paneID) { entry in
                    RunRow(run: entry.run,
                           action: {
                               SoundEffects.shared.play(.click)
                               center.jump(paneID: entry.paneID)
                               dismiss()
                           },
                           clear: {
                               SoundEffects.shared.play(.toggle)
                               center.clear(paneID: entry.paneID)
                           })
                }
                // The machine's last report outlives cleared runs and
                // relaunches; its age tells you how stale the matrix is.
                if center.runs.isEmpty, let last = center.lastReport {
                    lastReportRow(last)
                }
            }
            .padding(.vertical, 6)
            if ordered.contains(where: { $0.run.finished }) {
                Divider().opacity(0.45)
                Button {
                    SoundEffects.shared.play(.toggle)
                    center.clearFinished()
                } label: {
                    Text("Clear finished runs")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func lastReportRow(_ run: AnsibleCenter.Run) -> some View {
        Button {
            SoundEffects.shared.play(.click)
            state.openAnsibleLastReport()
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.playbook)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(run.summary)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(run.failedTotal > 0
                                         ? Color.red.opacity(0.9)
                                         : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let at = run.finishedAt {
                    widgetPopoverChip("ran \(Self.relative.localizedString(for: at, relativeTo: Date()))")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Last report on this machine — click for the matrix")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

private struct RunRow: View {
    let run: AnsibleCenter.Run
    let action: () -> Void
    let clear: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(gem)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.playbook)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(run.finished ? run.summary
                         : "running — \(run.currentTask)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(run.failedTotal > 0
                                         ? Color.red.opacity(0.9) : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovering, run.finished {
                    Button(action: clear) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear this report")
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary
                            .opacity(hovering ? 1 : 0))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovering ? Theme.selectionFill : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var gem: Color {
        if !run.finished { return Theme.accent }
        return run.failedTotal > 0 ? Color.red.opacity(0.95)
                                   : Color(red: 0.45, green: 0.85, blue: 0.55)
    }
}
