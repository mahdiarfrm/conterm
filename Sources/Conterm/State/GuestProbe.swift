import Foundation

/// Detail for one libvirt guest, fetched only when you open its panel.
///
/// The host probe deliberately reports guests as name + state: anything more
/// needs a `virsh dominfo` **per guest**, which would turn one SSH round trip
/// per host into one per VM on every refresh. So the expensive part is lazy —
/// a single guest, on demand, cached until you ask again.
@MainActor
final class GuestProbe: ObservableObject {
    static let shared = GuestProbe()

    struct Detail: Equatable {
        var state: String?
        var vcpus: String?
        /// Current and maximum allocation, in MiB.
        var memoryMB: Int?
        var maxMemoryMB: Int?
        var autostart: String?
        var persistent: String?
        var osType: String?
        /// Addresses from `domifaddr`, when the guest agent reports them.
        var addresses: [String] = []

        var isEmpty: Bool {
            state == nil && vcpus == nil && memoryMB == nil
                && maxMemoryMB == nil && addresses.isEmpty
        }
    }

    /// "host/guest" → what we know.
    @Published private(set) var details: [String: Detail] = [:]
    @Published private(set) var loading: Set<String> = []
    /// "host/guest" → why the lookup came back with nothing.
    @Published private(set) var failures: [String: String] = [:]

    private var fetchedAt: [String: Date] = [:]

    private init() {}

    static func key(_ host: String, _ guest: String) -> String { host + "/" + guest }

    func detail(host: String, guest: String) -> Detail? { details[Self.key(host, guest)] }
    func isLoading(host: String, guest: String) -> Bool { loading.contains(Self.key(host, guest)) }
    func failure(host: String, guest: String) -> String? { failures[Self.key(host, guest)] }

    /// Fetch one guest's detail. Re-reads at most every 10 s unless forced, so
    /// leaving a panel open doesn't hammer the host.
    func load(host: String, guest: String, force: Bool = false) {
        let key = Self.key(host, guest)
        guard !loading.contains(key) else { return }
        if !force, let at = fetchedAt[key], Date().timeIntervalSince(at) < 10 { return }
        fetchedAt[key] = Date()
        loading.insert(key)

        Task.detached(priority: .userInitiated) {
            // One connection, both queries: dominfo always answers, domifaddr
            // only when the guest agent is running — its failure is not the
            // lookup's failure, so it's separated by a marker rather than
            // allowed to poison the exit status.
            let script = "virsh dominfo -- \(Self.shellQuote(guest)); "
                       + "echo '#ADDR#'; "
                       + "virsh domifaddr -- \(Self.shellQuote(guest)) 2>/dev/null || true"
            let out = runWidgetTool("/usr/bin/ssh", [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                OrbitEngine.cleanHost(host), script,
            ])
            let parsed = out.map(Self.parse)
            await MainActor.run {
                self.loading.remove(key)
                if let parsed, !parsed.isEmpty {
                    self.details[key] = parsed
                    self.failures[key] = nil
                } else {
                    self.failures[key] = out == nil
                        ? "couldn't reach \(host)"
                        : "virsh reported nothing for this guest"
                }
            }
        }
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `virsh dominfo` is `Key:   value` lines; `domifaddr` is a table whose
    /// last column carries `addr/prefix`.
    nonisolated static func parse(_ out: String) -> Detail {
        var d = Detail()
        let parts = out.components(separatedBy: "#ADDR#")

        for line in parts[0].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "state":       d.state = value
            case "cpu(s)":      d.vcpus = value
            case "max memory":  d.maxMemoryMB = Self.mib(value)
            case "used memory": d.memoryMB = Self.mib(value)
            case "autostart":   d.autostart = value
            case "persistent":  d.persistent = value
            case "os type":     d.osType = value
            default:            break
            }
        }

        if parts.count > 1 {
            for line in parts[1].split(separator: "\n") {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                // Skip the header and the separator rule.
                guard let last = f.last, last.contains("."), last.contains("/") else { continue }
                let addr = last.split(separator: "/").first.map(String.init) ?? String(last)
                if !addr.isEmpty, !d.addresses.contains(addr) { d.addresses.append(addr) }
            }
        }
        return d
    }

    /// `virsh` reports memory in KiB.
    nonisolated static func mib(_ value: String) -> Int? {
        let n = value.split(separator: " ").first.flatMap { Int($0) }
        guard let n else { return nil }
        return value.lowercased().contains("kib") ? n / 1024 : n
    }
}
