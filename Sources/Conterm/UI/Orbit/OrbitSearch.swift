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

    /// One findable thing. Built once when the field opens — the host list
    /// comes from the shell history on disk, so ranking must never be the thing
    /// that reads it.
    struct SearchItem: Identifiable, Equatable {
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
        /// Where this sits with no query typed: live work first, then
        /// inventory. Ranking only reorders within what matches.
        let natural: Int
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

    // MARK: - Corpus

    /// Everything findable. Built when the field opens and on nothing else:
    /// `SSHHistory.recentTargets` parses the shell history file, which is far
    /// too expensive to sit behind a per-keystroke — let alone a per-render —
    /// path.
    func refreshSearchCorpus() {
        var seen = Set<String>()
        var out: [SearchItem] = []

        func offer(_ id: String, _ label: String, _ subtitle: String?,
                   _ glyph: String, _ kind: String,
                   _ target: SearchItem.Target, _ natural: Int) {
            guard seen.insert(id).inserted else { return }
            out.append(SearchItem(id: id, label: label, subtitle: subtitle,
                                  glyph: glyph, kind: kind, target: target,
                                  natural: natural))
        }

        for n in model.nodes {
            switch n.kind {
            case .pane, .agent:
                offer(n.id, n.label, n.subtitle,
                      n.status == .neutral ? "terminal" : "sparkle",
                      "Session", .node(n.id), 0)
            case .host(let t, let active):
                offer(n.id, n.label, t, "externaldrive.connected.to.line.below.fill",
                      "Host", .node(n.id), active ? 1 : 3)
            case .cluster(let ctx, _):
                offer(n.id, n.label, ctx, "cube.transparent", "Cluster", .node(n.id), 2)
            case .container:
                offer(n.id, n.label, n.subtitle, "shippingbox", "Container", .node(n.id), 4)
            case .vm:
                offer(n.id, n.label, n.subtitle, "macwindow.on.rectangle",
                      "VM", .node(n.id), 4)
            case .pod, .kubeNode, .podContainer:
                offer(n.id, n.label, n.subtitle, "cube", "Kubernetes", .node(n.id), 4)
            default: break
            }
        }
        for r in routines.routines {
            offer("routine:\(r.id.uuidString)", r.name,
                  "\(r.steps.count) step\(r.steps.count == 1 ? "" : "s")",
                  "list.bullet.rectangle", "Routine", .routine(r.id), 2)
        }
        // Hosts you know about but aren't connected to. These are the whole
        // point of the feature: they are inventory, they are numerous, and the
        // Live map deliberately doesn't draw them.
        for t in SSHHistory.recentTargets(limit: 60) {
            offer("host:\(t)", HostNameStore.name(for: t) ?? t, t,
                  "externaldrive.connected.to.line.below.fill", "Host", .host(t), 3)
        }

        searchCorpus = out.sorted {
            $0.natural != $1.natural ? $0.natural < $1.natural
                : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        rankSearch()
    }

    /// Filter and order the corpus for the current query. Called once per
    /// keystroke — never from `body`.
    func rankSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = searchCorpus
            searchIndex = 0
            return
        }
        var ranked: [(SearchItem, Int)] = []
        for item in searchCorpus {
            // A subtitle match is real but weaker than a name match — you
            // usually type the name.
            let byLabel = Self.searchRank(item.label, q)
            let bySub = item.subtitle.flatMap { Self.searchRank($0, q) }.map { $0 + 4 }
            guard let rank = [byLabel, bySub].compactMap({ $0 }).min() else { continue }
            ranked.append((item, rank))
        }
        searchResults = ranked.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.label.count != $1.0.label.count { return $0.0.label.count < $1.0.label.count }
            return $0.0.label.localizedCaseInsensitiveCompare($1.0.label) == .orderedAscending
        }.map(\.0)
        searchIndex = 0
    }

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

    func commitSearch(_ hit: SearchItem) {
        state.orbitSearchOpen = false
        searchQuery = ""
        searchIndex = 0
        SoundEffects.shared.play(.paletteConfirm)

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

    /// Two detached bubbles — the input bar, then the results — the same shape
    /// as the app's own command palette, so the one search here and the one
    /// everywhere else are recognisably the same object.
    @ViewBuilder
    var searchPanel: some View {
        if state.orbitSearchOpen {
            ZStack(alignment: .top) {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { state.toggleOrbitSearch() }
                VStack(spacing: 10) {
                    searchBar
                        .modifier(PaletteBubble(cornerRadius: 27, darken: 0.14))
                    if !searchResults.isEmpty {
                        searchList
                            .modifier(PaletteBubble(cornerRadius: 26))
                    } else if !searchQuery.isEmpty {
                        Text("Nothing matches “\(searchQuery)”.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .modifier(PaletteBubble(cornerRadius: 26))
                    }
                }
                .frame(maxWidth: 560)
                // Its own frame, so a wheel over the list scrolls the list
                // instead of panning the map underneath it.
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { searchFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in searchFrame = f }
                })
                .padding(.top, 84)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            .onAppear {
                searchQuery = ""
                refreshSearchCorpus()
                // Claiming focus synchronously races the field's mount and
                // loses, leaving the bar deaf until it is clicked.
                DispatchQueue.main.async { searchFieldFocused = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    searchFieldFocused = true
                }
            }
            .onDisappear { searchFrame = .zero }
            .onChange(of: searchQuery) { _, _ in rankSearch() }
            .onChange(of: state.orbitSearchNav) { old, new in
                guard !searchResults.isEmpty else { return }
                let n = searchResults.count
                searchIndex = ((searchIndex + (new - old)) % n + n) % n
                SoundEffects.shared.play(.paletteMove)
            }
            .onChange(of: state.orbitSearchRunTick) { _, _ in runSearch() }
        }
    }

    var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .font(.system(size: 15, weight: .medium))
            NeonCaretField(text: $searchQuery,
                           placeholder: "Find a host, session, cluster or routine",
                           fontSize: 16, lightBackground: prefs.lightGlass)
                .frame(height: 24)
                .focused($searchFieldFocused)
            Spacer()
            if !searchResults.isEmpty {
                Text("\(searchResults.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }
            Text("esc")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.stroke))
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    var searchList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { i, hit in
                        searchRow(hit, active: i == searchIndex)
                            .id("orbit-hit-\(i)")
                            .onTapGesture { commitSearch(hit) }
                            .onHover { if $0 { searchIndex = i } }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 380)
            .onChange(of: searchIndex) { _, i in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("orbit-hit-\(i)", anchor: .center)
                }
            }
        }
    }

    func searchRow(_ hit: SearchItem, active: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: hit.glyph)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let s = hit.subtitle, !s.isEmpty, s != hit.label {
                    Text(s)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(hit.kind.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(Theme.textSecondary.opacity(0.65))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(active ? Theme.selectionFill : .clear))
        .contentShape(Rectangle())
    }
}
