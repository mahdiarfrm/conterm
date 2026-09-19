import AppKit
import Combine
import SwiftUI

/// Inline host inspector — metric tiles, storage meters, containers, rename —
/// shown inside Orbit so a host can be examined and named without leaving the
/// cockpit. Sits on Orbit's panel surface (`orbitPanel`), in the Drop kit's
/// type and wells.
struct InlineHostPanel: View {
    let target: String
    @ObservedObject var probe: HostProbeModel
    let onConnect: () -> Void
    let onChanged: () -> Void
    let onClose: () -> Void
    var onRemove: (() -> Void)? = nil   // present only for a saved-space member

    @EnvironmentObject private var prefs: Preferences
    @State private var nameField = ""
    @FocusState private var nameFocused: Bool

    let green = Drop.good
    var displayName: String { HostNameStore.name(for: target) ?? target }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, OrbitPanel.inset).padding(.top, 4).padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            footer
        }
        .orbitPanel()
        .onAppear { nameField = HostNameStore.name(for: target) ?? "" }
    }

    var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(Drop.title(15))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(target).font(Drop.mono(10.5, .medium))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            DropIconButton(symbol: "arrow.clockwise", help: "Re-read this host",
                           spinning: probe.refreshing) { probe.refresh() }
            if let onRemove {
                DropIconButton(symbol: "trash", help: "Remove from this space", action: onRemove)
            }
            DropIconButton(symbol: "xmark", help: "Close", action: onClose)
        }
        .padding(.horizontal, OrbitPanel.inset).padding(.top, 20).padding(.bottom, 12)
    }

    @ViewBuilder private var content: some View {
        switch probe.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("probing \(target)…").font(Drop.display(12, .regular)).foregroundStyle(Theme.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 10) {
                nameEditor
                badge("exclamationmark.triangle.fill", "Unreachable", tint: Theme.warning)
                Text(why).font(Drop.mono(10.5)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
        case .loaded(let info):
            loaded(info)
        }
    }

    /// Who you are on this machine and how you reach it. The card names the
    /// host; two logins to the same box are otherwise identical here, and "which
    /// user am I?" is the first thing you need before running anything.
    @ViewBuilder private func identity(_ info: HostInfo) -> some View {
        let user = target.contains("@") ? String(target.split(separator: "@")[0]) : "default"
        let address = target.split(separator: "@").last.map(String.init) ?? target
        VStack(alignment: .leading, spacing: 4) {
            factRow("person.crop.circle", user, note: user == "root" ? "superuser" : nil)
            factRow("network", address,
                    note: info.ips.first { $0 != address }.map { "also \($0)" })
            if let k = info.kernel { factRow("cpu", k, note: nil) }
            if let n = info.usersLoggedIn, n > 0 {
                factRow("person.2", "\(n) logged in", note: nil)
            }
            if info.rebootRequired {
                factRow("arrow.triangle.2.circlepath", "reboot required", note: nil,
                        tint: Theme.warning)
            }
        }
    }

    func factRow(_ icon: String, _ value: String, note: String?,
                         tint: Color = Theme.textPrimary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary).frame(width: 13)
            Text(value).font(Drop.display(11, .medium))
                .foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
            if let note {
                Text(note).font(Drop.display(9.5, .regular))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func loaded(_ info: HostInfo) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            nameEditor
            if let os = info.os {
                HStack(spacing: 7) {
                    // The same mark the node card wears, so the panel and the
                    // map agree about what this machine is.
                    Group {
                        if let d = Distro.detect(os) {
                            DistroMark(distro: d, size: 12)
                        } else {
                            Image(systemName: "opticaldiscdrive").font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                    Text(os).font(Drop.display(11.5, .medium))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let arch = info.arch {
                        Text(arch).font(Drop.mono(9.5)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
            }
            identity(info)
            let cols = [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)]
            LazyVGrid(columns: cols, spacing: 9) {
                if let l = info.loadAvg {
                    // Labelled: three bare numbers read as one figure and two
                    // spare ones, and the 5/15-minute averages are the pair that
                    // says whether a spike is a spike or the new normal.
                    tile("LOAD 1m", String(format: "%.2f", l.0),
                         sub: String(format: "5m %.2f · 15m %.2f", l.1, l.2),
                         tint: loadColor(l.0, info.cores))
                }
                if let c = info.cores { tile("CPU", "\(c)", sub: "cores", tint: Theme.textPrimary) }
                if let t = info.memTotalMB, let av = info.memAvailMB {
                    meter("MEMORY", "\(fmtGB(t - av)) / \(fmtGB(t))", pct: Double(t - av) / Double(max(t, 1)))
                }
                if let up = info.uptime { tile("UPTIME", up, sub: nil, tint: Theme.textPrimary) }
            }
            if !info.disks.isEmpty {
                section("Storage")
                ForEach(info.disks.prefix(4), id: \.mount) { diskBar($0) }
            }
            if info.kubelet {
                badge("cube.transparent", "kubelet" + (info.kubeNodes.map { " · \($0) nodes" } ?? ""), tint: Drop.tones[4])
            }
            if let f = info.failedUnits, f > 0 {
                badge("exclamationmark.triangle.fill", "\(f) failed unit\(f == 1 ? "" : "s")", tint: Theme.warning)
            }
            if let c = info.containers, !c.isEmpty {
                let up = c.filter { $0.status.lowercased().contains("up") }.count
                section("Containers  ·  \(up)/\(c.count) up")
                VStack(spacing: 6) { ForEach(c.prefix(16), id: \.name) { containerRow($0) } }
            } else if !info.kubelet {
                Text("No containers running").font(Drop.display(11.5, .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    var nameEditor: some View {
        HStack(spacing: 7) {
            Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            TextField("Name this host", text: $nameField)
                .textFieldStyle(.plain).font(Drop.display(12, .regular))
                .focused($nameFocused).onSubmit(saveName)
            Button(action: saveName) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textPrimary)
            }.buttonStyle(.plain)
            Button(action: fetchName) {
                Image(systemName: "arrow.down.doc").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain).help("Fetch the hostname from the server")
        }
        .orbitFieldBed()
    }

    /// The same verb the action bar carries, worded the same way.
    var footer: some View {
        Button(action: onConnect) {
            Text("Connect").frame(maxWidth: .infinity).padding(.vertical, 3)
        }
        .buttonStyle(.drop)
        .help("Open a terminal window on this host")
        .padding(.horizontal, OrbitPanel.inset)
        .padding(.top, 10)
        .padding(.bottom, OrbitPanel.inset)
    }

    // MARK: pieces

    func tileLabel(_ label: String) -> some View {
        Text(label).font(Drop.mono(8.5, .medium)).kerning(1.2)
            .foregroundStyle(Theme.textSecondary.opacity(0.8))
    }

    func tile(_ label: String, _ value: String, sub: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            tileLabel(label)
            Text(value).font(Drop.display(17, .light)).monospacedDigit()
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            if let sub { Text(sub).font(Drop.mono(9)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(tileBed)
    }

    func meter(_ label: String, _ value: String, pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            tileLabel(label)
            Text(value).font(Drop.display(13, .medium)).monospacedDigit()
                .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            DropTube(fraction: pct, tint: gaugeTint(pct), height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(tileBed)
    }

    var tileBed: some View {
        RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
            .fill(Theme.selectionFill.opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5))
    }

    /// Nil while comfortable, so the gauge stays neutral ink.
    func gaugeTint(_ p: Double) -> Color? {
        p < 0.7 ? nil : (p < 0.9 ? Drop.warn : Drop.bad)
    }

    func diskBar(_ d: HostInfo.Disk) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(d.mount).font(Drop.mono(11, .medium))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Text("\(Int(d.pct * 100))% · \(fmtGB(d.totalKB / 1024))")
                    .font(Drop.mono(9.5)).foregroundStyle(Theme.textSecondary)
            }
            DropTube(fraction: d.pct, tint: gaugeTint(d.pct), height: 4)
        }
    }

    func section(_ t: String) -> some View {
        DropEyebrow(t).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
    }

    func badge(_ icon: String, _ text: String, tint: Color) -> some View {
        DropChip(text: text, symbol: icon, tint: tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func containerRow(_ c: HostInfo.Container) -> some View {
        let up = c.status.lowercased().contains("up")
        return HStack(spacing: 8) {
            Circle().fill(up ? green : Theme.textSecondary.opacity(0.6)).frame(width: 6, height: 6)
                .shadow(color: up ? green.opacity(0.6) : .clear, radius: 3)
            Text(c.name).font(Drop.mono(11))
                .foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 6)
        }
    }

    func loadColor(_ load: Double, _ cores: Int?) -> Color {
        let r = load / Double(max(cores ?? 1, 1))
        return r < 0.7 ? Theme.textPrimary : (r < 1 ? Drop.warn : Drop.bad)
    }

    func saveName() {
        HostNameStore.set(nameField.trimmingCharacters(in: .whitespaces), for: target)
        nameFocused = false
        onChanged()
    }
    func fetchName() {
        if case .loaded(let info) = probe.phase {
            let fetched = (info.fqdn?.isEmpty == false ? info.fqdn : nil) ?? (info.hostname.isEmpty ? nil : info.hostname)
            if let fetched { nameField = fetched; saveName() }
        } else {
            probe.refresh()
        }
    }
    func fmtGB(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1fG", Double(mb) / 1024) : "\(mb)M"
    }
}

extension MapNode.Status {
    var hint: String {
        switch self {
        case .working:   return "working"
        case .attention: return "needs you"
        case .ready:     return "ready"
        case .danger:    return "prod"
        case .neutral:   return "idle"
        }
    }
}
