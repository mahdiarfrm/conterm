import SwiftUI

/// Host Overview: one glass card that answers "how is this machine?"
/// in a glance. No boxed sub-cards — information sits directly on the
/// glass as typographic bands separated by hairlines: identity, vitals
/// (load / memory / storage), workloads, then network / schedule /
/// health. A status gem beside the hostname sums the whole machine.
/// Bands the host doesn't have simply don't render.
struct HostOverviewOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var prefs: Preferences
    @StateObject private var probe: HostProbeModel
    @State private var retryTarget = ""
    /// True once the spawn animation has settled. The live material
    /// only mounts at rest — an NSGlassEffectView ignores SwiftUI's
    /// animated blur/opacity, so animating over it would pop; the
    /// condense-from-blur plays entirely against the solid bed.
    let glassLive: Bool

    init(target: String, glassLive: Bool) {
        self.glassLive = glassLive
        _probe = StateObject(wrappedValue: HostProbeModel(target: target))
    }

    var body: some View {
        BriefingCard(glassLive: glassLive) {
            VStack(spacing: 0) {
                header
                switch probe.phase {
                case .loading: loading
                case .failed(let message): failed(message)
                case .loaded(let info): content(info)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    statusGem
                    Text(headline)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack(spacing: 6) {
                    if case .loaded(let info) = probe.phase,
                       let badge = Self.distroBadge(info.os) {
                        badge
                    }
                    Text(subheadline)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if case .loaded = probe.phase, let at = probe.fetchedAt {
                Text(Self.relative.localizedString(for: at, relativeTo: Date()))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            if probe.refreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                Button {
                    probe.refresh()
                    SoundEffects.shared.play(.click)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Refresh")
            }
            Button { state.closeHostOverview() } label: {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    /// One dot for the whole machine. The server answered, so it IS
    /// running — green unless something wants attention. Amber covers
    /// maintenance signals (failed units, reboot, near-full memory or
    /// disk); red is reserved for live distress: the CPU saturated
    /// right now. Grey until data lands.
    private var statusGem: some View {
        Circle()
            .fill(gemColor)
            .frame(width: 8, height: 8)
            .shadow(color: gemColor.opacity(0.85), radius: 5)
            .shadow(color: gemColor.opacity(0.4), radius: 10)
            .help(gemHelp)
    }

    private var gemColor: Color {
        guard case .loaded(let info) = probe.phase else {
            return Theme.textSecondary.opacity(0.5)
        }
        if isOverloaded(info) { return Color.red.opacity(0.95) }
        if (info.failedUnits ?? 0) > 0 || info.rebootRequired
            || memHot(info) || diskHot(info) {
            return Theme.warning
        }
        return Color(red: 0.45, green: 0.85, blue: 0.55)
    }

    private var gemHelp: String {
        guard case .loaded(let info) = probe.phase else { return "Collecting…" }
        if isOverloaded(info) { return "CPU saturated — load above core count" }
        let attention = alertItems(info).map(\.1)
        return attention.isEmpty ? "Up and healthy"
            : "Running, needs attention: " + attention.joined(separator: ", ")
    }

    /// OS mark in the subtitle. Preference order: the real distro logo
    /// from an installed Nerd Font (Font Logos block), tinted with the
    /// brand color; macOS's Apple mark; else an initial on a
    /// brand-colored chip so machines without Nerd Fonts still get one.
    @ViewBuilder @MainActor
    private static func distroBadge(_ os: String?) -> (some View)? {
        if let os {
            let lower = os.lowercased()
            if lower.contains("macos") || lower.contains("mac os") {
                Image(systemName: "apple.logo")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else if let glyphPath = NerdGlyphs.distroPath(for: lower) {
                FittedGlyph(base: glyphPath)
                    .fill(distroMark(lower)?.1 ?? Theme.textSecondary)
                    .frame(width: 13, height: 13)
            } else if let (initial, color) = distroMark(lower) {
                Text(initial)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(RoundedRectangle(cornerRadius: 3.5,
                                                 style: .continuous).fill(color))
            }
        }
    }

    private static func distroMark(_ os: String) -> (String, Color)? {
        let marks: [(key: String, initial: String, color: Color)] = [
            ("ubuntu", "U", Color(red: 0.91, green: 0.33, blue: 0.13)),
            ("debian", "D", Color(red: 0.66, green: 0.11, blue: 0.20)),
            ("fedora", "F", Color(red: 0.32, green: 0.64, blue: 0.85)),
            ("arch",   "A", Color(red: 0.09, green: 0.58, blue: 0.82)),
            ("alpine", "A", Color(red: 0.05, green: 0.35, blue: 0.50)),
            ("centos", "C", Color(red: 0.58, green: 0.13, blue: 0.47)),
            ("rocky",  "R", Color(red: 0.06, green: 0.72, blue: 0.51)),
            ("red hat", "R", Color(red: 0.93, green: 0.00, blue: 0.00)),
            ("rhel",   "R", Color(red: 0.93, green: 0.00, blue: 0.00)),
            ("suse",   "S", Color(red: 0.45, green: 0.73, blue: 0.15)),
            ("amazon", "A", Color(red: 1.00, green: 0.60, blue: 0.00)),
            ("nixos",  "N", Color(red: 0.32, green: 0.55, blue: 0.85)),
        ]
        if let m = marks.first(where: { os.contains($0.key) }) {
            return (m.initial, m.color)
        }
        if os.contains("linux") {
            return ("L", Color(white: 0.35))
        }
        return nil
    }

    private func isOverloaded(_ info: HostInfo) -> Bool {
        guard let load = info.loadAvg, let cores = info.cores, cores > 0
        else { return false }
        return load.0 > Double(cores)
    }
    private func memHot(_ info: HostInfo) -> Bool {
        guard let total = info.memTotalMB, let avail = info.memAvailMB,
              total > 0 else { return false }
        return Double(total - avail) / Double(total) > 0.92
    }
    private func diskHot(_ info: HostInfo) -> Bool {
        info.disks.contains { $0.pct > 0.9 }
    }

    private var isLoading: Bool {
        if case .loading = probe.phase { return true }
        return false
    }

    private var headline: String {
        if case .loaded(let info) = probe.phase, !info.hostname.isEmpty {
            return info.hostname
        }
        return probe.target
    }

    private var subheadline: String {
        guard case .loaded(let info) = probe.phase else {
            return "ssh \(probe.target)"
        }
        var parts: [String] = []
        if let os = info.os, !os.isEmpty { parts.append(os) }
        if let k = info.kernel { parts.append(k) }
        if let a = info.arch { parts.append(a) }
        if let up = info.uptime { parts.append("up \(up)") }
        return parts.isEmpty ? "ssh \(probe.target)" : parts.joined(separator: "  ·  ")
    }

    // MARK: - Loading / failure

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Collecting from \(probe.target)…")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
            HStack(spacing: 8) {
                TextField("user@host", text: $retryTarget)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 240)
                    .onSubmit(retry)
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Probes with your SSH keys. A different login is remembered for this host.")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .onAppear { retryTarget = probe.target }
    }

    private func retry() {
        let t = retryTarget.trimmingCharacters(in: .whitespaces)
        SoundEffects.shared.play(.click)
        if t.isEmpty || t == probe.target {
            probe.refresh()
        } else {
            state.retryHostOverview(as: t)
        }
    }

    // MARK: - Content

    private func content(_ info: HostInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                alertsSection(info)
                hairline
                vitalsBand(info)
                if info.containers != nil || info.vms != nil
                    || info.kubelet || info.kubeNodes != nil {
                    hairline
                    workloadsBand(info)
                }
                hairline
                footerBand(info)
                if !info.topProcs.isEmpty || !info.listeningPorts.isEmpty {
                    hairline
                    procsPortsBand(info)
                }
                if !info.journalErrors.isEmpty || !info.kernelWarnings.isEmpty {
                    hairline
                    logsBand(info)
                }
                if !info.lastLogins.isEmpty {
                    hairline
                    loginsBand(info)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: 620)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.stroke).frame(height: 0.5)
    }

    private func alertItems(_ info: HostInfo) -> [(Color, String)] {
        var items: [(Color, String)] = []
        if let failed = info.failedUnits, failed > 0 {
            items.append((Color.red.opacity(0.95),
                          "\(failed) failed unit\(failed == 1 ? "" : "s")"))
        }
        if isOverloaded(info) {
            items.append((Color.red.opacity(0.95), "load above core count"))
        }
        if info.rebootRequired {
            items.append((Theme.warning, "reboot required"))
        }
        if let updates = info.updatesAvailable {
            items.append((Theme.warning,
                          updates.trimmingCharacters(in: .whitespaces)
                              .trimmingCharacters(in: CharacterSet(charactersIn: "."))))
        }
        return items
    }

    @ViewBuilder
    private func alertsSection(_ info: HostInfo) -> some View {
        let items = alertItems(info)
        if !items.isEmpty {
            hairline
            HStack(spacing: 16) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Circle().fill(item.0).frame(width: 5, height: 5)
                        Text(item.1)
                            .font(.system(size: 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(item.0)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: Vitals

    private func vitalsBand(_ info: HostInfo) -> some View {
        // Load and memory are single figures — fixed columns; storage
        // grows with its mount list and takes the remaining width.
        HStack(alignment: .top, spacing: 28) {
            if let load = info.loadAvg {
                column("LOAD") { loadColumn(load, cores: info.cores) }
                    .frame(width: 168)
            }
            if let total = info.memTotalMB {
                column("MEMORY") { memoryColumn(total: total, avail: info.memAvailMB) }
                    .frame(width: 168)
            }
            if !info.disks.isEmpty {
                column("STORAGE") { storageColumn(info.disks) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func loadColumn(_ load: (Double, Double, Double),
                            cores: Int?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.2f", load.0))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(cores.map { loadTint(load.0, cores: $0) }
                                     ?? Theme.textPrimary)
                    .monospacedDigit()
                Text(String(format: "%.2f · %.2f", load.1, load.2))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            if let cores {
                bar(fill: min(1, load.0 / Double(cores)),
                    tint: loadTint(load.0, cores: cores))
                Text("\(cores) core\(cores == 1 ? "" : "s")")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
            }
        }
    }

    private func loadTint(_ v: Double, cores: Int) -> Color {
        let r = v / Double(max(cores, 1))
        if r >= 1.0 { return Color.red.opacity(0.95) }
        if r >= 0.7 { return Theme.warning }
        return Theme.textPrimary
    }

    private func memoryColumn(total: Int, avail: Int?) -> some View {
        let used = total - (avail ?? 0)
        let frac = total > 0 ? Double(used) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(gb(used))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                Text("of \(gb(total)) GB")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            bar(fill: frac, tint: frac > 0.9 ? Color.red.opacity(0.95)
                : frac > 0.75 ? Theme.warning : Theme.accent)
            Text("\(Int((frac * 100).rounded()))% in use")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
    }

    private func storageColumn(_ disks: [HostInfo.Disk]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(disks.prefix(3), id: \.mount) { d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.mount)
                            .font(.system(size: 11.5, weight: .medium,
                                          design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Int((d.pct * 100).rounded()))% of \(gb(d.totalKB / 1024)) GB")
                            .font(.system(size: 9.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                    bar(fill: d.pct, tint: d.pct > 0.9 ? Color.red.opacity(0.95)
                        : d.pct > 0.75 ? Theme.warning : Theme.accent)
                }
            }
        }
    }

    private func gb(_ mb: Int) -> String {
        String(format: mb >= 10_240 ? "%.0f" : "%.1f", Double(mb) / 1024)
    }

    // MARK: Workloads

    private func workloadsBand(_ info: HostInfo) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            microLabel("WORKLOADS")
            if let containers = info.containers {
                workloadRow("shippingbox",
                            "\(containers.count) container\(containers.count == 1 ? "" : "s")",
                            names: [])
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(containers.prefix(5), id: \.name) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(c.name)
                                .font(.system(size: 11, weight: .medium,
                                              design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .frame(width: 190, alignment: .leading)
                            Text(c.status.isEmpty ? c.image
                                 : "\(c.image) · \(c.status)")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    if containers.count > 5 {
                        Text("+\(containers.count - 5) more containers")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    }
                }
                .padding(.leading, 25)
            }
            if let vms = info.vms {
                workloadRow("desktopcomputer",
                            "\(vms.count) virtual machine\(vms.count == 1 ? "" : "s")",
                            names: vms)
            }
            if info.kubelet || info.kubeNodes != nil {
                workloadRow("helm", kubeSummary(info), names: [])
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func kubeSummary(_ info: HostInfo) -> String {
        var parts: [String] = []
        if info.kubelet { parts.append("kubelet active — cluster node") }
        if let n = info.kubeNodes {
            parts.append("\(n) node\(n == 1 ? "" : "s") visible")
        }
        return parts.joined(separator: " · ")
    }

    private func workloadRow(_ symbol: String, _ headline: String,
                             names: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text(headline)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            if !names.isEmpty {
                Text(nameList(names))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private func nameList(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        let rest = names.count - min(5, names.count)
        return rest > 0 ? "\(shown), +\(rest) more" : shown
    }

    // MARK: Footer band

    private func footerBand(_ info: HostInfo) -> some View {
        HStack(alignment: .top, spacing: 24) {
            if !info.ips.isEmpty || info.fqdn != nil {
                column("NETWORK") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let fqdn = info.fqdn { monoLine(fqdn, primary: true) }
                        ForEach(info.ips.prefix(3), id: \.self) {
                            monoLine($0, primary: info.fqdn == nil)
                        }
                    }
                }
            }
            if !info.timers.isEmpty || (info.cronEntries ?? 0) > 0 {
                column("SCHEDULE") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let crons = info.cronEntries, crons > 0 {
                            Text("\(crons) crontab entr\(crons == 1 ? "y" : "ies")")
                                .font(.system(size: 11.5, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        ForEach(info.timers.prefix(3), id: \.unit) { t in
                            monoLine(t.unit, primary: false)
                        }
                    }
                }
            }
            column("HEALTH") {
                VStack(alignment: .leading, spacing: 5) {
                    kvLine("Units",
                           failedSummary(info),
                           tint: (info.failedUnits ?? 0) > 0
                               ? Color.red.opacity(0.95) : Theme.textPrimary)
                    if let users = info.usersLoggedIn {
                        kvLine("Sessions", "\(users) logged in")
                    }
                    kvLine("Reboot",
                           info.rebootRequired ? "required" : "not needed",
                           tint: info.rebootRequired ? Theme.warning
                                                     : Theme.textPrimary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func failedSummary(_ info: HostInfo) -> String {
        guard let failed = info.failedUnits else { return "no systemd" }
        guard failed > 0 else { return "all running" }
        if let first = info.failedNames.first {
            let more = failed > 1 ? " +\(failed - 1)" : ""
            return "\(first)\(more) failed"
        }
        return "\(failed) failed"
    }

    private func kvLine(_ label: String, _ value: String,
                        tint: Color = Theme.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Processes / ports

    private func procsPortsBand(_ info: HostInfo) -> some View {
        HStack(alignment: .top, spacing: 24) {
            if !info.topProcs.isEmpty {
                column("TOP PROCESSES") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(info.topProcs.enumerated()),
                                id: \.offset) { _, p in
                            // Fixed name column keeps the figures in a
                            // tight, scannable second column instead of
                            // drifting to the far edge.
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(p.name)
                                    .font(.system(size: 11, weight: .medium,
                                                  design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .frame(width: 150, alignment: .leading)
                                Text("\(p.cpu)% cpu · \(p.mem)% mem")
                                    .font(.system(size: 9.5, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary)
                                    .monospacedDigit()
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            if !info.listeningPorts.isEmpty {
                column("LISTENING") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(info.listeningPorts.prefix(6), id: \.self) {
                            monoLine($0, primary: false)
                        }
                        if info.listeningPorts.count > 6 {
                            Text("+ \(info.listeningPorts.count - 6) more")
                                .font(.system(size: 9.5, design: .rounded))
                                .foregroundStyle(Theme.textSecondary.opacity(0.75))
                        }
                    }
                }
                .frame(width: 170)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Log feeds

    private func logsBand(_ info: HostInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !info.journalErrors.isEmpty {
                logFeed("RECENT ERRORS — journal", info.journalErrors,
                        dot: Color.red.opacity(0.85))
            }
            if !info.kernelWarnings.isEmpty {
                logFeed("KERNEL — dmesg", info.kernelWarnings,
                        dot: Theme.warning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func logFeed(_ label: String, _ lines: [String],
                         dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            microLabel(label)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(dot).frame(width: 4, height: 4)
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Logins

    private func loginsBand(_ info: HostInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            microLabel("RECENT LOGINS")
            ForEach(Array(info.lastLogins.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func monoLine(_ s: String, primary: Bool) -> some View {
        Text(s)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(primary ? Theme.textPrimary : Theme.textSecondary)
            .textSelection(.enabled)
            .lineLimit(1)
    }

    // MARK: Shared bits

    private func column<Content: View>(_ label: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            microLabel(label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func microLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .kerning(1.3)
            .foregroundStyle(Theme.textSecondary.opacity(0.7))
    }

    private func bar(fill: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.stroke)
                Capsule().fill(tint)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fill))))
            }
        }
        .frame(height: 4)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
