import SwiftUI

/// Classic interface style.
/// What the agent in a pane has done, as a record rather than scrollback:
/// every call with what it was about, how long it took, how it ended, and
/// its output when opened. Calls in flight sit on top and keep counting;
/// the rest are newest first. Monochrome throughout — the marks carry the
/// meaning, and a red verdict is the one colour that earns its place.
struct ClassicAgentToolOverlay: View {
    @EnvironmentObject var state: AppState
    let target: AppState.AgentToolsTarget
    let glassLive: Bool

    var body: some View {
        ClassicBriefingCard(glassLive: glassLive, width: 660) {
            if let pane = state.pane(id: target.paneID) {
                AgentToolPanel(pane: pane, focus: target.runID)
            } else {
                Text("That pane is gone.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(40)
            }
        }
    }
}

private struct AgentToolPanel: View {
    @ObservedObject var pane: Pane
    let focus: String?
    @EnvironmentObject var state: AppState
    @ObservedObject private var terraform = TerraformCenter.shared
    @ObservedObject private var ansible = AnsibleCenter.shared

    @State private var filter: AgentToolKind?
    /// Runs opened to their output. The one clicked to get here starts open.
    @State private var expanded: Set<String> = []
    @State private var hovered: String?

    private static let failColor = Color(red: 1.0, green: 0.42, blue: 0.42)

    private var runs: [AgentToolRun] {
        pane.toolRuns
            .filter { filter == nil || $0.kind == filter }
            .sorted { a, b in
                if a.isRunning != b.isRunning { return a.isRunning }
                return a.startedAt > b.startedAt
            }
    }

    /// Kinds present, in the enum's order, with counts.
    private var kinds: [(kind: AgentToolKind, count: Int)] {
        AgentToolKind.allCases.compactMap { k in
            let n = pane.toolRuns.filter { $0.kind == k }.count
            return n > 0 ? (k, n) : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if kinds.count > 1 { filters }
            Divider().opacity(0.4)
            content
        }
        .onAppear {
            if let focus { expanded.insert(focus) }
            // The transcript fills in commands and output while this shows.
            AgentCenter.shared.beginObserving()
        }
        .onDisappear { AgentCenter.shared.endObserving() }
        .onChange(of: focus) { _, new in
            if let new { expanded.insert(new) }
        }
    }

    // MARK: Header

    private var header: some View {
        let running = pane.toolRuns.filter(\.isRunning).count
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    if let asset = pane.agent.tool.markAsset,
                       let img = MarkImage.load(asset, template: pane.agent.tool.markIsTemplate) {
                        Image(nsImage: img)
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text("History")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text(subtitle(running: running))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if terraform.plans[pane.id] != nil {
                link("Terraform plan", .terraform) {
                    state.closeAgentTools()
                    state.openTerraformCockpit(paneID: pane.id)
                }
            }
            if ansible.runs[pane.id] != nil {
                link("Ansible cockpit", .ansible) {
                    state.closeAgentTools()
                    state.openAnsibleCockpit(paneID: pane.id)
                }
            }
            Button { state.closeAgentTools() } label: {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func subtitle(running: Int) -> String {
        var parts = [friendlyDirLabel(for: pane.cwd)]
        if let host = pane.remoteHost { parts.append(host) }
        let n = pane.toolRuns.count
        parts.append(n == 1 ? "1 call" : "\(n) calls")
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: "  ·  ")
    }

    private func link(_ title: String, _ kind: AgentToolKind,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                AgentToolGlyph(kind: kind, color: Theme.textPrimary, size: 11)
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Theme.chipBed))
            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 0.6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Filters

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", nil, pane.toolRuns.count)
                ForEach(kinds, id: \.kind) { entry in
                    chip(entry.kind.displayName, entry.kind, entry.count)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private func chip(_ title: String, _ kind: AgentToolKind?, _ count: Int) -> some View {
        let on = filter == kind
        return Button {
            withAnimation(Theme.Spring.snappy) { filter = kind }
            SoundEffects.shared.play(.toggle)
        } label: {
            HStack(spacing: 5) {
                if let kind {
                    AgentToolGlyph(kind: kind,
                                   color: on ? Theme.textPrimary : Theme.textSecondary,
                                   size: 11)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? Theme.selectionFill : Theme.chipBed))
            .overlay(Capsule().strokeBorder(on ? Theme.strokeStrong : Theme.stroke,
                                            lineWidth: 0.6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Rows

    @ViewBuilder
    private var content: some View {
        if runs.isEmpty {
            Text("Nothing yet. Calls appear here as Claude works: shell, files, search, the web, sub-agents, and the tools it reaches for.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(runs) { run in
                        row(run)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: listHeight)
        }
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(runs.count) * 60
        let open = CGFloat(expanded.intersection(runs.map(\.id)).count) * 200
        return min(rows + open + 12, 540)
    }

    private func toggle(_ run: AgentToolRun) {
        withAnimation(Theme.Spring.snappy) {
            if expanded.contains(run.id) { expanded.remove(run.id) } else { expanded.insert(run.id) }
        }
        SoundEffects.shared.play(.toggle)
    }

    private func row(_ run: AgentToolRun) -> some View {
        let isOpen = expanded.contains(run.id)
        let isHover = hovered == run.id
        return VStack(alignment: .leading, spacing: 8) {
            Button { toggle(run) } label: {
                HStack(alignment: .top, spacing: 14) {
                    AgentToolGlyph(kind: run.kind,
                                   color: Theme.textPrimary.opacity(run.isRunning || isOpen ? 1 : 0.8),
                                   size: 20)
                        .frame(width: 24, height: 24)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(run.kind.displayName)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Self.relative.localizedString(for: run.startedAt, relativeTo: Date()))
                                .font(.system(size: 10.5, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 4)
                            verdict(run)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                        }
                        Text(run.command ?? run.kind.displayName)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.72))
                            .lineLimit(isOpen ? 6 : 2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { outputBox(run) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOpen || isHover ? Theme.selectionFill : Color.clear)
        )
        .padding(.horizontal, 8)
        .onHover { hovered = $0 ? run.id : (hovered == run.id ? nil : hovered) }
    }

    /// Elapsed while running, duration and outcome once done.
    @ViewBuilder
    private func verdict(_ run: AgentToolRun) -> some View {
        if run.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.textPrimary)
                        .frame(width: 5, height: 5)
                        .opacity(Int(tl.date.timeIntervalSinceReferenceDate) % 2 == 0 ? 1 : 0.35)
                    Text(Self.duration(tl.date.timeIntervalSince(run.startedAt)))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        } else {
            HStack(spacing: 5) {
                if let d = run.duration {
                    Text(Self.duration(d))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                if run.failed {
                    Text("failed")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Self.failColor)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func outputBox(_ run: AgentToolRun) -> some View {
        let text: String
        let dim: Bool
        if run.isRunning {
            text = "Running… output lands when the call returns."; dim = true
        } else if let out = run.output, !out.isEmpty {
            text = out; dim = false
        } else if run.resultSeen {
            text = "No output."; dim = true
        } else {
            text = "Reading the transcript…"; dim = true
        }
        return ScrollView {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(dim ? Theme.textSecondary : Theme.textPrimary.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 190)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.recessedWash))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.5))
        .padding(.leading, 38)
    }

    private static func duration(_ s: TimeInterval) -> String {
        if s < 10 { return String(format: "%.1fs", s) }
        if s < 60 { return "\(Int(s))s" }
        let m = Int(s) / 60, r = Int(s) % 60
        if m < 60 { return String(format: "%dm %02ds", m, r) }
        return String(format: "%dh %02dm", m / 60, m % 60)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
