import SwiftUI

/// Live cockpit for a pane's Ansible playbook run: header with the
/// playbook, play, and current task; one row per host with count chips
/// and a status glyph; a failure feed with messages; recap line once
/// stats land. Rendered from AnsibleCenter's tail of the callback
/// feed — the pane's own console output stays untouched.
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
        VStack(spacing: 0) {
            if let run {
                header(run)
                Divider().opacity(0.4)
                content(run)
            } else {
                Text("No playbook run to show yet.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(40)
            }
        }
        .background(OverlayPanelBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 10)
        .frame(width: 620)
    }

    // MARK: Header

    private func header(_ run: AnsibleCenter.Run) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(gemColor(run))
                .frame(width: 8, height: 8)
                .shadow(color: gemColor(run).opacity(0.8), radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.playbook)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(headerLine(run))
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(run.summary)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(run.failedTotal > 0
                                 ? Color.red.opacity(0.95) : Theme.textSecondary)
                .monospacedDigit()
            if run.finished, let at = run.finishedAt {
                // Staleness pill: an old matrix should read as old.
                Text("ran \(Self.relative.localizedString(for: at, relativeTo: Date()))")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            Button { state.closeAnsibleCockpit() } label: {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func gemColor(_ run: AnsibleCenter.Run) -> Color {
        if run.failedTotal > 0 { return Color.red.opacity(0.95) }
        if run.finished { return Color(red: 0.45, green: 0.85, blue: 0.55) }
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

    @State private var contentHeight: CGFloat = 0

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private func content(_ run: AnsibleCenter.Run) -> some View {
        // The card hugs its content — a ScrollView greedily takes its
        // whole max height, leaving a small run floating in dead space.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                matrixBand(run)
                if !run.tasks.isEmpty {
                    hairline
                    tasksBand(run)
                }
                if !run.changes.isEmpty {
                    hairline
                    changesBand(run)
                }
                if !run.failures.isEmpty {
                    hairline
                    failuresBand(run)
                }
            }
            .padding(.bottom, 6)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self,
                                       value: geo.size.height)
            })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 60), 520))
    }

    private var hairline: some View {
        Rectangle().fill(Theme.stroke).frame(height: 0.5)
    }

    private func microLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .kerning(1.3)
            .foregroundStyle(Theme.textSecondary.opacity(0.7))
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

    // MARK: Matrix

    /// The signature: hosts as rows, tasks as result cells — the whole
    /// play at a glance. Host names and their count chips stay fixed;
    /// the cell field scrolls horizontally for long plays.
    private func matrixBand(_ run: AnsibleCenter.Run) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            microLabel("HOSTS × TASKS")
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(run.hostOrder, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 11, weight: .medium,
                                          design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 150, height: 13, alignment: .leading)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(run.hostOrder, id: \.self) { name in
                            HStack(spacing: 3) {
                                ForEach(run.tasks) { task in
                                    cell(task.results[name],
                                         current: !run.finished
                                            && task.id == run.tasks.count - 1,
                                         task: task.name)
                                }
                            }
                            .frame(height: 13)
                        }
                    }
                }
                VStack(alignment: .trailing, spacing: 5) {
                    ForEach(run.hostOrder, id: \.self) { name in
                        if let host = run.hosts[name] {
                            Text(shortCounts(host))
                                .font(.system(size: 9.5, design: .rounded))
                                .foregroundStyle(host.failed + host.unreachable > 0
                                                 ? Color.red.opacity(0.95)
                                                 : Theme.textSecondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(height: 13)
                        }
                    }
                }
            }
            legend
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func cell(_ kind: AnsibleCenter.CellKind?, current: Bool,
                      task: String) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(cellColor(kind))
            .frame(width: 9, height: 9)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(current ? Theme.accent : .clear, lineWidth: 1)
            )
            .help("\(task) — \(cellName(kind))")
    }

    private func cellColor(_ kind: AnsibleCenter.CellKind?) -> Color {
        switch kind {
        case .ok:          return Color(red: 0.30, green: 0.62, blue: 0.40)
        case .changed:     return Color(red: 0.93, green: 0.68, blue: 0.25)
        case .failed:      return Color.red.opacity(0.92)
        case .unreachable: return Color(red: 0.75, green: 0.20, blue: 0.30)
        case .skipped:     return Theme.textSecondary.opacity(0.35)
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
        HStack(spacing: 10) {
            legendDot(.ok, "ok")
            legendDot(.changed, "changed")
            legendDot(.failed, "failed")
            legendDot(.skipped, "skipped")
            Spacer()
        }
    }

    private func legendDot(_ kind: AnsibleCenter.CellKind, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(cellColor(kind))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 9, design: .rounded))
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
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                microLabel("TASKS · \(run.tasks.count)")
                Spacer()
                if let slow = slowest, slow.duration(now: now) > 1 {
                    Text("slowest: \(slow.name) · \(fmtDuration(slow.duration(now: now)))")
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            ForEach(run.tasks.suffix(8).reversed()) { task in
                taskRow(task, run: run, now: now)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(live ? Theme.accent
                                 : failed > 0 ? Color.red.opacity(0.95)
                                 : Theme.textSecondary)
                .frame(width: 12)
            Text(task.name)
                .font(.system(size: 11, weight: live ? .semibold : .regular,
                              design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if changed > 0 {
                Text("\(changed)Δ")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(cellColor(.changed))
                    .monospacedDigit()
            }
            if failed > 0 {
                Text("\(failed)✗")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Color.red.opacity(0.95))
                    .monospacedDigit()
            }
            Text(fmtDuration(task.duration(now: now)))
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Changes

    private func changesBand(_ run: AnsibleCenter.Run) -> some View {
        let changes = run.changes
        return VStack(alignment: .leading, spacing: 6) {
            microLabel("CHANGED · \(changes.count)")
            ForEach(Array(changes.prefix(8).enumerated()), id: \.offset) { _, c in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(cellColor(.changed))
                        .frame(width: 7, height: 7)
                    Text(c.host)
                        .font(.system(size: 10.5, weight: .medium,
                                      design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                    Text(c.task)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            if changes.count > 8 {
                Text("+\(changes.count - 8) more")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func failuresBand(_ run: AnsibleCenter.Run) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            microLabel("FAILURES · \(run.failures.count)")
            ForEach(run.failures.suffix(12)) { f in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red.opacity(0.9))
                            .frame(width: 4, height: 4)
                        Text("\(f.host) — \(f.task)\(f.unreachable ? " (unreachable)" : "")")
                            .font(.system(size: 11, weight: .medium,
                                          design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    if !f.msg.isEmpty {
                        Text(f.msg)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .padding(.leading, 10)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Pane badge while a playbook is live (or just finished): counts at a
/// glance, click for the cockpit. Event-driven text only — no ambient
/// animation.
struct AnsiblePill: View {
    let run: AnsibleCenter.Run
    var onTap: () -> Void

    private var stateTint: Color {
        if run.failedTotal > 0 { return Color.red.opacity(0.95) }
        if run.finished { return Color(red: 0.45, green: 0.85, blue: 0.55) }
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
                Text("\(run.playbook) · \(run.summary)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.chipBed))
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Ansible run — click for the cockpit")
    }
}
