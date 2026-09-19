import SwiftUI

/// Host Overview: one drop that answers "how is this machine?" in a
/// glance. Built from the `Drop` kit: a masthead, then vitals as gauges
/// (load and memory as rings, storage as tubes), workloads, the machine's
/// facts, and its logs. A status gem beside the eyebrow sums the whole
/// machine. Sections the host doesn't have simply don't render.
struct HostOverviewOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var prefs: Preferences
    @StateObject private var probe: HostProbeModel
    @State private var retryTarget = ""

    init(target: String) {
        _probe = StateObject(wrappedValue: HostProbeModel(target: target))
    }

    var body: some View {
        BriefingCard(width: 760) {
            VStack(spacing: 0) {
                header
                Group {
                    switch probe.phase {
                    case .loading: DropLoader(text: "Collecting from \(probe.target)")
                    case .failed(let message): failed(message)
                    case .loaded(let info): content(info)
                    }
                }
                .transition(.liquidSwap)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: phaseKey)
        }
    }

    private var phaseKey: Int {
        switch probe.phase {
        case .loading: return 0
        case .failed: return 1
        case .loaded: return 2
        }
    }

    // MARK: - Header

    private var header: some View {
        DropHeader(eyebrow: "Host", title: headline, gem: gemColor, gemHelp: gemHelp,
                   onClose: { state.closeHostOverview() }) {
            HStack(spacing: 7) {
                if case .loaded(let info) = probe.phase,
                   let badge = Self.distroBadge(info.os) {
                    badge
                }
                DropContext(subheadline)
            }
        } controls: {
            if case .loaded = probe.phase, let at = probe.fetchedAt {
                Text(Self.relative.localizedString(for: at, relativeTo: Date()))
                    .font(Drop.mono(9.5))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .padding(.trailing, 4)
            }
            DropIconButton(symbol: "arrow.clockwise", help: "Refresh",
                           spinning: probe.refreshing) {
                probe.refresh()
                SoundEffects.shared.play(.click)
            }
            .disabled(isLoading || probe.refreshing)
        }
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
        if isOverloaded(info) { return Drop.bad }
        if (info.failedUnits ?? 0) > 0 || info.rebootRequired
            || memHot(info) || diskHot(info) {
            return Theme.warning
        }
        return Drop.good
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

    // MARK: - Failure

    private func failed(_ message: String) -> some View {
        VStack(spacing: 22) {
            DropStatement(symbol: "bolt.horizontal", title: "Couldn't reach this host",
                          tint: Drop.warn)
                .padding(.bottom, -44)
            Text(message.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Drop.mono(10.5))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                    .fill(Theme.selectionFill.opacity(0.55)))
                .rollUp(delay: 0.22)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("user@host", text: $retryTarget)
                        .textFieldStyle(.plain)
                        .font(Drop.mono(12))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Theme.selectionFill))
                        .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 0.75))
                        .frame(width: 300)
                        .onSubmit(retry)
                    DropButton(title: "Retry", symbol: "arrow.clockwise",
                               prominent: true, action: retry)
                }
                Text("Probes non-interactively with your SSH keys. A different login is remembered for this host.")
                    .font(Drop.display(10.5, .regular))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
            }
            .rollUp(delay: 0.30)
        }
        .padding(.horizontal, Drop.inset)
        .padding(.bottom, 40)
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
        DropBody(maxHeight: 600) {
            alertsSection(info)
            vitalsBand(info)
            if info.containers != nil || info.vms != nil
                || info.kubelet || info.kubeNodes != nil {
                workloadsBand(info)
            }
            factsBand(info)
            if !info.topProcs.isEmpty || !info.listeningPorts.isEmpty {
                procsPortsBand(info)
            }
            if !info.journalErrors.isEmpty || !info.kernelWarnings.isEmpty {
                logsBand(info)
            }
            if !info.lastLogins.isEmpty {
                loginsBand(info)
            }
        }
    }

    private func alertItems(_ info: HostInfo) -> [(Color, String)] {
        var items: [(Color, String)] = []
        if let failed = info.failedUnits, failed > 0 {
            items.append((Drop.bad,
                          "\(failed) failed unit\(failed == 1 ? "" : "s")"))
        }
        if isOverloaded(info) {
            items.append((Drop.bad, "load above core count"))
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
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    DropChip(text: item.1, symbol: "exclamationmark", tint: item.0)
                }
                Spacer(minLength: 0)
            }
            .rollUp(delay: 0.08)
        }
    }

    // MARK: Vitals

    private func vitalsBand(_ info: HostInfo) -> some View {
        HStack(alignment: .top, spacing: 30) {
            if let load = info.loadAvg {
                loadGauge(load, cores: info.cores)
            }
            if let total = info.memTotalMB {
                memoryGauge(total: total, avail: info.memAvailMB)
            }
            if !info.disks.isEmpty {
                DropSection(label: "Storage", order: 2) { storageColumn(info.disks) }
            }
        }
    }

    private func loadGauge(_ load: (Double, Double, Double), cores: Int?) -> some View {
        let tint = cores.flatMap { loadTint(load.0, cores: $0) }
        return DropSection(label: "Load", order: 0) {
            DropRing(fraction: cores.map { load.0 / Double(max($0, 1)) } ?? 0, tint: tint) {
                DropFigure(value: load.0, format: "%.2f", font: Drop.display(22, .light),
                           color: tint ?? Theme.textPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.2f · %.2f", load.1, load.2))
                    .font(Drop.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                if let cores {
                    Text("\(cores) core\(cores == 1 ? "" : "s")")
                        .font(Drop.display(10.5, .regular))
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                }
            }
        }
        .frame(width: 118)
    }

    /// Nil while the load is comfortable, so the ring stays neutral ink.
    private func loadTint(_ v: Double, cores: Int) -> Color? {
        let r = v / Double(max(cores, 1))
        if r >= 1.0 { return Drop.bad }
        if r >= 0.7 { return Drop.warn }
        return nil
    }

    private func gaugeTint(_ fraction: Double) -> Color? {
        if fraction > 0.9 { return Drop.bad }
        if fraction > 0.75 { return Drop.warn }
        return nil
    }

    private func memoryGauge(total: Int, avail: Int?) -> some View {
        let used = total - (avail ?? 0)
        let frac = total > 0 ? Double(used) / Double(total) : 0
        return DropSection(label: "Memory", order: 1) {
            DropRing(fraction: frac, tint: gaugeTint(frac)) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    DropFigure(value: frac * 100, font: Drop.display(22, .light),
                               color: gaugeTint(frac) ?? Theme.textPrimary)
                    Text("%")
                        .font(Drop.display(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(gb(used)) of \(gb(total)) GB")
                    .font(Drop.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                Text("in use")
                    .font(Drop.display(10.5, .regular))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
            }
        }
        .frame(width: 118)
    }

    private func storageColumn(_ disks: [HostInfo.Disk]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(disks.prefix(4), id: \.mount) { d in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.mount)
                            .font(Drop.mono(12, .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Int((d.pct * 100).rounded()))%")
                            .font(Drop.display(13, .medium))
                            .foregroundStyle(gaugeTint(d.pct) ?? Theme.textPrimary)
                            .monospacedDigit()
                        Text("of \(gb(d.totalKB / 1024)) GB")
                            .font(Drop.display(10.5, .regular))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                    DropTube(fraction: d.pct, tint: gaugeTint(d.pct))
                }
            }
        }
        .padding(.top, 6)
    }

    private func gb(_ mb: Int) -> String {
        String(format: mb >= 10_240 ? "%.0f" : "%.1f", Double(mb) / 1024)
    }

    // MARK: Workloads

    private func workloadsBand(_ info: HostInfo) -> some View {
        DropSection(label: "Workloads", order: 3) {
            HStack(spacing: 8) {
                if let containers = info.containers {
                    DropChip(text: "\(containers.count) container\(containers.count == 1 ? "" : "s")",
                             symbol: "shippingbox.fill", tint: Drop.tones[0])
                }
                if let vms = info.vms {
                    DropChip(text: "\(vms.count) virtual machine\(vms.count == 1 ? "" : "s")",
                             symbol: "desktopcomputer", tint: Drop.tones[1])
                }
                if info.kubelet || info.kubeNodes != nil {
                    DropChip(text: kubeSummary(info), symbol: "helm",
                             tint: Drop.tones[4])
                }
            }
            if let containers = info.containers, !containers.isEmpty {
                DropWell {
                    ForEach(Array(containers.prefix(6).enumerated()), id: \.element.name) { i, c in
                        DropRow(index: i) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(c.name)
                                    .font(Drop.mono(11.5, .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .frame(width: 210, alignment: .leading)
                                Text(c.image)
                                    .font(Drop.display(11, .regular))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if !c.status.isEmpty {
                                    Text(c.status)
                                        .font(Drop.mono(9.5))
                                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    if containers.count > 6 {
                        more("+\(containers.count - 6) more containers")
                    }
                }
            }
            if let vms = info.vms, !vms.isEmpty {
                Text(nameList(vms))
                    .font(Drop.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private func more(_ text: String) -> some View {
        Text(text)
            .font(Drop.display(10.5, .regular))
            .foregroundStyle(Theme.textSecondary.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func kubeSummary(_ info: HostInfo) -> String {
        var parts: [String] = []
        if info.kubelet { parts.append("cluster node") }
        if let n = info.kubeNodes {
            parts.append("\(n) node\(n == 1 ? "" : "s") visible")
        }
        return parts.joined(separator: " · ")
    }

    private func nameList(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        let rest = names.count - min(5, names.count)
        return rest > 0 ? "\(shown), +\(rest) more" : shown
    }

    // MARK: Facts

    private func factsBand(_ info: HostInfo) -> some View {
        HStack(alignment: .top, spacing: 30) {
            if !info.ips.isEmpty || info.fqdn != nil {
                DropSection(label: "Network", order: 4) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let fqdn = info.fqdn { monoLine(fqdn, primary: true) }
                        ForEach(info.ips.prefix(3), id: \.self) {
                            monoLine($0, primary: info.fqdn == nil)
                        }
                    }
                }
            }
            if !info.timers.isEmpty || (info.cronEntries ?? 0) > 0 {
                DropSection(label: "Schedule", order: 5) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let crons = info.cronEntries, crons > 0 {
                            Text("\(crons) crontab entr\(crons == 1 ? "y" : "ies")")
                                .font(Drop.display(12, .medium))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        ForEach(info.timers.prefix(3), id: \.unit) { t in
                            monoLine(t.unit, primary: false)
                        }
                    }
                }
            }
            DropSection(label: "Health", order: 6) {
                VStack(alignment: .leading, spacing: 11) {
                    DropFact(label: "Units", value: failedSummary(info),
                             tint: (info.failedUnits ?? 0) > 0 ? Drop.bad : Theme.textPrimary)
                    if let users = info.usersLoggedIn {
                        DropFact(label: "Sessions", value: "\(users) logged in")
                    }
                    DropFact(label: "Reboot",
                             value: info.rebootRequired ? "required" : "not needed",
                             tint: info.rebootRequired ? Drop.warn : Theme.textPrimary)
                }
            }
        }
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

    // MARK: Processes / ports

    private func procsPortsBand(_ info: HostInfo) -> some View {
        HStack(alignment: .top, spacing: 30) {
            if !info.topProcs.isEmpty {
                DropSection(label: "Top processes", order: 7) {
                    DropWell {
                        ForEach(Array(info.topProcs.enumerated()), id: \.offset) { i, p in
                            DropRow(index: i) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(p.name)
                                        .font(Drop.mono(11.5, .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("\(p.cpu)% cpu")
                                        .font(Drop.mono(10))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 70, alignment: .trailing)
                                    Text("\(p.mem)% mem")
                                        .font(Drop.mono(10))
                                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                                        .frame(width: 70, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
            if !info.listeningPorts.isEmpty {
                DropSection(label: "Listening", order: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(info.listeningPorts.prefix(6), id: \.self) {
                            monoLine($0, primary: false)
                        }
                        if info.listeningPorts.count > 6 {
                            Text("+ \(info.listeningPorts.count - 6) more")
                                .font(Drop.display(10.5, .regular))
                                .foregroundStyle(Theme.textSecondary.opacity(0.75))
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(width: 190)
            }
        }
    }

    // MARK: Log feeds

    private func logsBand(_ info: HostInfo) -> some View {
        VStack(alignment: .leading, spacing: Drop.sectionGap) {
            if !info.journalErrors.isEmpty {
                logFeed("Recent errors · journal", info.journalErrors, tint: Drop.bad, order: 9)
            }
            if !info.kernelWarnings.isEmpty {
                logFeed("Kernel · dmesg", info.kernelWarnings, tint: Drop.warn, order: 10)
            }
        }
    }

    private func logFeed(_ label: String, _ lines: [String],
                         tint: Color, order: Int) -> some View {
        DropSection(label: label, tint: tint, order: order) {
            DropWell(padding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Drop.mono(10.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Logins

    private func loginsBand(_ info: HostInfo) -> some View {
        DropSection(label: "Recent logins", order: 11) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(info.lastLogins.enumerated()), id: \.offset) { _, line in
                    monoLine(line, primary: false)
                }
            }
        }
    }

    private func monoLine(_ s: String, primary: Bool) -> some View {
        Text(s)
            .font(Drop.mono(11))
            .foregroundStyle(primary ? Theme.textPrimary : Theme.textSecondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
