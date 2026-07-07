import SwiftUI

/// Cluster Overview: the briefing card for one EXPLICIT kubectl
/// context (whatever row was clicked), across ALL namespaces. Bands
/// roll in with the palette's entrance stagger; ready bars animate on
/// refresh. Data comes from ClusterPulse.fetchOverview — every call
/// pinned with `--context`, so the card can never show a different
/// cluster than its title.
struct ClusterOverviewOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var pulse = ClusterPulse.shared
    let glassLive: Bool

    private var overview: ClusterPulse.Overview? { pulse.overview }

    /// Namespace the card is narrowed to; nil shows the whole cluster.
    /// The fetch always spans all namespaces, so narrowing is a pure
    /// client-side filter — switching costs nothing.
    @State private var nsFilter: String?

    /// Every namespace present in the fetched data, `default` first.
    private var namespaces: [String] {
        guard let o = overview else { return [] }
        var names = Set(o.pods.map(\.namespace))
        names.formUnion(o.deployments.map(\.namespace))
        names.formUnion(o.services.map(\.namespace))
        names.formUnion(o.events.map(\.namespace))
        return names.sorted { a, b in
            if a == "default" { return true }
            if b == "default" { return false }
            return a < b
        }
    }

    /// The selection, unless a refresh dropped that namespace.
    private var effectiveFilter: String? {
        guard let f = nsFilter, namespaces.contains(f) else { return nil }
        return f
    }

    private func filtered(_ o: ClusterPulse.Overview) -> ClusterPulse.Overview {
        guard let ns = effectiveFilter else { return o }
        var f = o
        f.pods = o.pods.filter { $0.namespace == ns }
        f.deployments = o.deployments.filter { $0.namespace == ns }
        f.services = o.services.filter { $0.namespace == ns }
        f.events = o.events.filter { $0.namespace == ns }
        return f
    }

    var body: some View {
        BriefingCard(glassLive: glassLive) {
            VStack(spacing: 0) {
                header
                hairline
                if let o = overview {
                    content(filtered(o))
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Asking the cluster…")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                }
            }
        }
        .onChange(of: overview?.context) { _, _ in nsFilter = nil }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(gemColor)
                        .frame(width: 9, height: 9)
                        .shadow(color: gemColor.opacity(0.8), radius: 5)
                    Text(overview.map { KubeContextWatch.shortLabel($0.context) }
                         ?? "cluster")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text(headerLine)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let at = overview?.fetchedAt {
                Text(Self.relative.localizedString(for: at, relativeTo: Date()))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            if !namespaces.isEmpty { namespaceMenu }
            if pulse.overviewLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                Button {
                    if let o = overview {
                        pulse.fetchOverview(context: o.context)
                    }
                    SoundEffects.shared.play(.click)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            Button { state.closeClusterOverview() } label: {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// Namespace narrowing chip: a menu of everything the fetch saw.
    private var namespaceMenu: some View {
        Menu {
            Picker("Namespace", selection: $nsFilter) {
                Text("All namespaces").tag(String?.none)
                Divider()
                ForEach(namespaces, id: \.self) { ns in
                    Text(ns).tag(String?.some(ns))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(effectiveFilter ?? "all namespaces")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(effectiveFilter == nil
                             ? Theme.textSecondary : Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(Theme.stroke))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Narrow the card to one namespace")
    }

    private var gemColor: Color {
        guard let o = overview else { return Theme.textSecondary.opacity(0.5) }
        let bad = o.pods.contains { $0.health == .bad }
        let pending = o.pods.contains { $0.health == .pending }
        if bad { return Color.red.opacity(0.95) }
        if pending { return Theme.warning }
        return Color(red: 0.45, green: 0.85, blue: 0.55)
    }

    private var headerLine: String {
        guard let raw = overview else { return "fetching cluster state" }
        let o = filtered(raw)
        var parts: [String] = []
        if KubeContextWatch.shortLabel(raw.context) != raw.context {
            parts.append(raw.context)
        }
        parts.append(effectiveFilter.map { "namespace \($0)" } ?? "all namespaces")
        parts.append("\(o.pods.count) pod\(o.pods.count == 1 ? "" : "s")")
        parts.append("\(o.nodes.count) node\(o.nodes.count == 1 ? "" : "s")")
        if !o.services.isEmpty {
            parts.append("\(o.services.count) service\(o.services.count == 1 ? "" : "s")")
        }
        if let version = o.nodes.first?.version {
            parts.append(version)
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Content

    @State private var contentHeight: CGFloat = 0

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private func content(_ o: ClusterPulse.Overview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !o.nodes.isEmpty {
                    nodesBand(o).rollUp(delay: 0.05)
                    hairline
                }
                workloadsBand(o).rollUp(delay: 0.11)
                if !o.services.isEmpty {
                    hairline
                    servicesBand(o).rollUp(delay: 0.17)
                }
                if !o.events.isEmpty {
                    hairline
                    eventsBand(o).rollUp(delay: 0.23)
                }
            }
            .padding(.bottom, 6)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self,
                                       value: geo.size.height)
            })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 80), 560))
    }

    private var hairline: some View {
        Rectangle().fill(Theme.stroke).frame(height: 0.5)
    }

    private func bandLabel(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .kerning(1.3)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
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
        .animation(Theme.Spring.soft, value: fill)
    }

    /// A resource name with its namespace as a dimmed prefix, so the
    /// eye can skip the boilerplate and land on the name.
    private func namespacedName(_ ns: String, _ name: String,
                                size: CGFloat = 11) -> Text {
        Text("\(ns)/")
            .font(.system(size: size - 1, design: .monospaced))
            .foregroundStyle(Theme.textSecondary.opacity(0.6))
        + Text(name)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
    }

    // MARK: Nodes

    private func nodesBand(_ o: ClusterPulse.Overview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            bandLabel("server.rack", "NODES · \(o.nodes.count)")
            ForEach(o.nodes) { node in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(node.status == "Ready"
                              ? Color(red: 0.45, green: 0.85, blue: 0.55)
                              : Color.red.opacity(0.95))
                        .frame(width: 5, height: 5)
                    Text(node.name)
                        .font(.system(size: 11.5, weight: .medium,
                                      design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                    if let cpu = node.cpuPct { pressure("cpu", cpu) }
                    if let mem = node.memPct { pressure("mem", mem) }
                    Spacer(minLength: 8)
                    if node.status != "Ready" {
                        Text(node.status)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Color.red.opacity(0.95))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func pressure(_ label: String, _ pct: Int) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
            bar(fill: Double(pct) / 100,
                tint: pct > 90 ? Color.red.opacity(0.95)
                    : pct > 75 ? Theme.warning : Theme.accent)
                .frame(width: 52)
            Text("\(pct)%")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }

    // MARK: Workloads (per namespace: deployments × their pods, then bare pods)

    /// Pods grouped under their owning workload. A pod named
    /// web-7887448d46-dqplv reduces to `web` by dropping the pod and
    /// pod-template hash suffixes.
    private func workloadKey(_ podName: String) -> String {
        var parts = podName.split(separator: "-").map(String.init)
        func dropHash(_ lengths: ClosedRange<Int>) {
            guard parts.count > 1, let last = parts.last,
                  lengths.contains(last.count),
                  last.allSatisfy({ $0.isLowercase || $0.isNumber })
            else { return }
            parts.removeLast()
        }
        dropHash(5...5)
        dropHash(8...10)
        return parts.joined(separator: "-")
    }

    private struct NamespaceGroup: Identifiable {
        var id: String { name }
        let name: String
        let deployments: [ClusterPulse.Deployment]
        let pods: [ClusterPulse.Pod]
        let bare: [ClusterPulse.Pod]
    }

    /// One group per namespace that has anything in it — `default`
    /// first (it's where the user's own workloads usually live), the
    /// rest alphabetical.
    private func namespaceGroups(_ o: ClusterPulse.Overview) -> [NamespaceGroup] {
        let podsByNS = Dictionary(grouping: o.pods, by: \.namespace)
        let depsByNS = Dictionary(grouping: o.deployments, by: \.namespace)
        let names = Set(podsByNS.keys).union(depsByNS.keys).sorted { a, b in
            if a == "default" { return true }
            if b == "default" { return false }
            return a < b
        }
        return names.map { ns in
            let deps = (depsByNS[ns] ?? []).sorted { $0.name < $1.name }
            let depNames = Set(deps.map(\.name))
            let pods = podsByNS[ns] ?? []
            let bare = pods.filter { !depNames.contains(workloadKey($0.name)) }
            return NamespaceGroup(name: ns, deployments: deps,
                                  pods: pods, bare: bare)
        }
    }

    private func workloadsBand(_ o: ClusterPulse.Overview) -> some View {
        let running = o.pods.lazy.filter { $0.health == .good }.count
        let bad = o.pods.lazy.filter { $0.health == .bad }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                bandLabel("shippingbox",
                          "WORKLOADS · \(effectiveFilter?.uppercased() ?? "ALL NAMESPACES")")
                Spacer()
                Text(bad > 0 ? "\(running) running · \(bad) in trouble"
                             : "\(running) running")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(bad > 0 ? Color.red.opacity(0.95)
                                             : Theme.textSecondary)
                    .monospacedDigit()
            }
            if o.pods.isEmpty && o.deployments.isEmpty {
                Text(effectiveFilter == nil ? "No pods in this cluster."
                                            : "No pods in this namespace.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(namespaceGroups(o)) { group in
                namespaceSection(group)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func namespaceSection(_ group: NamespaceGroup) -> some View {
        let byWorkload = Dictionary(grouping: group.pods,
                                    by: { workloadKey($0.name) })
        return VStack(alignment: .leading, spacing: 6) {
            // The band label already names a narrowed namespace.
            if effectiveFilter == nil {
                Text(group.name)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary.opacity(0.55))
                    .padding(.top, 2)
            }
            ForEach(group.deployments) { dep in
                workloadRow(dep, pods: byWorkload[dep.name] ?? [])
            }
            ForEach(group.bare.prefix(8)) { pod in barePodRow(pod) }
            if group.bare.count > 8 {
                Text("+\(group.bare.count - 8) more pods")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
            }
        }
    }

    private func workloadRow(_ dep: ClusterPulse.Deployment,
                             pods: [ClusterPulse.Pod]) -> some View {
        let short = dep.ready < dep.desired
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(dep.name)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(pods.prefix(20)) { pod in
                    Circle()
                        .fill(podColor(pod.health))
                        .frame(width: 8, height: 8)
                        .help("\(pod.name) — \(pod.status) · \(pod.age)\(pod.restarts > 0 ? " · \(pod.restarts) restarts" : "")")
                        .transition(.scale.combined(with: .opacity))
                }
                if pods.count > 20 {
                    Text("+\(pods.count - 20)")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .animation(Theme.Spring.snappy, value: pods)
            Spacer(minLength: 8)
            bar(fill: dep.desired > 0 ? Double(dep.ready) / Double(dep.desired) : 0,
                tint: short ? Color.red.opacity(0.95)
                            : Color(red: 0.45, green: 0.85, blue: 0.55))
                .frame(width: 70)
            Text("\(dep.ready)/\(dep.desired)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(short ? Color.red.opacity(0.95)
                                       : Theme.textSecondary)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.leading, effectiveFilter == nil ? 10 : 0)
    }

    private func barePodRow(_ pod: ClusterPulse.Pod) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(podColor(pod.health))
                .frame(width: 8, height: 8)
            Text(pod.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
            Text(pod.status)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(pod.health == .bad ? Color.red.opacity(0.9)
                                 : pod.health == .pending ? Theme.warning
                                 : Theme.textSecondary)
            if pod.restarts > 2 {
                Text("\(pod.restarts) restarts")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.warning)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Text(pod.age)
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
                .monospacedDigit()
        }
        .padding(.leading, effectiveFilter == nil ? 10 : 0)
    }

    private func podColor(_ health: ClusterPulse.Health) -> Color {
        switch health {
        case .good:    return Color(red: 0.35, green: 0.68, blue: 0.45)
        case .pending: return Theme.warning
        case .bad:     return Color.red.opacity(0.92)
        }
    }

    // MARK: Services

    private func servicesBand(_ o: ClusterPulse.Overview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            bandLabel("network", "SERVICES · \(o.services.count)")
            ForEach(o.services.prefix(8)) { svc in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    namespacedName(svc.namespace, svc.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 210, alignment: .leading)
                    Text(svc.type)
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 76, alignment: .leading)
                    Text(svc.clusterIP)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(svc.ports)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            if o.services.count > 8 {
                Text("+\(o.services.count - 8) more services")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Events

    private func eventsBand(_ o: ClusterPulse.Overview) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            bandLabel("exclamationmark.triangle", "RECENT WARNINGS")
            ForEach(o.events) { e in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(Theme.warning)
                        .frame(width: 4, height: 4)
                    (Text("\(e.reason) · ")
                        .font(.system(size: 10.5, weight: .medium,
                                      design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                     + Text("\(e.namespace)/")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                     + Text(e.object)
                        .font(.system(size: 10.5, weight: .medium,
                                      design: .monospaced))
                        .foregroundStyle(Theme.textPrimary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(e.age)
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    Spacer(minLength: 0)
                }
                if !e.message.isEmpty {
                    Text(e.message)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 11)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
