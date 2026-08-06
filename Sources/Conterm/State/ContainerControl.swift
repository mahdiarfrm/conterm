import Foundation

/// Which container CLI a host answers to.
///
/// Detected once per host probe and carried on `HostInfo`, because the verbs
/// are not interchangeable: running `docker` on a machine that only has
/// `podman` fails with nothing the map could show, and Apple's `container`
/// names half of them differently. Whatever listed a host's containers is also
/// what acts on them.
///
/// Deliberately not `crictl`: a machine whose only runtime is the CRI socket is
/// a Kubernetes node, and its containers read far better through the cluster —
/// see the kube drill, which reaches them with the same `kubectl` it already
/// uses for nodes and pods.
enum ContainerRuntime: String, Sendable, Codable, Equatable {
    case docker, podman, nerdctl
    /// Apple's `container` on macOS.
    case apple = "container"

    /// The executable's name, which is also how the probe reports it.
    var tool: String { rawValue }

    var displayName: String {
        switch self {
        case .docker:  return "Docker"
        case .podman:  return "Podman"
        case .nerdctl: return "containerd"
        case .apple:   return "container"
        }
    }
}

/// One thing you can do to a container. `shell` is the odd one out: it needs a
/// TTY, so it is typed into a real terminal rather than captured.
enum ContainerAction: String, CaseIterable, Sendable {
    case start, stop, restart, remove, logs, stats, shell

    var isDestructive: Bool { self == .remove }

    var label: String {
        switch self {
        case .start:   return "Start"
        case .stop:    return "Stop"
        case .restart: return "Restart"
        case .remove:  return "Remove"
        case .logs:    return "Logs"
        case .stats:   return "Stats"
        case .shell:   return "Shell"
        }
    }

    var icon: String {
        switch self {
        case .start:   return "play.fill"
        case .stop:    return "stop.fill"
        case .restart: return "arrow.clockwise"
        case .remove:  return "trash"
        case .logs:    return "text.alignleft"
        case .stats:   return "gauge.with.dots.needle.33percent"
        case .shell:   return "terminal"
        }
    }
}

extension ContainerRuntime {
    /// The remote shell line for one action, or nil where the runtime has no
    /// answer for it.
    ///
    /// Docker, Podman and nerdctl share the Docker CLI surface. Apple's
    /// `container` uses `delete` for removal and reports no resource use at all,
    /// so `stats` is absent there rather than faked. nerdctl runs against its
    /// default containerd namespace — the `k8s.io` namespace belongs to the
    /// cluster, and reaching it from here would show a node's pods twice under
    /// two different sets of verbs.
    func command(_ action: ContainerAction, container name: String) -> String? {
        let c = shellQuote(name)
        switch (self, action) {
        case (.apple, .start):    return "container start \(c)"
        case (.apple, .stop):     return "container stop \(c)"
        case (.apple, .restart):  return "container stop \(c) && container start \(c)"
        case (.apple, .remove):   return "container delete \(c)"
        // stderr is where a container's own logging usually goes, and it would
        // otherwise be dropped on the way back, reading as a silent container.
        case (.apple, .logs):     return "container logs \(c) 2>&1 | tail -n 400"
        case (.apple, .stats):    return nil
        case (.apple, .shell):    return "container exec -it \(c) sh"
        case (_, .start):         return "\(tool) start \(c)"
        case (_, .stop):          return "\(tool) stop \(c)"
        case (_, .restart):       return "\(tool) restart \(c)"
        case (_, .remove):        return "\(tool) rm -f \(c)"
        case (_, .logs):          return "\(tool) logs --tail 400 \(c) 2>&1"
        case (_, .stats):
            return "\(tool) stats --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}' \(c)"
        case (_, .shell):         return "\(tool) exec -it \(c) sh"
        }
    }

    /// Whether this runtime can answer an action at all — what the UI offers.
    func supports(_ action: ContainerAction) -> Bool {
        command(action, container: "x") != nil
    }

    func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Acting on a host's containers, and the two read-only views that go with it.
///
/// Every action is one non-interactive SSH round trip. Nothing is polled: a
/// container's stats and logs are fetched when you ask for them, and a state
/// change tells the caller to re-probe the host rather than keeping a second
/// copy of the truth here.
@MainActor
final class ContainerControl: ObservableObject {
    static let shared = ContainerControl()

    struct Stats: Equatable {
        var cpu: String
        var memory: String
    }

