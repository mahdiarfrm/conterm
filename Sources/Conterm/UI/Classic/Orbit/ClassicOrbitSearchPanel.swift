import AppKit
import SwiftUI

/// Classic interface style. `OrbitSearchPanel`'s panels as they are drawn when
/// `Preferences.interfaceStyle` is `.classic`; the Liquid Drop counterparts
/// are the `drop…` members in `OrbitSearchPanel.swift`, and `OrbitPanelStyles.swift`
/// picks between them.
extension OrbitSearchPanel {

    var classicBody: some View {
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

    var classicBar: some View {
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

    var classicList: some View {
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
                .padding(8)
            }
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

    func classicRow(_ hit: OrbitOverlay.SearchItem, active: Bool) -> some View {
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
