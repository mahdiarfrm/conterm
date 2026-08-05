import AppKit
import SwiftUI

/// Finding something on the map by typing at it. Visual scanning is fine for
/// five nodes and useless for fifty, and the graph moves — so there is no
/// remembered place to look. Type a few letters, press Return, and the map
/// brings that thing to the middle and aims the bar at it.
///
/// The corpus is deliberately wider than what is currently drawn: hosts you
/// haven't connected to, sessions in another space, routines. Committing one
/// switches to the view that can show it rather than reporting that it isn't
/// here.
extension OrbitOverlay {

    struct SearchHit: Identifiable {
        enum Target: Equatable {
            case node(String)
            case host(String)        // known target, not currently on any graph
            case routine(UUID)
        }
        let id: String
        let label: String
        let subtitle: String?
        let glyph: String
        let kind: String
        let target: Target
        /// Lower is a better match; ties break on the shorter label, so `web1`
        /// wins over `web1-staging-replica` for the query `web`.
        let rank: Int
    }

    // MARK: - Matching

    /// How well `text` answers `query`, or nil for no match at all. The order
    /// is what makes a three-letter query land somewhere useful: a name that
    /// starts with what you typed beats one that merely contains it, and a
    /// scattered subsequence is the last resort rather than the first.
    static func searchRank(_ text: String, _ query: String) -> Int? {
        let t = text.lowercased(), q = query.lowercased()
        guard !q.isEmpty else { return 0 }
        if t == q { return 0 }
        if t.hasPrefix(q) { return 1 }
        // A word boundary anywhere: `02` should find `sib-02`.
        for sep in ["-", ".", "_", " ", "@", ":", "/"] where t.contains(sep + q) { return 2 }
        if t.contains(q) { return 3 }
        return isSubsequence(q, of: t) ? 6 : nil
    }

