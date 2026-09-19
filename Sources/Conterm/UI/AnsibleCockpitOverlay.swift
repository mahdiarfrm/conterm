import SwiftUI

/// Live cockpit for a pane's Ansible playbook run, built from the `Drop`
/// kit: a masthead with the playbook, play and current task; the run's
/// tally as large figures; the hosts × tasks matrix; then recent tasks,
/// the changes the play made, and a failure feed with messages. Rendered
/// from AnsibleCenter's tail of the callback feed — the pane's own console
/// output stays untouched.
struct AnsibleCockpitOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var center = AnsibleCenter.shared
    let target: AppState.AnsibleCockpitTarget

    private var run: AnsibleCenter.Run? {
        switch target {
        case .pane(let id): return center.runs[id]
        case .lastReport:   return center.lastReport
        }
    }

    var body: some View {
        BriefingCard(width: 690) {
            VStack(spacing: 0) {
                if let run {
                    header(run)
                    content(run)
                } else {
                    DropHeader(eyebrow: "Ansible", title: "No run yet",
                               onClose: { state.closeAnsibleCockpit() }) {
                        DropContext("Playbook runs in a pane report here.")
                    }
                    DropStatement(symbol: "play.circle",
                                  title: "No playbook run to show yet",
                                  message: "Start ansible-playbook in any pane and its hosts and tasks fill in live.")
                }
            }
        }
    }

    // MARK: Header

    private func header(_ run: AnsibleCenter.Run) -> some View {
        DropHeader(eyebrow: run.finished ? "Ansible · report" : "Ansible · running",
                   title: run.playbook, gem: gemColor(run),
                   gemHelp: run.summary,
                   onClose: { state.closeAnsibleCockpit() }) {
            DropContext(headerLine(run))
        } controls: {
            if run.finished, let at = run.finishedAt {
                // Staleness chip: an old matrix should read as old.
                DropChip(text: "ran \(Self.relative.localizedString(for: at, relativeTo: Date()))",
                         symbol: "clock")
            }
        }
    }

    private func gemColor(_ run: AnsibleCenter.Run) -> Color {
        if run.failedTotal > 0 { return Drop.bad }
        if run.finished { return Drop.good }
        return Theme.accent
    }

    private func headerLine(_ run: AnsibleCenter.Run) -> String {
        var parts: [String] = []
        if !run.play.isEmpty { parts.append(run.play) }
        parts.append("\(run.hostOrder.count) host\(run.hostOrder.count == 1 ? "" : "s")")
        if run.finished {
            parts.append("finished · \(run.tasksSeen) tasks · \(fmtDuration(run.elapsed))")
        } else if !run.currentTask.isEmpty {
            parts.append("task \(run.tasksSeen) — \(run.currentTask)")
            parts.append(fmtDuration(run.elapsed))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Content

    private func content(_ run: AnsibleCenter.Run) -> some View {
        DropBody(maxHeight: 560) {
            tallyBand(run)
            matrixBand(run)
            if !run.tasks.isEmpty { tasksBand(run) }
            if !run.changes.isEmpty { changesBand(run) }
            if !run.failures.isEmpty { failuresBand(run) }
        }
    }

    private func fmtDuration(_ s: Double) -> String {
        s < 60 ? String(format: "%.1fs", s)
               : String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // MARK: Tally

    /// The run in five numbers. A zero reads quiet; a count takes its
    /// result's color.
    private func tallyBand(_ run: AnsibleCenter.Run) -> some View {
        HStack(alignment: .top, spacing: 0) {
            tally("ok", run.okTotal, tint: Drop.good)
            tally("changed", run.changedTotal, tint: Drop.warn)
            tally("failed", run.failedTotal, tint: Drop.bad)
            tally("hosts", run.hostOrder.count, tint: nil)
            tally("tasks", run.tasksSeen, tint: nil)
        }
        .rollUp(delay: 0.06)
    }

    private func tally(_ label: String, _ value: Int, tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            DropFigure(value: Double(value), font: Drop.display(36, .light),
                       color: value > 0 ? (tint ?? Theme.textPrimary)
                                        : Theme.textSecondary.opacity(0.55))
            Text(label.uppercased())
                .font(Drop.mono(8.5, .medium))
                .kerning(1.6)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Matrix

    private static let cellSize: CGFloat = 12
    private static let rowHeight: CGFloat = 16
    private static let rowGap: CGFloat = 7

    /// The signature: hosts as rows, tasks as result cells — the whole
    /// play at a glance. Host names and their counts stay fixed; the cell
    /// field scrolls horizontally for long plays.
    private func matrixBand(_ run: AnsibleCenter.Run) -> some View {
        DropSection(label: "Hosts × tasks", order: 1) {
            DropWell(padding: 16) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: Self.rowGap) {
                        ForEach(run.hostOrder, id: \.self) { name in
                            Text(name)
                                .font(Drop.mono(11.5, .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 150, height: Self.rowHeight, alignment: .leading)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Self.rowGap) {
                            ForEach(run.hostOrder, id: \.self) { name in
                                HStack(spacing: 4) {
                                    ForEach(run.tasks) { task in
                                        cell(task.results[name],
                                             current: !run.finished
                                                && task.id == run.tasks.count - 1,
                                             task: task.name)
                                    }
                                }
                                .frame(height: Self.rowHeight)
                            }
                        }
                    }
                    VStack(alignment: .trailing, spacing: Self.rowGap) {
                        ForEach(run.hostOrder, id: \.self) { name in
                            if let host = run.hosts[name] {
                                Text(shortCounts(host))
                                    .font(Drop.mono(10))
                                    .foregroundStyle(host.failed + host.unreachable > 0
                                                     ? Drop.bad : Theme.textSecondary)
                                    .lineLimit(1)
                                    .frame(height: Self.rowHeight)
                            }
                        }
                    }
                }
            }
            legend
        }
    }

    private func cell(_ kind: AnsibleCenter.CellKind?, current: Bool,
                      task: String) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(cellColor(kind))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(current ? AnyShapeStyle(Drop.sheen)
                                          : AnyShapeStyle(Color.clear),
                                  lineWidth: 1.25)
            )
            .shadow(color: glows(kind) ? cellColor(kind).opacity(0.55) : .clear, radius: 3)
            .help("\(task) — \(cellName(kind))")
    }

    /// Only the results worth the eye carry light.
    private func glows(_ kind: AnsibleCenter.CellKind?) -> Bool {
        kind == .changed || kind == .failed || kind == .unreachable
    }

    private func cellColor(_ kind: AnsibleCenter.CellKind?) -> Color {
        switch kind {
        case .ok:          return Drop.good.opacity(0.62)
        case .changed:     return Drop.warn
        case .failed:      return Drop.bad
        case .unreachable: return Color(red: 0.80, green: 0.24, blue: 0.40)
        case .skipped:     return Theme.textSecondary.opacity(0.30)
        case nil:          return Theme.stroke
        }
    }

    private func cellName(_ kind: AnsibleCenter.CellKind?) -> String {
        switch kind {
        case .ok: return "ok"
        case .changed: return "changed"
        case .failed: return "failed"
        case .unreachable: return "unreachable"
        case .skipped: return "skipped"
        case nil: return "pending"
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendDot(.ok, "ok")
            legendDot(.changed, "changed")
            legendDot(.failed, "failed")
            legendDot(.unreachable, "unreachable")
            legendDot(.skipped, "skipped")
            Spacer()
        }
        .padding(.leading, 2)
    }

    private func legendDot(_ kind: AnsibleCenter.CellKind, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(cellColor(kind))
                .frame(width: 8, height: 8)
            Text(label)
                .font(Drop.mono(9))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
        }
    }

    private func shortCounts(_ h: AnsibleCenter.HostRow) -> String {
        var parts = ["\(h.ok)✓"]
        if h.changed > 0 { parts.append("\(h.changed)Δ") }
        if h.failed + h.unreachable > 0 { parts.append("\(h.failed + h.unreachable)✗") }
        return parts.joined(separator: " ")
    }

    // MARK: Tasks

    private func tasksBand(_ run: AnsibleCenter.Run) -> some View {
        let now = run.lastTs ?? Date().timeIntervalSince1970
        let slowest = run.tasks.max { $0.duration(now: now) < $1.duration(now: now) }
        return DropSection(label: "Tasks", count: run.tasks.count, order: 2) {
            if let slow = slowest, slow.duration(now: now) > 1 {
                HStack(spacing: 8) {
                    DropChip(text: "slowest · \(fmtDuration(slow.duration(now: now)))",
                             symbol: "tortoise.fill", tint: Drop.tones[1])
                    Text(slow.name)
                        .font(Drop.display(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            DropWell {
                ForEach(Array(run.tasks.suffix(8).reversed().enumerated()),
                        id: \.element.id) { i, task in
                    DropRow(index: i) { taskRow(task, run: run, now: now) }
                }
            }
        }
    }

    private func taskRow(_ task: AnsibleCenter.TaskEntry,
                         run: AnsibleCenter.Run, now: Double) -> some View {
        let failed = task.results.values.filter {
            $0 == .failed || $0 == .unreachable
        }.count
        let changed = task.results.values.filter { $0 == .changed }.count
        let live = !run.finished && task.id == run.tasks.count - 1
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: live ? "arrowtriangle.right.fill"
                  : failed > 0 ? "xmark" : "checkmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(live ? AnyShapeStyle(Drop.sheen)
                                 : failed > 0 ? AnyShapeStyle(Drop.bad)
                                 : AnyShapeStyle(Theme.textSecondary.opacity(0.7)))
                .frame(width: 14)
            Text(task.name)
                .font(Drop.display(12, live ? .semibold : .regular))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if changed > 0 {
                Text("\(changed)Δ")
                    .font(Drop.mono(10, .medium))
                    .foregroundStyle(Drop.warn)
            }
            if failed > 0 {
                Text("\(failed)✗")
                    .font(Drop.mono(10, .medium))
                    .foregroundStyle(Drop.bad)
            }
            Text(fmtDuration(task.duration(now: now)))
                .font(Drop.mono(10))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: Changes

    private func changesBand(_ run: AnsibleCenter.Run) -> some View {
        let changes = run.changes
        return DropSection(label: "Changed", tint: Drop.warn, count: changes.count, order: 3) {
            DropWell {
                ForEach(Array(changes.prefix(8).enumerated()), id: \.offset) { i, c in
                    DropRow(index: i) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(c.host)
                                .font(Drop.mono(11.5, .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 170, alignment: .leading)
                            Text(c.task)
                                .font(Drop.display(11.5, .regular))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if changes.count > 8 {
                    Text("+\(changes.count - 8) more")
                        .font(Drop.display(10.5, .regular))
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: Failures

    private func failuresBand(_ run: AnsibleCenter.Run) -> some View {
        DropSection(label: "Failures", tint: Drop.bad, count: run.failures.count, order: 4) {
            DropWell {
                ForEach(Array(run.failures.suffix(12).enumerated()),
                        id: \.element.id) { i, f in
                    DropRow(index: i) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(f.host)
                                    .font(Drop.mono(11.5, .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(f.task)
                                    .font(Drop.display(11.5, .regular))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                if f.unreachable {
                                    DropChip(text: "unreachable", tint: Drop.bad)
                                }
                            }
                            if !f.msg.isEmpty {
                                Text(f.msg)
                                    .font(Drop.mono(10.5))
                                    .foregroundStyle(Drop.bad.opacity(0.85))
                                    .lineSpacing(2)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Pane badge while a playbook is live (or just finished): counts at a
/// glance, click for the cockpit. Event-driven text only — no ambient
/// animation.
struct AnsiblePill: View {
    let run: AnsibleCenter.Run
    var onTap: () -> Void

    private var stateTint: Color {
        if run.failedTotal > 0 { return Drop.bad }
        if run.finished { return Drop.good }
        return Theme.accent
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let mark = CommandRow.bundledTemplateImage(named: "ansible-mark") {
                    Image(nsImage: mark)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 10, height: 10)
                        .foregroundStyle(stateTint)
                } else {
                    Image(systemName: run.finished
                          ? (run.failedTotal > 0 ? "xmark.circle.fill"
                                                 : "checkmark.circle.fill")
                          : "play.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(stateTint)
                }
                Text(run.playbook)
                    .font(Drop.display(10.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(run.summary)
                    .font(Drop.mono(9.5, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(Theme.chipBed))
            .overlay(Capsule().strokeBorder(Drop.sheen, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Ansible run — click for the cockpit")
    }
}
