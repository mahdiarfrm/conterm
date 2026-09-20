import AppKit
import SwiftUI

/// The arrows and Return, on their way from the key monitor to the search
/// field.
///
/// Deliberately *not* `AppState`: the map observes that, so every arrow key
/// republished it and re-evaluated the whole canvas — the graph, the
/// simulation step, every card — before the highlight could move. Holding the
/// key down made that per-repeat, which is why it crawled. Only the panel
/// watches this, so a keypress costs the panel and nothing else.
@MainActor
final class OrbitSearchBus: ObservableObject {
    static let shared = OrbitSearchBus()
    /// A signed running counter; the panel applies the difference, so one value
    /// carries both direction and repeats.
    @Published var nav = 0
    @Published var runTick = 0
}

/// The map's search field: a bar and a result list on two detached surfaces —
/// drops in the ⌘K palette's proportions in Liquid Drop, the palette's glass
/// bubbles in Classic (`UI/Classic/Orbit/ClassicOrbitSearchPanel.swift`).
/// State and matching are shared; `OrbitPanelStyles.swift` picks the chrome.
///
/// Its own `View` rather than a slice of `OrbitOverlay.body`, for the same
/// reason the bus exists — typing here must not cost a redraw of the graph.
struct OrbitSearchPanel: View {
    /// Everything findable, built by the map when the field opens. Passed in as
    /// a value because gathering it reads the shell history off disk, which is
    /// not something a keystroke may do.
    let corpus: [OrbitOverlay.SearchItem]
    let onCommit: (OrbitOverlay.SearchItem) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject var prefs: Preferences
    @ObservedObject var bus = OrbitSearchBus.shared

    @State var query = ""
    @State var index = 0
    @State var results: [OrbitOverlay.SearchItem] = []
    @FocusState var fieldFocused: Bool
    var dropBody: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(OrbitPanel.modalDim).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 12) {
                bar.orbitPanel(cornerRadius: 32, bevel: 12, dim: OrbitPanel.modalDim)
                if !results.isEmpty {
                    list.orbitPanel(cornerRadius: 28, bevel: 16, dim: OrbitPanel.modalDim,
                                    fadesEdges: true)
                } else if !query.isEmpty {
                    Text("Nothing matches “\(query)”.")
                        .font(Drop.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 26).padding(.vertical, 22)
                        .orbitPanel(cornerRadius: 28, bevel: 16, dim: OrbitPanel.modalDim)
                }
            }
            .frame(maxWidth: 580)
            .padding(.top, 84)
        }
        .onAppear {
            query = ""; index = 0; results = corpus
            // Claiming focus synchronously races the field's mount and loses,
            // leaving the bar deaf until it is clicked.
            DispatchQueue.main.async { fieldFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fieldFocused = true }
        }
        // The corpus is gathered by the map when the field opens, which lands a
        // render *after* this view mounts — so `onAppear` alone showed whatever
        // had been gathered the previous time it was opened, and on the first
        // open showed nothing at all.
        .onChange(of: corpus) { _, _ in rank() }
        .onChange(of: query) { _, _ in rank() }
        .onChange(of: bus.nav) { old, new in move(by: new - old) }
        .onChange(of: bus.runTick) { _, _ in commitFocused() }
    }

    // MARK: - Matching

    func rank() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = corpus; index = 0; return }
        var ranked: [(OrbitOverlay.SearchItem, Int)] = []
        for item in corpus {
            // A subtitle match is real but weaker than a name match — you
            // usually type the name.
            let byLabel = OrbitOverlay.searchRank(item.label, q)
            let bySub = item.subtitle.flatMap { OrbitOverlay.searchRank($0, q) }.map { $0 + 4 }
            guard let rank = [byLabel, bySub].compactMap({ $0 }).min() else { continue }
            ranked.append((item, rank))
        }
        results = ranked.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.label.count != $1.0.label.count { return $0.0.label.count < $1.0.label.count }
            return $0.0.label.localizedCaseInsensitiveCompare($1.0.label) == .orderedAscending
        }.map(\.0)
        index = 0
    }

    func move(by delta: Int) {
        guard !results.isEmpty, delta != 0 else { return }
        let n = results.count
        index = ((index + delta) % n + n) % n
    }

    func commitFocused() {
        guard let hit = results.indices.contains(index) ? results[index] : results.first
        else { return }
        onCommit(hit)
    }

    // MARK: - Chrome

    var dropBar: some View {
        HStack(spacing: 12) {
            NeonCaretField(text: $query,
                           placeholder: "Find a host, session, cluster or routine",
                           fontSize: 17, lightBackground: prefs.lightGlass)
                .frame(height: 24)
                .focused($fieldFocused)
            Spacer()
            if !results.isEmpty {
                Text("\(results.count)")
                    .font(Drop.mono(10, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("esc")
                .font(Drop.mono(10, .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Theme.stroke))
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .font(.system(size: 15, weight: .regular))
        }
        .padding(.leading, 28).padding(.trailing, 22)
        .frame(height: 64)
    }

    var dropList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, hit in
                        // No hover selection. The list scrolls under a
                        // stationary cursor, so hovering moved the highlight
                        // to whatever happened to slide beneath the pointer —
                        // which fought every arrow key and left two rows
                        // looking picked at once.
                        row(hit, active: i == index)
                            .onTapGesture { onCommit(hit) }
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 380)
            // Unanimated: held down, the arrow repeats faster than an animation
            // can finish, and the queued ones fight each other into a crawl.
            // By the row's `ForEach` identity: a lazy stack can only scroll to
            // a row it hasn't built yet through that, never through an `.id()`
            // the unbuilt row would have carried.
            .onChange(of: index) { _, i in
                guard results.indices.contains(i) else { return }
                proxy.scrollTo(results[i].id, anchor: .center)
            }
        }
    }

    func dropRow(_ hit: OrbitOverlay.SearchItem, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: hit.glyph)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.label)
                    .font(Drop.display(13.5, .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let s = hit.subtitle, !s.isEmpty, s != hit.label {
                    Text(s)
                        .font(Drop.display(10.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(hit.kind.uppercased())
                .font(Drop.mono(8.5, .medium))
                .kerning(1.2)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(.leading, 4).padding(.trailing, 14)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(active ? Theme.selectionFill : .clear))
        .contentShape(Rectangle())
    }
}
