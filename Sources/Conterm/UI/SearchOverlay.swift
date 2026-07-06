import AppKit
import SwiftUI

/// Find bar (⌘F). Terminal scope drives libghostty's search engine: the
/// renderer highlights every match, navigation scrolls the selection into
/// view, and the bar shows "k of n" from the engine's own counts — real
/// scrollback search, unaffected by line wrapping or new output.
///
/// Panes running Claude Code gain a Conversation scope that searches the
/// session transcript instead. A fullscreen (alternate-screen) session
/// keeps its conversation out of scrollback entirely, so this is the only
/// scope that can see it; results open inline, or hand off to Claude
/// Code's own transcript search.
struct SearchOverlay: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // ActivePaneReader supplies the LIVE focus so the bar can close
        // on a pane switch — observing AppState alone misses intra-tab
        // focus changes entirely.
        ActivePaneReader { active in
            if let pane = state.searchPane {
                SearchBar(pane: pane, activePaneID: active?.id)
            }
        }
    }
}

private struct SearchBar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var pane: Pane
    /// Live focus from ActivePaneReader (nil when no pane is focused).
    var activePaneID: UUID?
    @StateObject private var transcript = TranscriptSearchModel()
    @FocusState private var queryFocused: Bool
    @State private var selectedHit: Int?
    @State private var expandedHit: Int?
    /// Debounce for short terminal needles: a 1–2 character needle
    /// matches nearly everything and is the engine's most expensive
    /// case, so it waits 300 ms; three chars and up (or clearing the
    /// field) go straight through.
    @State private var pendingNeedle: DispatchWorkItem?

    private var scope: AppState.SearchScope { state.searchScope }
    private var transcriptAvailable: Bool { pane.agentTranscriptPath != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if scope == .conversation, !state.searchQuery.isEmpty {
                Divider().opacity(0.4)
                conversationResults
            }
        }
        .background(OverlayPanelBackground(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.40), radius: 18, x: 0, y: 8)
        .frame(width: scope == .conversation ? 480 : 400)
        .onAppear {
            // Defer + re-assert: a synchronous @FocusState set in
            // onAppear is unreliable — the field may not be mounted and
            // the window may not be key yet (⌘F clears first responder
            // right before this).
            DispatchQueue.main.async { queryFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                queryFocused = true
            }
            // A seeded needle (search_selection, reopened bar) must fire
            // the initial search itself — onChange only sees edits.
            if !state.searchQuery.isEmpty { queryChanged(state.searchQuery) }
        }
        .onChange(of: state.searchQuery) { _, q in queryChanged(q) }
        .onChange(of: state.searchScope) { old, new in scopeChanged(old, new) }
        .onChange(of: activePaneID) { _, newID in
            // The session is welded to its pane; a pane/tab switch ends
            // it rather than silently retargeting.
            if newID != pane.id { state.closeSearch() }
        }
        .onDisappear {
            pendingNeedle?.cancel()
        }
    }

    // MARK: - Bar

    private var bar: some View {
        HStack(spacing: 8) {
            if transcriptAvailable { scopePicker }
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .font(.system(size: 12, weight: .medium))
            TextField(scope == .terminal ? "Find in scrollback"
                                         : "Find in conversation",
                      text: Binding(
                        get: { state.searchQuery },
                        set: { state.searchQuery = $0 }
                      ))
            .textFieldStyle(.plain)
            .focused($queryFocused)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .onSubmit { submit() }
            .background(ArrowKeyCatcher(
                onUp: { arrow(up: true) },
                onDown: { arrow(up: false) }
            ))

            countBadge

            if scope == .terminal {
                navButton("chevron.up", help: "Previous match (⌘⇧G)") {
                    state.navigateSearch(next: false)
                }
                navButton("chevron.down", help: "Next match (⌘G)") {
                    state.navigateSearch(next: true)
                }
            }

            Button { state.closeSearch() } label: {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            scopeChip("Terminal", .terminal)
            scopeChip("Claude", .conversation)
        }
        .padding(2)
        .background(Capsule().fill(Theme.recessedWash))
    }

    private func scopeChip(_ label: String, _ value: AppState.SearchScope) -> some View {
        Button {
            guard state.searchScope != value else { return }
            state.searchScope = value
            SoundEffects.shared.play(.toggle)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(scope == value ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    Capsule().fill(scope == value ? Theme.selectionFill : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var countBadge: some View {
        if !state.searchQuery.isEmpty {
            Text(countText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.stroke))
                .monospacedDigit()
        }
    }

    private var countText: String {
        switch scope {
        case .terminal:
            guard let total = pane.searchTotal else { return "…" }
            if let sel = pane.searchSelected, total > 0 { return "\(sel)/\(total)" }
            return "\(total)"
        case .conversation:
            if transcript.searching { return "…" }
            return "\(transcript.hits.count)"
        }
    }

    private func navButton(_ symbol: String, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Behavior

    private func queryChanged(_ q: String) {
        selectedHit = nil
        expandedHit = nil
        switch scope {
        case .terminal:
            pendingNeedle?.cancel()
            let ctrl = pane.controller
            if q.isEmpty || q.count >= 3 {
                ctrl?.search(q)
            } else {
                let work = DispatchWorkItem { ctrl?.search(q) }
                pendingNeedle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        case .conversation:
            transcript.update(path: pane.agentTranscriptPath, query: q)
        }
    }

    private func scopeChanged(_ old: AppState.SearchScope,
                              _ new: AppState.SearchScope) {
        selectedHit = nil
        expandedHit = nil
        switch new {
        case .terminal:
            transcript.update(path: nil, query: "")
            queryChanged(state.searchQuery)
        case .conversation:
            // Leave terminal scope cleanly: drop the engine session so
            // stale highlights don't sit behind the transcript results.
            pendingNeedle?.cancel()
            pane.controller?.endSearch()
            transcript.update(path: pane.agentTranscriptPath,
                              query: state.searchQuery)
        }
    }

    private func submit() {
        switch scope {
        case .terminal:
            state.navigateSearch(next: true)
        case .conversation:
            if let sel = effectiveHit {
                expandedHit = expandedHit == sel ? nil : sel
            }
        }
    }

    private func arrow(up: Bool) {
        switch scope {
        case .terminal:
            state.navigateSearch(next: !up)
        case .conversation:
            moveHitSelection(by: up ? -1 : +1)
        }
    }

    // MARK: - Conversation results

    private var effectiveHit: Int? {
        if let s = selectedHit, transcript.hits.contains(where: { $0.id == s }) {
            return s
        }
        return transcript.hits.first?.id
    }

    private func moveHitSelection(by delta: Int) {
        let hits = transcript.hits
        guard !hits.isEmpty else { return }
        let current = effectiveHit ?? hits.first!.id
        guard let idx = hits.firstIndex(where: { $0.id == current }) else {
            selectedHit = hits.first?.id
            return
        }
        selectedHit = hits[max(0, min(hits.count - 1, idx + delta))].id
    }

    @ViewBuilder
    private var conversationResults: some View {
        if transcript.hits.isEmpty {
            Text(transcript.searching ? "Searching…"
                 : "Nothing in this conversation matches “\(state.searchQuery)”.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(16)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(transcript.hits) { hit in
                            TranscriptHitRow(
                                hit: hit,
                                query: state.searchQuery,
                                isSelected: hit.id == effectiveHit,
                                isExpanded: hit.id == expandedHit,
                                onTap: {
                                    selectedHit = hit.id
                                    expandedHit = expandedHit == hit.id ? nil : hit.id
                                })
                            .id(hit.id)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 340)
                .onChange(of: effectiveHit) { _, new in
                    if let n = new {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(n, anchor: .center)
                        }
                    }
                }
            }
            if canRevealInClaude {
                Divider().opacity(0.4)
                revealFooter
            }
        }
    }

    /// The handoff only makes sense while the session is live on the
    /// alternate screen — that's when Claude Code's own transcript mode
    /// (^O, /) can take over navigation.
    private var canRevealInClaude: Bool {
        pane.agent.phase != .idle && pane.noScrollback
    }

    private var revealFooter: some View {
        Button(action: revealInClaude) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Search inside Claude Code")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                Spacer()
                Text("^O /")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Claude Code's transcript mode and run this search there (n/N step matches)")
    }

    /// Drive Claude Code's own transcript search: ^O enters transcript
    /// mode, "/" opens its search, then the needle and Return. The
    /// delays give the TUI time to swap modes before input lands; after
    /// the jump, n/N step matches inside Claude Code itself.
    private func revealInClaude() {
        guard let ctrl = pane.controller else { return }
        let needle = state.searchQuery
        state.closeSearch()
        ctrl.performBindingAction("text:\\x0f")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            ctrl.typeText("/")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) {
            ctrl.typeText(needle)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            ctrl.sendReturn()
        }
    }
}

// MARK: - Rows

private struct TranscriptHitRow: View {
    let hit: TranscriptHit
    let query: String
    let isSelected: Bool
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: hit.message.role == .user
                      ? "person.fill" : "sparkle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(hit.message.role == .user
                                     ? Theme.textSecondary : Theme.accent)
                    .frame(width: 14)
                highlighted(hit.snippet, query: query)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let d = hit.message.date {
                    Text(Self.relative.localizedString(for: d, relativeTo: Date()))
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary
                        .opacity(hovering || isSelected ? 1 : 0))
            }
            if isExpanded {
                ScrollView {
                    highlighted(hit.message.text, query: query)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.recessedWash)
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.accentSoft
                      : hovering ? Theme.selectionFill : .clear)
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

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func highlighted(_ s: String, query: String) -> Text {
        guard !query.isEmpty else { return Text(s) }
        var attributed = AttributedString(s)
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...]
                .range(of: query, options: .caseInsensitive) {
            attributed[range].foregroundColor = .black
            attributed[range].backgroundColor = Theme.accent
            searchStart = range.upperBound
        }
        return Text(attributed)
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
