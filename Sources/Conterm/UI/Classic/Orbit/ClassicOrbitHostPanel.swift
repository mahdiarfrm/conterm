import AppKit
import Combine
import SwiftUI

/// Classic interface style. Inline host inspector — metric tiles, storage meters, containers, rename —
/// shown inside Orbit so a host can be examined and named without leaving the
/// cockpit.
struct ClassicInlineHostPanel: View {
    let target: String
    @ObservedObject var probe: HostProbeModel
    let onConnect: () -> Void
    let onChanged: () -> Void
    let onClose: () -> Void
    var onRemove: (() -> Void)? = nil   // present only for a saved-space member

    @EnvironmentObject private var prefs: Preferences
    @State private var nameField = ""
    @FocusState private var nameFocused: Bool

    let green = Color(red: 0.32, green: 0.72, blue: 0.46)
    let red = Color(red: 0.92, green: 0.30, blue: 0.30)
    var displayName: String { HostNameStore.name(for: target) ?? target }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView { content.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14) }
            footer
        }
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 26, y: 12)
        .onAppear { nameField = HostNameStore.name(for: target) ?? "" }
    }

    var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(target).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { probe.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(probe.refreshing ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Re-read this host")
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).frame(width: 27, height: 27)
                        .background(Circle().fill(Theme.selectionFill))
                }.buttonStyle(.plain).help("Remove from this space")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 27, height: 27)
                    .background(Circle().fill(Theme.selectionFill))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 17).padding(.top, 16).padding(.bottom, 12)
    }

    @ViewBuilder private var content: some View {
        switch probe.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("probing \(target)…").font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 10) {
                nameEditor
                badge("exclamationmark.triangle.fill", "Unreachable", tint: Theme.warning)
                Text(why).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
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
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
            if let note {
                Text(note).font(.system(size: 9.5, design: .rounded))
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
                    Text(os).font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let arch = info.arch {
                        Text(arch).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
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
                badge("cube.transparent", "kubelet" + (info.kubeNodes.map { " · \($0) nodes" } ?? ""), tint: Theme.accent)
            }
            if let f = info.failedUnits, f > 0 {
                badge("exclamationmark.triangle.fill", "\(f) failed unit\(f == 1 ? "" : "s")", tint: Theme.warning)
            }
            if let c = info.containers, !c.isEmpty {
                let up = c.filter { $0.status.lowercased().contains("up") }.count
                section("Containers  ·  \(up)/\(c.count) up")
                VStack(spacing: 6) { ForEach(c.prefix(16), id: \.name) { containerRow($0) } }
            } else if !info.kubelet {
                Text("No containers running").font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    var nameEditor: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            TextField("Name this host", text: $nameField)
                .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
                .focused($nameFocused).onSubmit(saveName)
            Button(action: saveName) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
            }.buttonStyle(.plain)
            Button(action: fetchName) {
                Image(systemName: "arrow.down.doc").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain).help("Fetch the hostname from the server")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.selectionFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    /// The same verb the action bar carries, worded the same way.
    var footer: some View {
        Button(action: onConnect) {
            Text("Connect")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Capsule(style: .continuous).fill(chromeFill(prefs, selected: true)))
                .overlay(Capsule(style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open a terminal window on this host")
        .padding(14)
    }

    // MARK: pieces

    func tile(_ label: String, _ value: String, sub: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            if let sub { Text(sub).font(.system(size: 9.5, design: .rounded)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(tileBed)
    }

    func meter(_ label: String, _ value: String, pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            bar(pct, tint: usageColor(pct))
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(tileBed)
    }

    var tileBed: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.selectionFill)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    func bar(_ pct: Double, tint: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.selectionFill)
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.75), tint],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, g.size.width * min(max(pct, 0), 1)))
            }
        }.frame(height: 4)
    }

    func diskBar(_ d: HostInfo.Disk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(d.mount).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Text("\(Int(d.pct * 100))% · \(fmtGB(d.totalKB / 1024))")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.textSecondary)
            }
            bar(d.pct, tint: usageColor(d.pct))
        }
    }

    func section(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.4)
            .foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
    }

    func badge(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(tint)
            Text(text).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }

    func containerRow(_ c: HostInfo.Container) -> some View {
        let up = c.status.lowercased().contains("up")
        return HStack(spacing: 8) {
            Circle().fill(up ? green : Theme.textSecondary.opacity(0.6)).frame(width: 6, height: 6)
                .shadow(color: up ? green.opacity(0.6) : .clear, radius: 3)
            Text(c.name).font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 6)
        }
    }

    func usageColor(_ p: Double) -> Color {
        p < 0.7 ? green : (p < 0.9 ? Theme.warning : red)
    }
    func loadColor(_ load: Double, _ cores: Int?) -> Color {
        let r = load / Double(max(cores ?? 1, 1))
        return r < 0.7 ? green : (r < 1 ? Theme.warning : red)
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
