import SwiftUI

/// Fleet run: pick hosts, type one command, get a tab with a pane per
/// host running it over ssh. Hosts come from recent ssh targets and
/// ~/.ssh/config; selection order decides pane order.
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
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            commandField
            Divider().opacity(0.4)
            hostList
            Divider().opacity(0.4)
            footer
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
        .frame(width: 440)
        .onAppear {
            rows = Self.loadRows()
            commandFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Fleet run")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { state.closeFleetRun() } label: {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var commandField: some View {
        TextField("Command — leave empty to just connect",
                  text: $command)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .focused($commandFocused)
            .onSubmit { runIfReady() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private var hostList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let recents = rows.filter(\.isRecent)
                let others = rows.filter { !$0.isRecent }
                if !recents.isEmpty {
                    sectionHeader("RECENT")
                    ForEach(recents) { hostRow($0) }
                }
                if !others.isEmpty {
                    sectionHeader("ALL HOSTS")
                    ForEach(others) { hostRow($0) }
                }
                if rows.isEmpty {
                    Text("No ssh targets found — connect to a host once, or add entries to ~/.ssh/config.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(14)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 280)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .kerning(1.2)
            .foregroundStyle(Theme.textSecondary.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func hostRow(_ row: Row) -> some View {
        let index = selected.firstIndex(of: row.target)
        return Button {
            SoundEffects.shared.play(.toggle)
            if let index {
                selected.remove(at: index)
            } else {
                selected.append(row.target)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: index != nil
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(index != nil
                                     ? Theme.accent : Theme.textSecondary.opacity(0.6))
                Text(row.target)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if let index {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text(selected.isEmpty
                 ? "Pick the hosts to fan out to."
                 : "One pane per host, in the order picked.")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            // Theme.accent is near-white on dark glass — as a fill it
            // would swallow white text; the ssh blue holds contrast in
            // both appearances.
            Button(action: runIfReady) {
                Text(selected.count <= 1
                     ? "Run"
                     : "Run on \(selected.count) hosts")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected.isEmpty ? Theme.textSecondary : .white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(selected.isEmpty
                                               ? AnyShapeStyle(Theme.stroke)
                                               : AnyShapeStyle(Theme.sshAccentDeep)))
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
