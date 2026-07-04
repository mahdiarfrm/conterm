import AppKit
import SwiftUI

/// Where am I pointed: the active kubectl context plus the running Docker
/// container count. The kube side reads the config file directly (no
/// kubectl needed) and re-parses only when its mtime moves; the docker
/// side shells out to the CLI on a slow clock. Hidden when neither
/// exists on this machine.
@MainActor
final class ContextsModel: ObservableObject {
    struct Snapshot: Equatable {
        var kubeContext: String?
        var dockerRunning: Int?

        var isEmpty: Bool { kubeContext == nil && dockerRunning == nil }
        /// Contexts that deserve a red flag before a destructive command.
        var kubeDanger: Bool {
            kubeContext?.lowercased().contains("prod") ?? false
        }
    }

    @Published private(set) var snap = Snapshot()

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var loading = false
    private var kubeMTime: Date?
    private var lastDockerAt: CFTimeInterval = 0

    /// Docker spawns a real subprocess (and the daemon may be slow), so
    /// it polls far less often than the file-stat kube check.
    private static let dockerEvery: CFTimeInterval = 30
    nonisolated private static let dockerPath = locateWidgetTool("docker")

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
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 1
        timer = t
        tick()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        refreshKube()
        let now = CACurrentMediaTime()
        if Self.dockerPath != nil, now - lastDockerAt >= Self.dockerEvery {
            lastDockerAt = now
            refreshDocker()
        }
    }

    // MARK: Kube

    nonisolated private static func kubeConfigPath() -> String {
        if let env = ProcessInfo.processInfo.environment["KUBECONFIG"],
           let first = env.split(separator: ":").first, !first.isEmpty {
            return String(first)
        }
        return "\(NSHomeDirectory())/.kube/config"
    }

    private func refreshKube() {
        let path = Self.kubeConfigPath()
        let mtime = (try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate]) as? Date
        guard mtime != kubeMTime || (mtime != nil && snap.kubeContext == nil) else {
            if mtime == nil, snap.kubeContext != nil { snap.kubeContext = nil }
            return
        }
        kubeMTime = mtime
        guard mtime != nil,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            snap.kubeContext = nil
            return
        }
        snap.kubeContext = Self.currentContext(in: text)
    }

    /// `current-context: <name>` at top level; values may be quoted.
    nonisolated private static func currentContext(in yaml: String) -> String? {
        for line in yaml.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("current-context:") else { continue }
            let value = line.dropFirst("current-context:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: Docker

    private func refreshDocker() {
        guard !loading, let docker = Self.dockerPath else { return }
        loading = true
        Task.detached(priority: .utility) {
            // One line per running container; nil when the daemon is down.
            let out = runWidgetTool(docker, ["ps", "-q"])
            let count = out.map {
                $0.split(whereSeparator: \.isNewline).count
            }
            await MainActor.run {
                self.loading = false
                if self.snap.dockerRunning != count { self.snap.dockerRunning = count }
            }
        }
    }
}

struct ContextsWidget: View {
    @StateObject private var model = ContextsModel()
    var compact: Bool

    var body: some View {
        Group {
            if !model.snap.isEmpty {
                WidgetShell(compact: compact, help: help, onTap: {}) {
                    HStack(spacing: compact ? 4 : 5) {
                        if let ctx = model.snap.kubeContext {
                            widgetIcon("helm", compact: compact)
                            Text(ctx)
                                .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                              design: .rounded))
                                .foregroundStyle(model.snap.kubeDanger
                                                 ? Color.red.opacity(0.95)
                                                 : Theme.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: compact ? 70 : 110)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if model.snap.kubeContext != nil, model.snap.dockerRunning != nil {
                            widgetChipDivider()
                        }
                        if let running = model.snap.dockerRunning {
                            widgetIcon("shippingbox", compact: compact)
                            Text("\(running)")
                                .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                              design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var help: String {
        var parts: [String] = []
        if let ctx = model.snap.kubeContext {
            parts.append("kubectl · \(ctx)\(model.snap.kubeDanger ? " ⚠ production" : "")")
        }
        if let running = model.snap.dockerRunning {
            parts.append("docker · \(running) running")
        }
        return parts.joined(separator: "  ·  ")
    }
}
