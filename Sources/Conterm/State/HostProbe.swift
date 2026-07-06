import Foundation

/// Everything the Host Overview shows about a remote machine, gathered
/// by one non-interactive SSH round-trip. Optionals are "the host
/// doesn't have this" (no docker, no systemd, …) and their sections
/// simply don't render.
struct HostInfo: Sendable, Equatable {
    struct Disk: Sendable, Equatable {
        let mount: String
        let totalKB: Int
        let usedKB: Int
        var pct: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) : 0 }
    }
    struct Container: Sendable, Equatable {
        let name: String
        let image: String
        let status: String
    }
    struct Timer: Sendable, Equatable {
        let next: String
        let unit: String
    }

    var hostname = ""
    var fqdn: String?
    var os: String?
    var kernel: String?
    var arch: String?
    var uptime: String?
    var loadAvg: (Double, Double, Double)?
    var cores: Int?
    var memTotalMB: Int?
    var memAvailMB: Int?
    var disks: [Disk] = []
    var ips: [String] = []
    var containers: [Container]?
    var vms: [String]?
    var kubelet = false
    var kubeNodes: Int?
    var timers: [Timer] = []
    var cronEntries: Int?
    var failedUnits: Int?
    var failedNames: [String] = []
    var usersLoggedIn: Int?
    var rebootRequired = false
    /// "name  12.3  4.0" — comm, %cpu, %mem, busiest first.
    var topProcs: [(name: String, cpu: String, mem: String)] = []
    var listeningPorts: [String] = []
    /// journalctl -p err tail, pre-trimmed to "HH:MM:SS unit: message".
    var journalErrors: [String] = []
    /// dmesg err/warn tail (or journal kernel fallback).
    var kernelWarnings: [String] = []
    var lastLogins: [String] = []
    /// Debian update-notifier line, e.g. "42 updates can be applied…".
    var updatesAvailable: String?

    static func == (a: HostInfo, b: HostInfo) -> Bool {
        a.hostname == b.hostname && a.uptime == b.uptime
            && a.loadAvg?.0 == b.loadAvg?.0 && a.disks == b.disks
            && a.containers == b.containers && a.timers == b.timers
            && a.journalErrors == b.journalErrors
            && a.listeningPorts == b.listeningPorts
    }
}

/// Fetches and parses the overview for one SSH target. The collector is
/// a single POSIX-sh script sent over stdin — one round trip, every
/// probe individually guarded so a missing tool yields an empty section
/// instead of a failure. BatchMode keeps it non-interactive: if the
/// connection would prompt (password, unknown host key), it fails fast
/// with a readable error instead of hanging.
@MainActor
final class HostProbeModel: ObservableObject {
    enum Phase {
        case loading
        case loaded(HostInfo)
        case failed(String)
    }

    let target: String
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var fetchedAt: Date?
    /// True while a probe runs behind an already-shown snapshot.
    @Published private(set) var refreshing = false

    private var generation = 0

    /// Last good snapshot per target, kept for the app's lifetime —
    /// reopening a host shows it instantly (with its age in the header)
    /// while a fresh probe revalidates in the background.
    private static var snapshotCache: [String: (info: HostInfo, at: Date)] = [:]

    init(target: String) {
        self.target = target
        if let cached = Self.snapshotCache[target] {
            phase = .loaded(cached.info)
            fetchedAt = cached.at
        }
        refresh()
    }