    /// "host/container" → last readings.
    @Published private(set) var stats: [String: Stats] = [:]
    @Published private(set) var logs: [String: String] = [:]
    /// Actions in flight, so a button can't be pressed twice.
    @Published private(set) var busy: Set<String> = []
    /// "host/container" → why the last action or fetch came back empty.
    @Published private(set) var failures: [String: String] = [:]

    private init() {}

    static func key(_ host: String, _ container: String) -> String { host + "/" + container }

    func isBusy(host: String, container: String) -> Bool {
        busy.contains(Self.key(host, container))
    }
    func failure(host: String, container: String) -> String? {
        failures[Self.key(host, container)]
    }
    func stats(host: String, container: String) -> Stats? {
        stats[Self.key(host, container)]
    }
    func log(host: String, container: String) -> String? {
        logs[Self.key(host, container)]
    }

    /// Run a state-changing action. Returns once the runtime has answered, so
    /// the caller can re-probe the host straight after — the map's idea of what
    /// is running comes from the probe, not from a second copy kept here.
    func perform(_ action: ContainerAction, container name: String, host: String,
                 runtime: ContainerRuntime) async {
        guard let line = runtime.command(action, container: name) else { return }
        let key = Self.key(host, name)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        failures[key] = nil

        let out = await Task.detached(priority: .userInitiated) {
            Self.ssh(host: host, line: line + " 2>&1")
        }.value

        busy.remove(key)
        // The CLI is the authority on what went wrong, so its own words are what
        // gets shown — "no such container", "permission denied".
        if let out, !Self.looksLikeFailure(out) {
            failures[key] = nil
        } else {
            failures[key] = Self.trimError(out)
                ?? "\(runtime.displayName) didn't answer on \(host)"
        }
    }

    /// One-shot resource use. Cheap enough to ask for when a panel opens, far
    /// too expensive to poll across a fleet.
    ///
    /// Reports like any other action: `docker stats` wants a running container
    /// and a reachable daemon, and when it has neither the honest answer is to
    /// say so. Silently leaving the rows blank made the verb look inert.
    func loadStats(container name: String, host: String, runtime: ContainerRuntime) {
        guard let line = runtime.command(.stats, container: name) else { return }
        let key = Self.key(host, name)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        failures[key] = nil
        Task.detached(priority: .userInitiated) {
            let out = Self.ssh(host: host, line: line + " 2>&1")
            await MainActor.run {
                self.busy.remove(key)
                if let parsed = out.flatMap(Self.parseStats) {
                    self.stats[key] = parsed
                    self.failures[key] = nil
                } else {
                    self.failures[key] = Self.trimError(out)
                        ?? "\(runtime.displayName) reported no stats for \(name)"
                }
            }
        }
    }

    func loadLogs(container name: String, host: String, runtime: ContainerRuntime) {
        guard let line = runtime.command(.logs, container: name) else { return }
        let key = Self.key(host, name)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task.detached(priority: .userInitiated) {
            let out = Self.ssh(host: host, line: line)
            await MainActor.run {
                self.busy.remove(key)
                self.logs[key] = (out?.isEmpty == false) ? out : "No output."
            }
        }
    }

    // MARK: - Transport

    nonisolated private static func ssh(host: String, line: String) -> String? {
        runWidgetTool("/usr/bin/ssh", [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            OrbitEngine.cleanHost(host), line,
        ])
    }

    /// `docker start` echoes the container's name on success, so an exit code of
    /// zero with an error-shaped line is the case worth catching.
    nonisolated private static func looksLikeFailure(_ out: String) -> Bool {
        let s = out.lowercased()
        return s.contains("error") || s.contains("no such") || s.contains("permission denied")
            || s.contains("cannot connect to the docker daemon")
    }

    nonisolated private static func trimError(_ out: String?) -> String? {
        guard let out else { return nil }
        let line = out.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return nil }
        return String(line).replacingOccurrences(of: "Error response from daemon: ", with: "")
    }

    /// `CPU%<TAB>used / limit`.
    nonisolated static func parseStats(_ out: String) -> Stats? {
        guard let line = out.split(separator: "\n").first else { return nil }
        let f = line.components(separatedBy: "\t")
        guard f.count >= 2 else { return nil }
        let cpu = f[0].trimmingCharacters(in: .whitespaces)
        let mem = f[1].trimmingCharacters(in: .whitespaces)
        guard !cpu.isEmpty else { return nil }
        return Stats(cpu: cpu, memory: mem)
    }
}
