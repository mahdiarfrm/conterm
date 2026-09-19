import SwiftUI

/// What the agent in a pane has done, as a record rather than scrollback:
/// every call with what it was about, how long it took, how it ended, and
/// its output when opened. Calls in flight sit on top and keep counting;
/// the rest are newest first.
///
/// Built from the `Drop` kit: a masthead naming the working directory, a
/// row of kind filters, then the calls in one well. Colour is reserved for
/// state — a call in flight and a failed one; a clean finish stays quiet.
struct AgentToolOverlay: View {
    @EnvironmentObject var state: AppState
    let target: AppState.AgentToolsTarget

    var body: some View {
        BriefingCard(width: 720) {
            if let pane = state.pane(id: target.paneID) {
                AgentToolPanel(pane: pane, focus: target.runID)
            } else {
                VStack(spacing: 0) {
                    DropHeader(eyebrow: "History", title: "Pane closed",
                               onClose: { state.closeAgentTools() }) {
                        DropContext("Its record went with it.")
                    }
                    DropStatement(symbol: "rectangle.slash", title: "That pane is gone")
                }
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
            if kinds.count > 1 { filters.rollUp(delay: 0.12) }
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
        return DropHeader(eyebrow: "History",
                          title: friendlyDirLabel(for: pane.cwd),
                          gem: running > 0 ? Drop.good : nil,
                          gemHelp: running == 1 ? "1 call running" : "\(running) calls running",
                          onClose: { state.closeAgentTools() }) {
            HStack(spacing: 7) {
                if let asset = pane.agent.tool.markAsset,
                   let img = MarkImage.load(asset, template: pane.agent.tool.markIsTemplate) {
                    Image(nsImage: img)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(Theme.textSecondary)
                }
                DropContext(subtitle(running: running))
            }
        } controls: {
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
        }
    }

    private func subtitle(running: Int) -> String {
        var parts: [String] = []
        if let host = pane.remoteHost { parts.append(host) }
        let n = pane.toolRuns.count
        parts.append(n == 1 ? "1 call" : "\(n) calls")
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: "  ·  ")
    }

    private func link(_ title: String, _ kind: AgentToolKind,
                      action: @escaping () -> Void) -> some View {
        HistoryLink(title: title, kind: kind, action: action)
    }

    // MARK: Filters

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                chip("All", nil, pane.toolRuns.count)
                ForEach(kinds, id: \.kind) { entry in
                    chip(entry.kind.displayName, entry.kind, entry.count)
                }
            }
            .padding(.horizontal, Drop.inset)
            // Room for the selected chip's stroke inside the scroll clip.
            .padding(.vertical, 2)
        }
        .padding(.bottom, 18)
    }

    private func chip(_ title: String, _ kind: AgentToolKind?, _ count: Int) -> some View {
        DropFilterChip(title: title, count: count, selected: filter == kind) {
            withAnimation(Theme.Spring.snappy) { filter = kind }
            SoundEffects.shared.play(.toggle)
        }
    }

    // MARK: Rows

    private var content: some View {
        Group {
            if runs.isEmpty {
                DropStatement(symbol: "clock.arrow.circlepath",
                              title: "Nothing yet",
                              message: "Calls appear here as Claude works: shell, files, search, the web, sub-agents, and the tools it reaches for.")
            } else {
                DropBody(maxHeight: 540) {
                    DropWell {
                        ForEach(Array(runs.enumerated()), id: \.element.id) { i, run in
                            row(run, index: i)
                        }
                    }
                }
            }
        }
        // A filter is a different list, not an edit of this one: the rows
        // leave together and the new set surfaces in order.
        .id(filter)
        .transition(.liquidSwap)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: filter)
    }

    private func toggle(_ run: AgentToolRun) {
        withAnimation(Theme.Spring.snappy) {
            if expanded.contains(run.id) { expanded.remove(run.id) } else { expanded.insert(run.id) }
        }
        SoundEffects.shared.play(.toggle)
    }

    private func row(_ run: AgentToolRun, index: Int) -> some View {
        let isOpen = expanded.contains(run.id)
        let isHover = hovered == run.id
        return VStack(alignment: .leading, spacing: 10) {
            Button { toggle(run) } label: {
                HStack(alignment: .top, spacing: 14) {
                    AgentToolGlyph(kind: run.kind,
                                   color: Theme.textPrimary.opacity(run.isRunning || isOpen ? 1 : 0.8),
                                   size: 20)
                        .frame(width: 24, height: 24)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(run.kind.displayName)
                                .font(Drop.display(13))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Self.relative.localizedString(for: run.startedAt, relativeTo: Date()))
                                .font(Drop.mono(9.5))
                                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                            Spacer(minLength: 4)
                            verdict(run)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                        }
                        Text(run.command ?? run.kind.displayName)
                            .font(Drop.mono(11.5))
                            .foregroundStyle(Theme.textPrimary.opacity(0.72))
                            .lineLimit(isOpen ? 6 : 2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { outputBox(run).transition(.liquidSwap) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.selectionFill.opacity(isOpen || isHover ? 1 : 0))
        )
        .offset(x: isHover && !isOpen ? 3 : 0)
        .onHover { hovered = $0 ? run.id : (hovered == run.id ? nil : hovered) }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHover)
        .rollUp(delay: 0.12 + Double(min(index, 12)) * 0.035)
    }

    /// Elapsed while running, duration and outcome once done.
    @ViewBuilder
    private func verdict(_ run: AgentToolRun) -> some View {
        if run.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Drop.good)
                        .frame(width: 5, height: 5)
                        .opacity(Int(tl.date.timeIntervalSinceReferenceDate) % 2 == 0 ? 1 : 0.35)
                    Text(Self.duration(tl.date.timeIntervalSince(run.startedAt)))
                        .font(Drop.mono(10, .medium))
                        .foregroundStyle(Drop.good)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Drop.good.opacity(0.13)))
                .overlay(Capsule().strokeBorder(Drop.good.opacity(0.22), lineWidth: 0.5))
            }
        } else {
            HStack(spacing: 7) {
                if let d = run.duration {
                    Text(Self.duration(d))
                        .font(Drop.mono(10, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                if run.failed {
                    DropChip(text: "failed", symbol: "xmark", tint: Drop.bad)
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
                .font(Drop.mono(10.5))
                .lineSpacing(2)
                .foregroundStyle(dim ? Theme.textSecondary : Theme.textPrimary.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(maxHeight: 190)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.recessedWash))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(run.failed ? AnyShapeStyle(Drop.bad.opacity(0.35))
                                             : AnyShapeStyle(Theme.stroke),
                                  lineWidth: 0.5))
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

/// Jump from the record to the cockpit a call belongs to. Carries the tool's
/// own glyph, which an SF Symbol button can't.
private struct HistoryLink: View {
    let title: String
    let kind: AgentToolKind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AgentToolGlyph(kind: kind, color: Theme.textPrimary, size: 11)
                Text(title)
                    .font(Drop.display(11, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(hovering ? Theme.strokeStrong : Theme.selectionFill))
            .overlay(Capsule().strokeBorder(
                hovering ? AnyShapeStyle(Drop.sheen) : AnyShapeStyle(Theme.stroke),
                lineWidth: hovering ? 1 : 0.5))
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovering)
    }
}