    static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var i = needle.startIndex
        for c in hay where i < needle.endIndex && c == needle[i] {
            i = needle.index(after: i)
        }
        return i == needle.endIndex
    }

    /// Everything findable, ranked. Nodes come from the whole live model rather
    /// than the current graph — searching only what is already drawn would make
    /// the field useless in exactly the case it exists for.
    var searchHits: [SearchHit] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        var out: [SearchHit] = []

        func offer(_ id: String, _ label: String, _ subtitle: String?,
                   _ glyph: String, _ kind: String, _ target: SearchHit.Target) {
            guard seen.insert(id).inserted else { return }
            // A subtitle match is real but weaker than a name match — you
            // usually type the name.
            let byLabel = Self.searchRank(label, q)
            let bySub = subtitle.flatMap { Self.searchRank($0, q) }.map { $0 + 4 }
            guard let rank = [byLabel, bySub].compactMap({ $0 }).min() else { return }
            out.append(SearchHit(id: id, label: label, subtitle: subtitle,
                                 glyph: glyph, kind: kind, target: target, rank: rank))
        }

        for n in model.nodes {
            switch n.kind {
            case .host(let t, _):
                offer(n.id, n.label, HostNameStore.name(for: t) == nil ? t : t,
                      "externaldrive.connected.to.line.below.fill", "Host", .node(n.id))
            case .pane:
                offer(n.id, n.label, n.subtitle,
                      n.status == .neutral ? "terminal" : "sparkle", "Session", .node(n.id))
            case .agent:
                offer(n.id, n.label, n.subtitle, "sparkle", "Session", .node(n.id))
            case .cluster(let ctx, _):
                offer(n.id, n.label, ctx, "cube.transparent", "Cluster", .node(n.id))
            case .container:
                offer(n.id, n.label, n.subtitle, "shippingbox", "Container", .node(n.id))
            case .vm:
                offer(n.id, n.label, n.subtitle, "macwindow.on.rectangle", "VM", .node(n.id))
            case .pod, .kubeNode, .podContainer:
                offer(n.id, n.label, n.subtitle, "cube", "Kubernetes", .node(n.id))
            default: break
            }
        }
        // Hosts you know about but aren't connected to. These are the whole
        // point of the feature: they are inventory, they are numerous, and the
        // Live map deliberately doesn't draw them.
        for t in SSHHistory.recentTargets(limit: 60) {
            offer("host:\(t)", HostNameStore.name(for: t) ?? t, t,
                  "externaldrive.connected.to.line.below.fill", "Host", .host(t))
        }
        for r in routines.routines {
            offer("routine:\(r.id.uuidString)", r.name,
                  "\(r.steps.count) step\(r.steps.count == 1 ? "" : "s")",
                  "list.bullet.rectangle", "Routine", .routine(r.id))
        }

        return out.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.label.count != $1.label.count { return $0.label.count < $1.label.count }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    var searchResults: [SearchHit] { Array(searchHits.prefix(12)) }

    // MARK: - Committing

    /// Bring `id` to the middle of the canvas. Run twice on a delay because a
    /// node the simulation has never placed has no position yet — the first
    /// pass moves the camera to where it will be, the second corrects once the
    /// sim has actually put it somewhere.
    func centerOn(_ id: String) {
        func aim() {
            let w = sim.position(id)
            withAnimation(Theme.Spring.soft) {
                // Biased up by the deck's own band, or the node lands under it.
                pan = CGSize(width: -w.x * z, height: -w.y * z - 40)
            }
        }
        sim.wake()
        aim()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { aim() }
    }

    func runSearch() {
        guard let hit = searchResults.indices.contains(searchIndex)
                ? searchResults[searchIndex] : searchResults.first else { return }
        commitSearch(hit)
    }

    func commitSearch(_ hit: SearchHit) {
        state.orbitSearchOpen = false
        searchQuery = ""
        searchIndex = 0

        switch hit.target {
        case .routine(let id):
            guard let r = routines.routines.first(where: { $0.id == id }) else { return }
            launchValues = [:]
            launchLater = false
            withAnimation(Theme.Spring.snappy) { launchingRoutine = r }

        case .host(let target):
            // Not on any graph: Fleet is the view that draws every known host,
            // so go there rather than reporting nothing found.
            withAnimation(Theme.Spring.soft) {
                state.orbitFocusSession = nil
                spaces.currentID = nil
                autoView = "fleet"
            }
            reveal("host:\(target)") { select(target) }

        case .node(let id):
            // A focused session or a saved board hides most of the fleet, so
            // committing something outside it has to widen the view first.
            let here = liveGraph().nodes.contains { $0.id == id }
            if !here {
                withAnimation(Theme.Spring.soft) {
                    state.orbitFocusSession = nil
                    spaces.currentID = nil
                    autoView = isIdleHostNode(id) ? "fleet" : "live"
                }
            }
            reveal(id) { handleTap(id, in: liveGraph()) }
        }
    }

    /// Whether `id` names a host that isn't currently connected — Live drops
    /// those, so they can only be shown in Fleet.
    func isIdleHostNode(_ id: String) -> Bool {
        guard let n = model.nodes.first(where: { $0.id == id }) else { return id.hasPrefix("host:") }
        if case .host(_, let active) = n.kind { return !active }
        return false
    }

    /// Let the graph rebuild under the new view before aiming at something in
    /// it — `liveGraph()` is recomputed per frame, and acting on the old one
    /// selects a node the map is no longer drawing.
    func reveal(_ id: String, _ act: @escaping () -> Void) {
        sim.wake()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            act()
            centerOn(id)
        }
    }

    // MARK: - The field

    @ViewBuilder
    var searchPanel: some View {
        if state.orbitSearchOpen {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { state.toggleOrbitSearch() }
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        TextField("Find a host, session or routine", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .focused($searchFieldFocused)
                            .onSubmit { runSearch() }
                        if !searchQuery.isEmpty {
                            Text("\(searchHits.count)")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(chromeFill(prefs)))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)

                    if !searchResults.isEmpty {
                        Divider().opacity(0.35)
                        VStack(spacing: 0) {
                            ForEach(Array(searchResults.enumerated()), id: \.element.id) { i, hit in
                                searchRow(hit, active: i == searchIndex)
                                    .onTapGesture { commitSearch(hit) }
                            }
                        }
                        .padding(.vertical, 5)
                    } else if !searchQuery.isEmpty {
                        Divider().opacity(0.35)
                        Text("Nothing by that name")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                .frame(width: 460)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(prefs.lightGlass ? Color.white.opacity(0.92) : Color.black.opacity(0.88)))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 34, y: 16)
                .padding(.top, 96)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            .onAppear { searchFieldFocused = true }
            // Typing narrows the list under the cursor; an index left pointing
            // past the end would commit nothing.
            .onChange(of: searchQuery) { _, _ in searchIndex = 0 }
            .onChange(of: state.orbitSearchNav) { old, new in
                guard !searchResults.isEmpty else { return }
                let n = searchResults.count
                searchIndex = ((searchIndex + (new - old)) % n + n) % n
            }
            .onChange(of: state.orbitSearchRunTick) { _, _ in runSearch() }
        }
    }

    func searchRow(_ hit: SearchHit, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hit.glyph)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.label)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let s = hit.subtitle, !s.isEmpty, s != hit.label {
                    Text(s)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(hit.kind.uppercased())
                .font(OrbitFont.face(8)).tracking(0.5)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, 13).padding(.vertical, 6.5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(active ? Theme.accent.opacity(0.16) : .clear)
            .padding(.horizontal, 6))
        .contentShape(Rectangle())
    }
}
