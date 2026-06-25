import AppKit
import SwiftUI

/// Scrollback search overlay (⌘F). Snapshots the active pane's
/// scrollback when opened, then filters lines client-side as the user
/// types. ↑/↓ moves the highlight through matches; Enter scrolls the
/// terminal to the selected match (and closes the overlay); clicking
/// a row also scrolls to that match.
struct SearchOverlay: View {
    @EnvironmentObject var state: AppState
    @FocusState private var queryFocused: Bool
    @State private var selectedLineNo: Int?
    // Memoized scan of the (fixed) snapshot. Recomputed only when the
    // query changes — moving the selection or hovering a row must not
    // re-scan thousands of lines.
    @State private var matches: [SearchMatch] = []

    var body: some View {
        VStack(spacing: 0) {
            inputBar
            Divider().opacity(0.4)
            results
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .overlay(
            // Glass top-edge highlight.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.32), .clear],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 10)
        .frame(maxWidth: 560)
        .onAppear {
            // Defer + re-assert: a synchronous @FocusState set in
            // onAppear is unreliable. The TextField may not be mounted
            // and the window may not be key yet, since the ⌘F path calls
            // makeFirstResponder(nil) right before this.
            DispatchQueue.main.async { queryFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                queryFocused = true
            }
            // Reopening can carry a query forward; seed the cache.
            matches = computeMatches()
        }
    }

    // MARK: - Sub-views

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .font(.system(size: 13, weight: .medium))
            TextField("Search scrollback…", text: Binding(
                get: { state.searchQuery },
                set: { state.searchQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .focused($queryFocused)
            .font(.system(size: 14, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .onSubmit { jumpToSelectedMatch() }
            .onChange(of: state.searchQuery) { _, _ in
                selectedLineNo = nil
                matches = computeMatches()
            }
            .background(ArrowKeyCatcher(
                onUp: { moveSelection(by: -1) },
                onDown: { moveSelection(by: +1) }
            ))

            if !matches.isEmpty {
                Text("\(matches.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var results: some View {
        if state.searchQuery.isEmpty {
            placeholder("Type to search the current pane's scrollback.")
        } else if matches.isEmpty {
            placeholder("Nothing matches “\(state.searchQuery)”.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches, id: \.lineNo) { match in
                            SearchMatchRow(
                                match: match,
                                query: state.searchQuery,
                                isSelected: match.lineNo == effectiveSelection,
                                onTap: { jump(to: match) }
                            )
                            .id(match.lineNo)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
                .onChange(of: effectiveSelection) { _, newValue in
                    if let n = newValue {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(n, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(20)
    }

    private var panelBackground: some View {
        OverlayPanelBackground(cornerRadius: 14)
    }

    // MARK: - Search

    private func computeMatches() -> [SearchMatch] {
        let q = state.searchQuery
        guard !q.isEmpty else { return [] }
        var hits: [SearchMatch] = []
        // Snapshot is captured at toggleSearch() time so it can't shift
        // under the user's typing. enumerated() gives us 0-based line
        // numbers; we display 1-based.
        for (i, raw) in state.searchSnapshot
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .enumerated() {
            let line = String(raw)
            // Skip blank lines for noise reduction.
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if line.range(of: q, options: .caseInsensitive) != nil {
                hits.append(SearchMatch(lineNo: i + 1, text: line))
                if hits.count >= 500 { break }   // soft cap on huge scrollbacks
            }
        }
        return hits
    }

    /// The selection that actually drives the highlight + scroll. If the
    /// user hasn't moved the cursor yet, default to the first match so
    /// Enter has a sensible target.
    private var effectiveSelection: Int? {
        if let n = selectedLineNo, matches.contains(where: { $0.lineNo == n }) {
            return n
        }
        return matches.first?.lineNo
    }

    private func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let current = effectiveSelection ?? matches.first!.lineNo
        guard let idx = matches.firstIndex(where: { $0.lineNo == current }) else {
            selectedLineNo = matches.first?.lineNo
            return
        }
        let next = max(0, min(matches.count - 1, idx + delta))
        selectedLineNo = matches[next].lineNo
    }

    private func jumpToSelectedMatch() {
        guard let n = effectiveSelection,
              let match = matches.first(where: { $0.lineNo == n }) else { return }
        jump(to: match)
    }

    /// Scroll the active pane's terminal viewport to the match's row and
    /// close the search overlay. libghostty's `scroll_to_row:N` action
    /// uses an absolute row index where 0 is the earliest scrollback row,
    /// which matches our snapshot's line numbering exactly (since we
    /// captured the snapshot with `POINT_SCREEN` starting at top-left).
    private func jump(to match: SearchMatch) {
        let row = max(0, match.lineNo - 1)
        state.selectedTab?.paneTree.activePane?.controller?
            .performBindingAction("scroll_to_row:\(row)")
        // Close the overlay so the user can see the line we scrolled to.
        state.toggleSearch()
    }
}

/// Catches ↑/↓ key presses inside a SwiftUI view. SwiftUI's onKeyPress
/// only catches arrow keys on macOS 14+ when the view has focus we
/// don't own (the TextField does), so we install a local event monitor
/// scoped to the window the view is in.
private struct ArrowKeyCatcher: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onUp = onUp
        v.onDown = onDown
        return v
    }
    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onUp = onUp
        nsView.onDown = onDown
    }

    final class CatcherView: NSView {
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, let win = self.window, event.window === win else {
                    return event
                }
                switch event.keyCode {
                case 126: self.onUp?();   return nil   // ↑
                case 125: self.onDown?(); return nil   // ↓
                default:  return event
                }
            }
        }

        isolated deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

struct SearchMatch: Hashable {
    let lineNo: Int
    let text: String
}

private struct SearchMatchRow: View {
    let match: SearchMatch
    let query: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(match.lineNo)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 36, alignment: .trailing)

            highlighted(match.text, query: query)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if hovering || isSelected {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.white.opacity(0.18) : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return Theme.accentSoft }
        if hovering { return Color.white.opacity(0.05) }
        return .clear
    }

    /// Build an AttributedString that highlights every case-insensitive
    /// occurrence of `query` inside `s`.
    private func highlighted(_ s: String, query: String) -> Text {
        guard !query.isEmpty else { return Text(s) }
        var attributed = AttributedString(s)
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...]
                .range(of: query, options: .caseInsensitive) {
            attributed[range].foregroundColor = .black
            attributed[range].backgroundColor = Theme.accent
            attributed[range].font = .system(size: 12, weight: .bold,
                                              design: .monospaced)
            searchStart = range.upperBound
        }
        return Text(attributed)
    }
}
