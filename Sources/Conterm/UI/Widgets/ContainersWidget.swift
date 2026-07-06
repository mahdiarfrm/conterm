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
        var containers: [Container]
    }

    @Published private(set) var groups: [RuntimeGroup] = []
    /// Total running across reachable runtimes; nil when none answered.
    @Published private(set) var total: Int?

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var loading = false

    /// Label + resolved CLI path for each runtime present on disk.
    /// `apple` marks Apple's `container` CLI, which lists as JSON
    /// instead of the docker-style template the other three share.
    nonisolated private static let runtimes: [(label: String, path: String, apple: Bool)] =
        [("Docker", "docker", false), ("Podman", "podman", false),
         ("containerd", "nerdctl", false), ("Apple", "container", true)]
            .compactMap { entry in
                locateWidgetTool(entry.1).map { (entry.0, $0, entry.2) }
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
                    found.append(RuntimeGroup(name: rt.label, containers: containers))
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
                    ContainersPopover(model: model)
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

    var body: some View {
        WidgetPopoverChrome(title: "Containers", width: 280, trailing: {
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.45, green: 0.85, blue: 0.55))
                        .frame(width: 5, height: 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name)
                            .font(.system(size: 12, weight: .medium,
                                          design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 0) {
                            Text(c.image)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !c.status.isEmpty {
                                Text("  ·  \(c.status)")
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }
}
