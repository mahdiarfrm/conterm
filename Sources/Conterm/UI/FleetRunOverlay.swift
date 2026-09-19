import SwiftUI

/// Fleet run: pick hosts, type one command, get a tab with a pane per
/// host running it over ssh. Hosts come from recent ssh targets and
/// ~/.ssh/config; selection order decides pane order, and each picked row
/// wears its position. A `Drop` card: masthead, the command capsule, the
/// host wells, and a footer that counts the selection beside the action.
struct FleetRunOverlay: View {
    @EnvironmentObject var state: AppState

    @State private var command = ""
    /// Selection keeps click order — it becomes the pane order.
    @State private var selected: [String] = []
    @State private var rows: [Row] = []
    @FocusState private var commandFocused: Bool

    struct Row: Identifiable {
        let target: String
        let detail: String?
        let isRecent: Bool
        var id: String { target }
    }

    var body: some View {
        BriefingCard(width: 580) {
            VStack(spacing: 0) {
                DropHeader(eyebrow: "Fleet", title: "Fleet run",
                           onClose: { state.closeFleetRun() }) {
                    DropContext("One command across many hosts — a pane per host.")
                }
                commandField
                hostList
                footer
            }
        }
        .onAppear {
            rows = Self.loadRows()
            // The field mounts with the card, under the forming drop, so
            // typing lands in it from the first keystroke.
            commandFocused = true
        }
    }

    private var commandField: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
            TextField("Command — leave empty to just connect", text: $command)
                .textFieldStyle(.plain)
                .font(Drop.mono(12.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($commandFocused)
                .onSubmit { runIfReady() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Capsule().fill(Theme.selectionFill))
        .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 0.75))
        .padding(.horizontal, Drop.inset)
        .padding(.bottom, 22)
        .rollUp(delay: 0.12)
    }

    @ViewBuilder
    private var hostList: some View {
        if rows.isEmpty {
            DropStatement(symbol: "antenna.radiowaves.left.and.right",
                          title: "No ssh targets yet",
                          message: "Connect to a host once, or add entries to ~/.ssh/config.")
        } else {
            let recents = rows.filter(\.isRecent)
            let others = rows.filter { !$0.isRecent }
            DropBody(maxHeight: 340) {
                if !recents.isEmpty {
                    DropSection(label: "Recent", count: recents.count, order: 0) {
                        DropWell {
                            ForEach(Array(recents.enumerated()), id: \.element.id) { i, row in
                                hostRow(row, index: i)
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    DropSection(label: "All hosts", count: others.count, order: 1) {
                        DropWell {
                            ForEach(Array(others.enumerated()), id: \.element.id) { i, row in
                                hostRow(row, index: recents.count + i)
                            }
                        }
                    }
                }
            }
        }
    }

    private func hostRow(_ row: Row, index: Int) -> some View {
        let order = selected.firstIndex(of: row.target)
        return DropRow(index: index, action: {
            SoundEffects.shared.play(.toggle)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if let order {
                    selected.remove(at: order)
                } else {
                    selected.append(row.target)
                }
            }
        }) {
            HStack(spacing: 12) {
                orderBadge(order)
                Text(row.target)
                    .font(Drop.display(12.5, order != nil ? .semibold : .medium))
                    .foregroundStyle(order != nil ? Theme.textPrimary : Theme.textPrimary.opacity(0.85))
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(Drop.mono(10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// An empty ring until picked, then the row's place in the pane order.
    private func orderBadge(_ order: Int?) -> some View {
        ZStack {
            Circle().strokeBorder(Theme.strokeStrong, lineWidth: 1)
                .opacity(order == nil ? 1 : 0)
            Circle().fill(Theme.textPrimary)
                .scaleEffect(order == nil ? 0.4 : 1)
                .opacity(order == nil ? 0 : 1)
            if let order {
                Text("\(order + 1)")
                    .font(Drop.mono(10, .bold))
                    .foregroundStyle(Theme.panelBed)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: 20, height: 20)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            DropFigure(value: Double(selected.count), font: Drop.display(28, .light))
            VStack(alignment: .leading, spacing: 2) {
                Text(selected.count == 1 ? "HOST PICKED" : "HOSTS PICKED")
                    .font(Drop.mono(8.5, .medium))
                    .kerning(1.6)
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                Text(selected.isEmpty ? "Pick the hosts to fan out to."
                                      : "One pane per host, in the order picked.")
                    .font(Drop.display(10.5, .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            DropButton(title: selected.count <= 1 ? "Run" : "Run on \(selected.count) hosts",
                       symbol: "play.fill", prominent: true, action: runIfReady)
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.4 : 1)
                .animation(.easeOut(duration: 0.15), value: selected.isEmpty)
        }
        .padding(.horizontal, Drop.inset)
        .padding(.bottom, 36)
        .rollUp(delay: 0.30)
    }

    private func runIfReady() {
        guard !selected.isEmpty else { return }
        SoundEffects.shared.play(.paletteConfirm)
        state.fleetRun(targets: selected, command: command)
    }

    /// Recent ssh targets first (shell history + palette clicks), then
    /// the remaining ~/.ssh/config hosts.
    @MainActor
    private static func loadRows() -> [Row] {
        let hosts = SSHHosts.loadAll()
        let hostByAlias = Dictionary(hosts.map { ($0.alias, $0) },
                                     uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [Row] = []
        for target in SSHHistory.recentTargets() + SSHRecents.load()
        where seen.insert(target).inserted {
            out.append(Row(target: target,
                           detail: hostByAlias[target]?.hostname,
                           isRecent: true))
        }
        for host in hosts where seen.insert(host.alias).inserted {
            out.append(Row(target: host.alias,
                           detail: host.hostname,
                           isRecent: false))
        }
        return out
    }
}
