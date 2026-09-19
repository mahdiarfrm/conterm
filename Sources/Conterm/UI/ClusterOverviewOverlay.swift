import SwiftUI

/// Cluster Overview: the drop for one EXPLICIT kubectl context (whatever
/// row was clicked), across ALL namespaces. Built from the `Drop` kit: a
/// masthead, a pulse of large figures around a pod-health ring, then nodes,
/// workloads per namespace, Helm releases, services and recent warnings,
/// each a section of rows in a well. Figures and gauges re-run when a
/// refresh or the namespace filter changes their value. Data comes from
/// ClusterPulse.fetchOverview — every call pinned with `--context`, so the
/// card can never show a different cluster than its title.
struct ClusterOverviewOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var pulse = ClusterPulse.shared
    @ObservedObject private var helm = HelmReleases.shared

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
        BriefingCard(width: 780) {
            VStack(spacing: 0) {
                header
                Group {
                    if let o = overview {
                        content(filtered(o))
                    } else {
                        DropLoader(text: "Asking the cluster")
                    }
                }
                .transition(.liquidSwap)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: overview == nil)
        }
        .onChange(of: overview?.context) { _, _ in nsFilter = nil }
    }

    // MARK: Header

    private var header: some View {
        DropHeader(eyebrow: "Cluster",
                   title: overview.map { KubeContextWatch.shortLabel($0.context) } ?? "cluster",
                   gem: gemColor, gemHelp: gemHelp,
                   onClose: { state.closeClusterOverview() }) {
            DropContext(headerLine)
        } controls: {
            if let at = overview?.fetchedAt {
                Text(Self.relative.localizedString(for: at, relativeTo: Date()))
                    .font(Drop.mono(9.5))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .padding(.trailing, 4)
            }
            if !namespaces.isEmpty { namespaceMenu }
            DropIconButton(symbol: "arrow.clockwise", help: "Refresh",
                           spinning: pulse.overviewLoading) {
                if let o = overview {
                    pulse.fetchOverview(context: o.context)
                    helm.refresh(context: o.context, force: true)
                }
                SoundEffects.shared.play(.click)
            }
            .disabled(pulse.overviewLoading)
        }
    }

    /// Namespace narrowing: a glass capsule over a menu of everything the
    /// fetch saw. The rim brightens while a filter is active.
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
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9, weight: .bold))
                Text(effectiveFilter ?? "all namespaces")
                    .font(Drop.display(11, .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(effectiveFilter == nil ? Theme.textSecondary : Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Theme.selectionFill))
            .overlay(Capsule().strokeBorder(
                effectiveFilter == nil ? AnyShapeStyle(Theme.stroke)
                                       : AnyShapeStyle(Drop.sheen),
                lineWidth: effectiveFilter == nil ? 0.5 : 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Narrow the card to one namespace")
    }

    /// Red is cluster-critical only: a node down, or a workload fully
    /// dark. Pod-level trouble — crash loops, image pulls, short
    /// deployments — is amber.
    private var gemColor: Color {
        guard let o = overview else { return Theme.textSecondary.opacity(0.5) }
        let nodeDown = o.nodes.contains { !ClusterPulse.nodeIsReady($0.status) }
        let outage = o.deployments.contains { $0.desired > 0 && $0.ready == 0 }
        if nodeDown || outage { return Drop.bad }
        let trouble = o.pods.contains { $0.health != .good }
            || o.deployments.contains { $0.ready < $0.desired }
        if trouble { return Drop.warn }
        return Drop.good
    }

    private var gemHelp: String {
        guard overview != nil else { return "Asking the cluster…" }
        if gemColor == Drop.bad { return "A node is down or a workload is fully dark" }
        if gemColor == Drop.warn { return "Running, with pods or deployments in trouble" }
        return "Healthy"
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

    private func content(_ o: ClusterPulse.Overview) -> some View {
        DropBody(maxHeight: 600) {
            pulseBand(o)
            if !o.nodes.isEmpty { nodesBand(o) }
            workloadsBand(o)
            if !filteredReleases.isEmpty { helmBand }
            if !o.services.isEmpty { servicesBand(o) }
            if !o.events.isEmpty { eventsBand(o) }
        }
    }

    /// A resource name with its namespace as a dimmed prefix, so the
    /// eye can skip the boilerplate and land on the name.
    private func namespacedName(_ ns: String, _ name: String,
                                size: CGFloat = 11.5) -> Text {
        Text("\(ns)/")
            .font(Drop.mono(size - 1))
            .foregroundStyle(Theme.textSecondary.opacity(0.6))
        + Text(name)
            .font(Drop.mono(size, .medium))
            .foregroundStyle(Theme.textPrimary)
    }

    private func dot(_ color: Color, size: CGFloat = 7) -> some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
    }

    private func more(_ text: String) -> some View {
        Text(text)
            .font(Drop.display(10.5, .regular))
            .foregroundStyle(Theme.textSecondary.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    // MARK: Pulse

    /// The cluster in five numbers: the share of pods that are healthy as a
    /// ring, then the counts that explain it.
    private func pulseBand(_ o: ClusterPulse.Overview) -> some View {
        let total = o.pods.count
        let running = o.pods.lazy.filter { $0.health == .good }.count
        let bad = o.pods.lazy.filter { $0.health == .bad }.count
        let pending = max(0, total - running - bad)
        let tint: Color? = bad > 0 ? Drop.bad : pending > 0 ? Drop.warn : nil
        let share = total > 0 ? Double(running) / Double(total) : 0
        return HStack(alignment: .center, spacing: 34) {
            DropRing(fraction: share, tint: tint, size: 104) {
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        DropFigure(value: share * 100, font: Drop.display(24, .light),
                                   color: tint ?? Theme.textPrimary)
                        Text("%")
                            .font(Drop.display(11, .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text("HEALTHY")
                        .font(Drop.mono(7.5, .medium))
                        .kerning(1.4)
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                }
            }
            heroStat("Running", running)
            heroStat("In trouble", bad, tint: bad > 0 ? Drop.bad : nil)
            if pending > 0 { heroStat("Pending", pending, tint: Drop.warn) }
            heroStat("Nodes", o.nodes.count)
            if !o.services.isEmpty { heroStat("Services", o.services.count) }
            Spacer(minLength: 0)
        }
        .rollUp(delay: 0.08)
    }

    private func heroStat(_ label: String, _ value: Int, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            DropFigure(value: Double(value), color: tint ?? Theme.textPrimary)
            Text(label.uppercased())
                .font(Drop.mono(8.5, .medium))
                .kerning(1.4)
                .foregroundStyle(tint?.opacity(0.85) ?? Theme.textSecondary.opacity(0.75))
        }
        .fixedSize()
    }

    // MARK: Nodes

    private func nodesBand(_ o: ClusterPulse.Overview) -> some View {
        DropSection(label: "Nodes", count: o.nodes.count, order: 1) {
            DropWell {
                ForEach(Array(o.nodes.enumerated()), id: \.element.id) { i, node in
                    DropRow(index: i) {
                        HStack(alignment: .center, spacing: 14) {
                            dot(ClusterPulse.nodeIsReady(node.status) ? Drop.good : Drop.bad)
                            Text(node.name)
                                .font(Drop.mono(11.5, .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 210, alignment: .leading)
                            if let cpu = node.cpuPct { pressure("cpu", cpu) }
                            if let mem = node.memPct { pressure("mem", mem) }
                            Spacer(minLength: 8)
                            if node.status != "Ready" {
                                DropChip(text: node.status, tint: Drop.bad)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Nil while comfortable, so the gauge stays neutral ink.
    private func heat(_ pct: Int) -> Color? {
        if pct > 90 { return Drop.bad }
        if pct > 75 { return Drop.warn }
        return nil
    }

    private func pressure(_ label: String, _ pct: Int) -> some View {
        HStack(spacing: 7) {
            Text(label.uppercased())
                .font(Drop.mono(8.5, .medium))
                .kerning(1.2)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
            DropTube(fraction: Double(pct) / 100, tint: heat(pct), height: 4)
                .frame(width: 72)
            Text("\(pct)%")
                .font(Drop.mono(10))
                .foregroundStyle(heat(pct) ?? Theme.textSecondary)
                .frame(width: 34, alignment: .trailing)
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
        DropSection(label: "Workloads · \(effectiveFilter ?? "all namespaces")", order: 2) {
            if o.pods.isEmpty && o.deployments.isEmpty {
                DropStatement(symbol: "shippingbox",
                              title: effectiveFilter == nil ? "No pods in this cluster"
                                                            : "No pods in this namespace")
                    .padding(.bottom, -30)
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(namespaceGroups(o)) { group in
                    namespaceSection(group)
                }
            }
        }
    }

    private func namespaceSection(_ group: NamespaceGroup) -> some View {
        let byWorkload = Dictionary(grouping: group.pods,
                                    by: { workloadKey($0.name) })
        return VStack(alignment: .leading, spacing: 7) {
            // The section label already names a narrowed namespace.
            if effectiveFilter == nil {
                Text(group.name)
                    .font(Drop.mono(10, .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .padding(.leading, 12)
            }
            DropWell {
                ForEach(Array(group.deployments.enumerated()), id: \.element.id) { i, dep in
                    DropRow(index: i) {
                        workloadRow(dep, pods: byWorkload[dep.name] ?? [])
                    }
                }
                ForEach(Array(group.bare.prefix(8).enumerated()), id: \.element.id) { i, pod in
                    DropRow(index: group.deployments.count + i) { barePodRow(pod) }
                }
                if group.bare.count > 8 {
                    more("+\(group.bare.count - 8) more pods")
                }
            }
        }
    }

    private func workloadRow(_ dep: ClusterPulse.Deployment,
                             pods: [ClusterPulse.Pod]) -> some View {
        let short = dep.ready < dep.desired
        return HStack(alignment: .center, spacing: 12) {
            Text(dep.name)
                .font(Drop.mono(11.5, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 200, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(pods.prefix(20)) { pod in
                    Circle()
                        .fill(podColor(pod.health))
                        .frame(width: 8, height: 8)
                        .help("\(pod.name) — \(pod.status) · \(pod.age)\(pod.restarts > 0 ? " · \(pod.restarts) restarts" : "")")
                        .transition(.scale.combined(with: .opacity))
                }
                if pods.count > 20 {
                    Text("+\(pods.count - 20)")
                        .font(Drop.mono(9.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .animation(Theme.Spring.snappy, value: pods)
            Spacer(minLength: 8)
            DropTube(fraction: dep.desired > 0 ? Double(dep.ready) / Double(dep.desired) : 0,
                     tint: short ? Drop.bad : Drop.good, height: 4)
                .frame(width: 84)
            Text("\(dep.ready)/\(dep.desired)")
                .font(Drop.mono(10.5, .medium))
                .foregroundStyle(short ? Drop.bad : Theme.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func barePodRow(_ pod: ClusterPulse.Pod) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(podColor(pod.health))
                .frame(width: 8, height: 8)
            Text(pod.name)
                .font(Drop.mono(11.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 240, alignment: .leading)
            if pod.health == .good {
                Text(pod.status)
                    .font(Drop.display(11, .regular))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                DropChip(text: pod.status,
                         tint: pod.health == .bad ? Drop.bad : Drop.warn)
            }
            if pod.restarts > 2 {
                DropChip(text: "\(pod.restarts) restarts",
                         symbol: "arrow.counterclockwise", tint: Drop.warn)
            }
            Spacer(minLength: 8)
            Text(pod.age)
                .font(Drop.mono(10))
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
    }

    private func podColor(_ health: ClusterPulse.Health) -> Color {
        switch health {
        case .good:    return Color(red: 0.35, green: 0.68, blue: 0.45)
        case .pending: return Drop.warn
        case .bad:     return Drop.bad
        }
    }

    // MARK: Helm

    /// Releases for the card's context, narrowed by the namespace filter
    /// like every other section.
    private var filteredReleases: [HelmReleases.Release] {
        guard let ns = effectiveFilter else { return helm.releases }
        return helm.releases.filter { $0.namespace == ns }
    }

    private var helmBand: some View {
        DropSection(label: "Helm releases", count: filteredReleases.count, order: 3) {
            DropWell {
                ForEach(Array(filteredReleases.enumerated()), id: \.element.id) { i, release in
                    DropRow(index: i) {
                        HStack(alignment: .center, spacing: 12) {
                            dot(helmStatusColor(release.status))
                            namespacedName(release.namespace, release.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 230, alignment: .leading)
                            Text(release.chart)
                                .font(Drop.mono(10.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("rev \(release.revision)")
                                .font(Drop.mono(10))
                                .foregroundStyle(Theme.textSecondary.opacity(0.75))
                            DropChip(text: release.status,
                                     tint: helmStatusColor(release.status))
                        }
                    }
                }
            }
        }
    }

    private func helmStatusColor(_ status: String) -> Color {
        switch status {
        case "deployed":
            return Drop.good
        case let s where s.hasPrefix("pending"):
            return Drop.warn
        case "uninstalling", "superseded":
            return Drop.warn
        default:
            return Drop.bad
        }
    }

    // MARK: Services

    private func servicesBand(_ o: ClusterPulse.Overview) -> some View {
        DropSection(label: "Services", count: o.services.count, order: 4) {
            DropWell {
                ForEach(Array(o.services.prefix(8).enumerated()), id: \.element.id) { i, svc in
                    DropRow(index: i) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            namespacedName(svc.namespace, svc.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 240, alignment: .leading)
                            Text(svc.type.uppercased())
                                .font(Drop.mono(8.5, .medium))
                                .kerning(1.2)
                                .foregroundStyle(Theme.textSecondary.opacity(0.75))
                                .frame(width: 92, alignment: .leading)
                            Text(svc.clusterIP)
                                .font(Drop.mono(10.5))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(svc.ports)
                                .font(Drop.mono(10.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                if o.services.count > 8 {
                    more("+\(o.services.count - 8) more services")
                }
            }
        }
    }

    // MARK: Events

    private func eventsBand(_ o: ClusterPulse.Overview) -> some View {
        DropSection(label: "Recent warnings", tint: Drop.warn, order: 5) {
            DropWell {
                ForEach(Array(o.events.enumerated()), id: \.element.id) { i, e in
                    DropRow(index: i) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                (Text("\(e.reason) · ")
                                    .font(Drop.mono(11, .medium))
                                    .foregroundStyle(Drop.warn)
                                 + Text("\(e.namespace)/")
                                    .font(Drop.mono(10))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
                                 + Text(e.object)
                                    .font(Drop.mono(11, .medium))
                                    .foregroundStyle(Theme.textPrimary))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(e.age)
                                    .font(Drop.mono(10))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                            }
                            if !e.message.isEmpty {
                                Text(e.message)
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
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
