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

/// The map's search field: a bar and a result list, in the two detached glass
/// bubbles the app's command palette already uses.
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
    @ObservedObject private var bus = OrbitSearchBus.shared

    @State private var query = ""
    @State private var index = 0
    @State private var results: [OrbitOverlay.SearchItem] = []
    @FocusState private var fieldFocused: Bool
    /// The panel's rectangle, so the map's wheel catcher can hand scroll to the
    /// list instead of panning underneath it.
    @Binding var frame: CGRect

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 10) {
                bar.modifier(PaletteBubble(cornerRadius: 27, darken: 0.14))
                if !results.isEmpty {
                    list.modifier(PaletteBubble(cornerRadius: 26))
                } else if !query.isEmpty {
                    Text("Nothing matches “\(query)”.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .modifier(PaletteBubble(cornerRadius: 26))
                }
            }
            .frame(maxWidth: 560)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
                    .onDisappear { frame = .zero }
            })
            .padding(.top, 84)
        }
        .onAppear {
            query = ""; index = 0; results = corpus
            // Claiming focus synchronously races the field's mount and loses,
            // leaving the bar deaf until it is clicked.
            DispatchQueue.main.async { fieldFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fieldFocused = true }
        }
        .onChange(of: query) { _, _ in rank() }
        .onChange(of: bus.nav) { old, new in move(by: new - old) }
        .onChange(of: bus.runTick) { _, _ in commitFocused() }
    }

    // MARK: - Matching

    private func rank() {
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

    private func move(by delta: Int) {
        guard !results.isEmpty, delta != 0 else { return }
        let n = results.count
        index = ((index + delta) % n + n) % n
    }

    private func commitFocused() {
        guard let hit = results.indices.contains(index) ? results[index] : results.first
        else { return }
        onCommit(hit)
    }

    // MARK: - Chrome

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .font(.system(size: 15, weight: .medium))
            NeonCaretField(text: $query,
                           placeholder: "Find a host, session, cluster or routine",
                           fontSize: 16, lightBackground: prefs.lightGlass)
                .frame(height: 24)
                .focused($fieldFocused)
            Spacer()
            if !results.isEmpty {
                Text("\(results.count)")
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

    private var list: some View {
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
                            .id("orbit-hit-\(i)")
                            .onTapGesture { onCommit(hit) }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 380)
            // Unanimated: held down, the arrow repeats faster than an animation
            // can finish, and the queued ones fight each other into a crawl.
            .onChange(of: index) { _, i in proxy.scrollTo("orbit-hit-\(i)", anchor: .center) }
        }
    }

    private func row(_ hit: OrbitOverlay.SearchItem, active: Bool) -> some View {
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