    func refresh() {
        generation += 1
        let gen = generation
        let target = target
        if case .loaded = phase {
            refreshing = true
        } else {
            phase = .loading
        }
        Task.detached(priority: .userInitiated) {
            let result = Self.fetch(target: target)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.refreshing = false
                switch result {
                case .success(let raw):
                    let info = Self.parse(raw)
                    self.phase = .loaded(info)
                    self.fetchedAt = Date()
                    Self.snapshotCache[target] = (info, Date())
                case .failure(let message):
                    // A stale snapshot beats an error screen; the header
                    // age shows it isn't fresh.
                    if case .loaded = self.phase { return }
                    self.phase = .failed(message)
                }
            }
        }
    }

    // MARK: - Collector

    /// Marker-delimited so one stream carries every section. Each probe
    /// is guarded and `|| true`'d — the script must exit 0 on any box
    /// that has a POSIX sh, Linux or not.
    nonisolated private static let collector = #"""
    put() { printf '\n===conterm:%s===\n' "$1"; }
    put hostname; hostname 2>/dev/null || true
    put fqdn; hostname -f 2>/dev/null || true
    put os; ( . /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME" ) || sw_vers 2>/dev/null | head -2 | tr '\n' ' ' || true
    put kernel; uname -sr 2>/dev/null || true
    put arch; uname -m 2>/dev/null || true
    put uptime; uptime 2>/dev/null || true
    put loadavg; cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null || true
    put cores; nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true
    put mem; free -m 2>/dev/null || true
    put disk; df -Pk 2>/dev/null | awk 'NR>1 && $1 ~ /^\//' || true
    put ips; hostname -I 2>/dev/null || ifconfig 2>/dev/null | awk '/inet /{print $2}' || true
    put docker; command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null; true
    put vms; command -v virsh >/dev/null 2>&1 && virsh list --name 2>/dev/null; true
    put kubelet; systemctl is-active kubelet 2>/dev/null || systemctl is-active k3s 2>/dev/null || true
    put kubenodes; command -v kubectl >/dev/null 2>&1 && kubectl get nodes --no-headers 2>/dev/null | grep -c .; true
    put timers; systemctl list-timers --no-pager --no-legend 2>/dev/null | head -5 || true
    put cron; crontab -l 2>/dev/null | grep -Ev '^[[:space:]]*#|^[[:space:]]*$' | grep -c .; true
    put failed; systemctl --failed --no-legend --plain 2>/dev/null | grep -c .; true
    put failedlist; systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | head -4; true
    put users; who 2>/dev/null | grep -c .; true
    put reboot; [ -f /var/run/reboot-required ] && echo yes; true
    put procs; ps -eo comm,pcpu,pmem --sort=-pcpu 2>/dev/null | head -6 | tail -5; true
    put ports; { command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | tail -n +2 || netstat -tln 2>/dev/null | grep LISTEN; } | awk '{print $4}' | sort -u | head -12; true
    put journal; journalctl -p err -n 5 --no-pager --output=short 2>/dev/null | grep -v '^--' | tail -5; true
    put kernlog; { dmesg --level=err,warn 2>/dev/null || journalctl -k -p warning -n 8 --no-pager --output=short 2>/dev/null; } | grep -v '^--' | tail -4; true
    put lastlog; last -n 4 -w 2>/dev/null | grep -Ev '^wtmp|^$' | head -4; true
    put updates; grep -m1 'can be applied' /var/lib/update-notifier/updates-available 2>/dev/null; true
    put end
    """#

    private enum FetchResult: Sendable {
        case success(String)
        case failure(String)
    }

    nonisolated private static func fetch(target: String) -> FetchResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes",
                       "-o", "ConnectTimeout=6",
                       target, "sh"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        do { try p.run() } catch {
            return .failure("Couldn't launch ssh: \(error.localizedDescription)")
        }
        stdin.fileHandleForWriting.write(Data(collector.utf8))
        stdin.fileHandleForWriting.closeFile()

        // Watchdog: a wedged connection must not strand the task.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + 15, execute: watchdog)
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        let out = String(decoding: outData, as: UTF8.self)
        if out.contains("===conterm:hostname===") { return .success(out) }
        var err = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if err.contains("Permission denied") || err.contains("Host key verification") {
            err += "\n\nHost Overview connects non-interactively with your keys. If you log in as a different user, enter it below (e.g. root@\(target.split(separator: "@").last.map(String.init) ?? target))."
        }
        return .failure(err.isEmpty ? "No response from \(target)." : err)
    }

    // MARK: - Parse

    nonisolated private static func parse(_ raw: String) -> HostInfo {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("===conterm:"), line.hasSuffix("===") {
                current = String(line.dropFirst("===conterm:".count).dropLast(3))
                sections[current!] = []
            } else if let key = current, !line.isEmpty {
                sections[key, default: []].append(String(line))
            }
        }
        func first(_ key: String) -> String? {
            sections[key]?.first?.trimmingCharacters(in: .whitespaces)
        }
        func int(_ key: String) -> Int? { first(key).flatMap { Int($0) } }

        var info = HostInfo()
        info.hostname = first("hostname") ?? "unknown"
        info.fqdn = first("fqdn")
        if info.fqdn == info.hostname { info.fqdn = nil }
        info.os = first("os")
        info.kernel = first("kernel")
        info.arch = first("arch")
        info.uptime = first("uptime").map(prettyUptime)
        if let l = first("loadavg") {
            let nums = l.replacingOccurrences(of: "{", with: "")
                .replacingOccurrences(of: "}", with: "")
                .split(separator: " ").compactMap { Double($0) }
            if nums.count >= 3 { info.loadAvg = (nums[0], nums[1], nums[2]) }
        }
        info.cores = int("cores")
        if let mem = sections["mem"]?.first(where: { $0.hasPrefix("Mem:") }) {
            let f = mem.split(separator: " ").compactMap { Int($0) }
            // free -m: total used free shared buff/cache available
            if f.count >= 1 { info.memTotalMB = f[0] }
            if f.count >= 6 { info.memAvailMB = f[5] }
        }
        info.disks = (sections["disk"] ?? []).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 6, let total = Int(f[1]), let used = Int(f[2]),
                  total > 0 else { return nil }
            return HostInfo.Disk(mount: String(f[5]), totalKB: total, usedKB: used)
        }
        .sorted { $0.totalKB > $1.totalKB }
        // Dedupe bind-mount duplicates by mount point, keep the biggest few.
        var seenMounts = Set<String>()
        info.disks = info.disks.filter { seenMounts.insert($0.mount).inserted }
        if info.disks.count > 4 { info.disks = Array(info.disks.prefix(4)) }

        info.ips = (first("ips") ?? "")
            .split(separator: " ").map(String.init)
            .filter { $0 != "127.0.0.1" && $0 != "::1" && !$0.isEmpty }
        if sections["docker"] != nil, !(sections["docker"] ?? []).isEmpty {
            info.containers = (sections["docker"] ?? []).compactMap { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard let name = f.first, !name.isEmpty else { return nil }
                return HostInfo.Container(name: String(name),
                                          image: f.count > 1 ? String(f[1]) : "",
                                          status: f.count > 2 ? String(f[2]) : "")
            }
        }
        let vmNames = (sections["vms"] ?? []).filter { !$0.isEmpty }
        if !vmNames.isEmpty { info.vms = vmNames }
        info.kubelet = first("kubelet") == "active"
        if let n = int("kubenodes"), n > 0 { info.kubeNodes = n }
        info.timers = (sections["timers"] ?? []).compactMap { line in
            // list-timers --plain-ish columns: NEXT … LEFT LAST … UNIT ACTIVATES
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2,
                  let unit = f.first(where: { $0.hasSuffix(".timer") })
            else { return nil }
            let next = f.prefix(4).joined(separator: " ")
            return HostInfo.Timer(next: next, unit: String(unit))
        }
        info.cronEntries = int("cron")
        info.failedUnits = int("failed")
        info.failedNames = sections["failedlist"] ?? []
        info.usersLoggedIn = int("users")
        info.rebootRequired = first("reboot") == "yes"
        info.topProcs = (sections["procs"] ?? []).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3 else { return nil }
            let name = f.dropLast(2).joined(separator: " ")
            return (name: name, cpu: String(f[f.count - 2]),
                    mem: String(f[f.count - 1]))
        }
        info.listeningPorts = (sections["ports"] ?? [])
            .map { $0.replacingOccurrences(of: "*:", with: ":") }
        info.journalErrors = (sections["journal"] ?? []).map(trimJournalLine)
        info.kernelWarnings = (sections["kernlog"] ?? []).map { line in
            // dmesg keeps its "[ 1234.56]" stamp; journal fallback gets
            // the same trim as the error feed.
            line.hasPrefix("[") ? line : trimJournalLine(line)
        }
        info.lastLogins = sections["lastlog"] ?? []
        info.updatesAvailable = first("updates")
        return info
    }

    /// "Jul 06 19:20:01 host unit[pid]: msg" → "19:20:01 unit[pid]: msg".
    nonisolated private static func trimJournalLine(_ line: String) -> String {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count > 4 else { return line }
        return String(f[2]) + " " + f.dropFirst(4).joined(separator: " ")
    }

    /// "14:03:22 up 41 days,  2:11,  3 users, …" → "41 days, 2:11".
    nonisolated private static func prettyUptime(_ s: String) -> String {
        guard let upRange = s.range(of: "up ") else { return s }
        let parts = s[upRange.upperBound...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let head = parts.first else { return s }
        if head.contains("day"), parts.count > 1, parts[1].contains(":") {
            return head + ", " + parts[1]
        }
        return head
    }
}
