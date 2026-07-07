import AppKit
import SwiftUI

/// Running containers across every runtime on the machine — Docker,
/// Podman, and containerd (through nerdctl, which mirrors the docker
/// CLI). The pill shows the total; the popover groups containers by
/// runtime. A runtime is listed only while its CLI exists and its
/// daemon answers, so a stopped Docker Desktop simply drops out.
@MainActor
final class ContainerRuntimesModel: ObservableObject {
    struct Container: Equatable {
        let name: String
        let image: String
        let status: String
    }
    struct RuntimeGroup: Identifiable, Equatable {
        var id: String { name }
        let name: String
        /// CLI command word typed into panes (docker / podman /
        /// nerdctl / container) — the shell resolves it, so pane
        /// commands stay readable.
        let cli: String
        /// Resolved binary path for background actions (restart).
        let path: String
        /// Apple's `container` CLI: swift-argument-parser flags (no
        /// combined -it) and a different logs syntax.
        let apple: Bool
        var containers: [Container]
    }

    @Published private(set) var groups: [RuntimeGroup] = []
    /// Total running across reachable runtimes; nil when none answered.
    @Published private(set) var total: Int?

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var loading = false

    /// Label + CLI + resolved path for each runtime present on disk.
    /// `apple` marks Apple's `container` CLI, which lists as JSON
    /// instead of the docker-style template the other three share.
    nonisolated private static let runtimes: [(label: String, cli: String,
                                               path: String, apple: Bool)] =
        [("Docker", "docker", false), ("Podman", "podman", false),
         ("containerd", "nerdctl", false), ("Apple", "container", true)]
            .compactMap { entry in
                locateWidgetTool(entry.1).map { (entry.0, entry.1, $0, entry.2) }
            }

    init() {
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        inactiveObs = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if NSApp?.isActive ?? true { start() }
    }

    isolated deinit {
        timer?.invalidate()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    /// External nudge after a mutating action (restart): re-list soon,
    /// giving the daemon a moment to settle.
    func poke(after seconds: Double = 1.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Task { @MainActor in self.refresh() }
        }
    }

    private func start() {
        guard !Self.runtimes.isEmpty, timer == nil else { return }
        // Each poll spawns one subprocess per runtime (and a daemon may
        // be slow to answer), so the clock stays lazy.
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 5
        timer = t
        refresh()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        guard !loading, !Self.runtimes.isEmpty else { return }
        loading = true
        Task.detached(priority: .utility) {
            var found: [RuntimeGroup] = []
            for rt in Self.runtimes {
                let containers: [Container]?
                if rt.apple {
                    containers = runWidgetTool(rt.path, ["ls", "--format", "json"])
                        .flatMap(Self.parseAppleContainers)
                } else {
                    // docker/podman/nerdctl share the ps template syntax;
                    // a dead daemon exits non-zero and drops the runtime.
                    containers = runWidgetTool(rt.path, ["ps", "--format",
                        "{{.Names}}\t{{.Image}}\t{{.Status}}"]).map { out in
                        out.split(whereSeparator: \.isNewline).compactMap { line in
                            let f = line.split(separator: "\t",
                                               omittingEmptySubsequences: false)
                            guard let name = f.first, !name.isEmpty else { return nil }
                            return Container(name: String(name),
                                             image: f.count > 1 ? String(f[1]) : "",
                                             status: f.count > 2 ? String(f[2]) : "")
                        }
                    }
                }
                if let containers {
                    found.append(RuntimeGroup(name: rt.label, cli: rt.cli,
                                              path: rt.path, apple: rt.apple,
                                              containers: containers))
                }
            }
            let groups = found
            await MainActor.run {
                self.loading = false
                let total = groups.isEmpty ? nil
                    : groups.reduce(0) { $0 + $1.containers.count }
                if self.total != total { self.total = total }
                if self.groups != groups { self.groups = groups }
            }
        }
    }
}

extension ContainerRuntimesModel {
    /// Apple's `container ls --format json`: entries nest identity under
    /// `configuration` (id + image reference) with a top-level status.
    /// Field names are matched tolerantly — flat `id`/`image` variants
    /// parse too — and non-running rows are dropped in case an all-list
    /// ever comes back.
    nonisolated static func parseAppleContainers(_ out: String) -> [Container]? {
        guard let data = out.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data))
                as? [[String: Any]] else { return nil }
        return arr.compactMap { obj in
            let cfg = obj["configuration"] as? [String: Any]
            guard let name = (cfg?["id"] as? String) ?? (obj["id"] as? String),
                  !name.isEmpty else { return nil }
            let status = ((obj["status"] as? String) ?? "").lowercased()
            if !status.isEmpty, status != "running" { return nil }
            var image = ""
            if let img = cfg?["image"] as? [String: Any] {
                image = (img["reference"] as? String) ?? ""
            } else if let s = (cfg?["image"] as? String) ?? (obj["image"] as? String) {
                image = s
            }
            return Container(name: name, image: image,
                             status: status.isEmpty ? "" : status)
        }
    }
}

struct ContainersWidget: View {
    @StateObject private var model = ContainerRuntimesModel()
    @EnvironmentObject private var state: AppState
    var compact: Bool
    @State private var showingPopover = false

    var body: some View {
        Group {
            if let total = model.total {
                WidgetShell(compact: compact,
                            help: help(total),
                            onTap: {
                                showingPopover.toggle()
                                SoundEffects.shared.play(.toggle)
                            }) {
                    HStack(spacing: compact ? 4 : 5) {
                        widgetIcon("shippingbox", compact: compact)
                        Text("\(total)")
                            .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                    }
                }
                .popover(isPresented: $showingPopover, arrowEdge: .top) {
                    // Environment objects don't reliably cross into the
                    // popover's window — hand AppState over explicitly.
                    ContainersPopover(model: model, state: state)
                }
            }
        }
    }

    private func help(_ total: Int) -> String {
        let names = model.groups.map(\.name).joined(separator: ", ")
        return "containers · \(total) running (\(names)) — click for the list"
    }
}

private struct ContainersPopover: View {
    @ObservedObject var model: ContainerRuntimesModel
    let state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WidgetPopoverChrome(title: "Containers", width: 300, trailing: {
            widgetPopoverChip("\(model.total ?? 0) running")
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups) { group in
                        runtimeSection(group)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 300)
        }
    }

    @ViewBuilder
    private func runtimeSection(_ group: ContainerRuntimesModel.RuntimeGroup) -> some View {
        Text(group.name.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .kerning(1.2)
            .foregroundStyle(Theme.textSecondary.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 3)
        if group.containers.isEmpty {
            Text("None running")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        } else {
            ForEach(group.containers, id: \.name) { c in
                ContainerRow(container: c, group: group,
                             shellIn: { openShell(group, c) },
                             tailLogs: { openLogs(group, c) },
                             restart: { restart(group, c) })
            }
        }
    }

    // MARK: Actions

    private func openShell(_ group: ContainerRuntimesModel.RuntimeGroup,
                           _ c: ContainerRuntimesModel.Container) {
        // Apple's CLI (swift-argument-parser) needs its short flags split.
        let cmd = group.apple
            ? "\(group.cli) exec -i -t \(c.name) sh"
            : "\(group.cli) exec -it \(c.name) sh"
        SoundEffects.shared.play(.click)
        dismiss()
        state.openTabRunning(command: cmd, title: c.name)
    }

    private func openLogs(_ group: ContainerRuntimesModel.RuntimeGroup,
                          _ c: ContainerRuntimesModel.Container) {
        let cmd = group.apple
            ? "\(group.cli) logs --follow \(c.name)"
            : "\(group.cli) logs -f --tail 200 \(c.name)"
        SoundEffects.shared.play(.click)
        dismiss()
        state.openTabRunning(command: cmd, title: "\(c.name) logs")
    }

    private func restart(_ group: ContainerRuntimesModel.RuntimeGroup,
                         _ c: ContainerRuntimesModel.Container) {
        SoundEffects.shared.play(.click)
        let path = group.path
        let name = c.name
        Task.detached(priority: .utility) {
            _ = runWidgetTool(path, ["restart", name])
        }
        model.poke(after: 2)
    }
}

/// One container with hover actions: shell into it, tail its logs
/// (each opens a new tab running the command), restart it in the
/// background. Apple's CLI has no restart verb, so that action hides.
private struct ContainerRow: View {
    let container: ContainerRuntimesModel.Container
    let group: ContainerRuntimesModel.RuntimeGroup
    let shellIn: () -> Void
    let tailLogs: () -> Void
    let restart: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(Color(red: 0.45, green: 0.85, blue: 0.55))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text(container.image)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !container.status.isEmpty {
                        Text("  ·  \(container.status)")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if hovering {
                HStack(spacing: 2) {
                    action("terminal", help: "Shell into \(container.name)",
                           run: shellIn)
                    action("text.alignleft", help: "Tail logs", run: tailLogs)
                    if !group.apple {
                        action("arrow.clockwise", help: "Restart", run: restart)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(hovering ? Theme.selectionFill : .clear)
        .onHover { hovering = $0 }
    }

    private func action(_ symbol: String, help: String,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
