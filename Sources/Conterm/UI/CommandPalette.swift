import SwiftUI

/// Command palette. Three modes:
///   • `.commands`  — list of app commands (default, opened with ⌘K)
///   • `.notesList` — browse + filter notes (entered via "Notes" command)
///   • `.noteEdit(id)` — edit a single note's content
///
/// Arrow keys + Enter + Esc throughout. Esc unwinds one level
/// (edit → list → commands → closed).
///
/// This type owns the palette's state and logic once; its look comes in
/// two interface styles, picked by `prefs.liquidDrop`:
///  - Liquid Drop — Spotlight's proportions (`PaletteMetrics`): a capsule
///    field and, a gap below it, a results panel that hugs its rows. Each
///    is its own `LiquidDrop` (`PaletteSurface`); `PalettePresenter`
///    sequences them.
///  - Classic — two `PaletteBubble` panels and the Classic rows
///    (`UI/Classic/ClassicCommandPalette*.swift`).
struct CommandPalette: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @State var query: String = ""
    @FocusState var queryFocused: Bool
    /// Flips true one runloop after the panel mounts so the result
    /// rows cascade in (staggered by index). Only the *open* animates
    /// — typing/filtering doesn't re-cascade (rows key off this, not
    /// the query), so it never feels janky mid-search.
    @State var appeared = false
    /// Cached SSH rows. Refreshed when the user enters SSH mode in
    /// the palette so scrolling and filtering use an in-memory list
    /// instead of re-parsing the shell-history file on every body
    /// re-eval.
    @State var cachedAllSSHRows: [SSHRow] = []
    /// Omni-search results for the current non-empty query, recomputed
    /// only when `query` changes (see `onChange(of: query)`). The body
    /// re-renders on every focus-index move (arrow keys); reading this
    /// cache instead of calling `omniResults` keeps that navigation off
    /// the fuzzy-match + frecency-sort path.
    @State var cachedOmniResults: [Command] = []
    /// Index range of the "Recently used" top-picks band within
    /// `cachedOmniResults`, so the list can draw the section label +
    /// divider. nil when no row has been picked before.
    @State var cachedRecentBand: Range<Int>? = nil
    /// Refreshed each time the palette opens: SSH rows (history +
    /// ~/.ssh/config) and the active pane's directory listing, newest
    /// first. Cached so per-keystroke filtering never touches disk.
    @State var cachedCwdFiles: [CwdFile] = []
    /// Settings match-table, built lazily once per palette open; per
    /// keystroke it is only filtered, and rows materialize per match.
    @State var cachedSettingsItems: [SettingsItem] = []

    @EnvironmentObject var tabGroups: TabGroupStore
    /// Shared by every row so the selection glides (see `paletteRow`).
    @Namespace var selection
    @Environment(\.liquidRevealed) var surfaceReady

    var body: some View {
        // Two separate surfaces: the field on top and the results panel a
        // gap below. At rest, a strip of learned suggestions floats between
        // them.
        let liquid = prefs.liquidDrop
        VStack(spacing: liquid ? PaletteMetrics.gap : 10) {
            topBar
            if state.paletteMode == .commands && query.isEmpty {
                suggestionStrip
                    .padding(.vertical, liquid ? 0 : 2)
                    .transition(.opacity)
            }
            contentPanel
        }
        .frame(minWidth: liquid ? PaletteMetrics.width : nil,
               maxWidth: liquid ? PaletteMetrics.width : 600)
        .environment(\.paletteSelection, selection)
        .onAppear {
            query = ""; state.paletteFocusedIndex = 0
            appeared = false
            // Focus the field on the next runloop turn — claiming it
            // synchronously races the field's mount and loses, leaving
            // the bar deaf until clicked. The delayed retry covers the
            // slower first present of the panel. The field is live from
            // here on; only its pixels wait for the drop.
            DispatchQueue.main.async {
                queryFocused = true
                // Classic panels are there from the first frame, so the
                // rows cascade at once.
                if !prefs.liquidDrop { appeared = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                queryFocused = true
            }
            // On a drop, rows cascade once the panel under them has formed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                appeared = true
            }
            if state.paletteMode == .sshHosts { refreshSSHRowsIfNeeded() }
            // Commands mode searches across hosts + cwd files too.
            if state.paletteMode == .commands { refreshOmniSources() }
            syncTrayState(focusTray: true)
        }
        .onChange(of: state.paletteMode) { _, mode in
            // Mode change resets query + focus.
            query = ""
            state.paletteFocusedIndex = 0
            // Liquid Drop replays the row cascade on a mode change.
            if prefs.liquidDrop { appeared = false }
            DispatchQueue.main.async {
                queryFocused = true
                appeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                queryFocused = true
            }
            if mode == .sshHosts { refreshSSHRowsIfNeeded() }
            if mode == .commands { refreshOmniSources() }
            syncTrayState(focusTray: mode == .commands)
        }
        .onChange(of: query) { _, q in
            // Recompute the omni cache once per keystroke — the only place
            // the query-dependent results change. Sources (cwd files, SSH
            // rows) are refreshed on open / mode-change, before any typing.
            if q.isEmpty {
                cachedOmniResults = []
                cachedRecentBand = nil
            } else {
                let r = omniResults(for: q)
                cachedOmniResults = r.rows
                cachedRecentBand = r.recentBand
            }
            state.paletteFocusedIndex = 0
            // Typing hides the tray; clearing brings it back unfocused
            // (↑ from the list's top row climbs back in).
            syncTrayState(focusTray: false)
        }
        .onChange(of: state.paletteFocusedIndex) { _, _ in
            clampFocus()
            // Soft cursor tick when arrow-keys move the highlight.
            SoundEffects.shared.play(.paletteMove)
        }
        .onChange(of: state.paletteTrayIndex) { _, _ in
            SoundEffects.shared.play(.paletteMove)
        }
        .onChange(of: state.paletteTrayFocused) { _, _ in
            SoundEffects.shared.play(.paletteMove)
        }
        .onChange(of: state.paletteRunTick) { _, _ in handleEnter() }
        .onChange(of: state.paletteEscTick) { _, _ in handleEsc() }
        .onChange(of: state.paletteDeleteTick) { _, _ in handleDelete() }
    }

    func handleDelete() {
        switch state.paletteMode {
        case .notesList:
            // Index 0 is the always-present "New note" row, skip it.
            let i = state.paletteFocusedIndex
            guard i >= 1 else { return }
            let list = filteredNotes
            let noteIdx = i - 1
            guard noteIdx < list.count else { return }
            state.notes.delete(list[noteIdx].id)
            // Pull the focus up if we just deleted the last item.
            let newCount = filteredNotes.count + 1
            if i >= newCount {
                state.paletteFocusedIndex = max(1, newCount - 1)
            }
        case .noteEdit(let id):
            state.notes.delete(id)
            withAnimation(Theme.Spring.soft) {
                state.paletteMode = .notesList
            }
        default:
            break
        }
    }

    /// Bar bubble. Carries the mode's input field (or the groups
    /// header); note-edit has no bar — the editor is a single bubble.
    @ViewBuilder var topBar: some View {
        switch state.paletteMode {
        case .noteEdit:
            EmptyView()
        case .groups:
            if prefs.liquidDrop {
                PaletteSurface(cornerRadius: PaletteMetrics.fieldHeight / 2, bevel: 12,
                               formDelay: 0.08) {
                    groupsHeader
                }
            } else {
                classicGroupsHeader
                    .modifier(PaletteBubble(cornerRadius: 27, darken: 0.14))
            }
        case .commands:
            barBubble("Search commands, files, hosts, history… or math", ContermGlyph.iconName)
        case .notesList:
            barBubble("Search notes…", "note.text")
        case .sessions:
            barBubble("Filter sessions by tab, dir, or host…", "rectangle.3.group")
        case .agents:
            barBubble("Filter agents by tool, tab, or dir…", RobotGlyph.iconName)
        case .shellHistory:
            barBubble("Fuzzy-search your shell history…", "clock.arrow.circlepath")
        case .sshHosts:
            barBubble("Filter SSH hosts…", "network")
        case .clipboard:
            barBubble("Search recent copies…", "doc.on.clipboard")
        }
    }

    @ViewBuilder
    func barBubble(_ placeholder: String, _ icon: String) -> some View {
        if prefs.liquidDrop {
            PaletteSurface(cornerRadius: PaletteMetrics.fieldHeight / 2, bevel: 12,
                           formDelay: 0.08) {
                searchBar(placeholder: placeholder, icon: icon)
            }
        } else {
            classicSearchBar(placeholder: placeholder, icon: icon)
                .modifier(PaletteBubble(cornerRadius: 27, darken: 0.14))
        }
    }

    /// Results bubble. In commands mode an unmatched query collapses
    /// it entirely, leaving the bar floating alone.
    @ViewBuilder var contentPanel: some View {
        if !(state.paletteMode == .commands && filteredCommands.isEmpty) {
            if prefs.liquidDrop {
                PaletteSurface(cornerRadius: PaletteMetrics.panelRadius, bevel: 18,
                               fadesEdges: true) {
                    modeContent
                }
            } else {
                modeContent
                    .modifier(PaletteBubble(cornerRadius: 26))
            }
        }
    }

    /// The current mode's list or editor, without its surface.
    var modeContent: some View {
        VStack(spacing: 0) {
            switch state.paletteMode {
            case .commands:
                commandsView
            case .notesList:
                notesListView
            case .noteEdit(let id):
                noteEditView(id: id)
            case .sessions:
                sessionsView
            case .agents:
                agentsView
            case .shellHistory:
                shellHistoryView
            case .sshHosts:
                sshHostsView
            case .clipboard:
                clipboardView
            case .groups:
                groupsView
            }
        }
    }

    // MARK: - Esc / Enter handling

    func handleEsc() {
        switch state.paletteMode {
        case .commands:
            state.togglePalette()
        case .notesList:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        case .noteEdit:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .notesList }
        case .sessions:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        case .agents:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        case .shellHistory:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        case .sshHosts:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        case .clipboard:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        case .groups:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        }
    }

    func handleEnter() {
        switch state.paletteMode {
        case .commands:        runFocusedCommand();       SoundEffects.shared.play(.paletteConfirm)
        case .notesList:       openFocusedNote();         SoundEffects.shared.play(.paletteConfirm)
        case .noteEdit:        break  // Return passes through to the editor
        case .sessions:        jumpToFocusedSession();    SoundEffects.shared.play(.paletteConfirm)
        case .agents:          jumpToFocusedAgent();      SoundEffects.shared.play(.paletteConfirm)
        case .shellHistory:    runFocusedHistoryEntry();  SoundEffects.shared.play(.paletteConfirm)
        case .sshHosts:        connectFocusedSSHHost();   SoundEffects.shared.play(.paletteConfirm)
        case .clipboard:       pasteFocusedClipboardEntry(); SoundEffects.shared.play(.paletteConfirm)
        case .groups:          break  // managed via inline buttons
        }
    }

    func clampFocus() {
        let count: Int
        switch state.paletteMode {
        case .commands:  count = filteredCommands.count
        case .notesList: count = filteredNotes.count + 1  // +1 for "new note"
        case .noteEdit:  return
        case .sessions:  count = filteredSessions.count
        case .agents:    count = filteredAgents.count
        case .shellHistory: count = filteredShellHistory.count
        case .sshHosts:     count = filteredSSHRows.count
        case .clipboard:    count = filteredClipboard.count
        case .groups:    return
        }
        guard count > 0 else { state.paletteFocusedIndex = 0; return }
        var i = state.paletteFocusedIndex % count
        if i < 0 { i += count }
        if i != state.paletteFocusedIndex { state.paletteFocusedIndex = i }
    }

    // MARK: - Building blocks

    func searchBar(placeholder: String, icon: String) -> some View {
        // Spotlight's order: the text leads from the inset, the mode's glyph
        // sits in the trailing slot.
        HStack(spacing: 12) {
            NeonCaretField(text: $query, placeholder: placeholder,
                           fontSize: PaletteMetrics.fieldTextSize,
                           lightBackground: prefs.lightGlass)
                .frame(height: 26)
            Spacer(minLength: 0)
            modeKeyHints
            Group {
                if icon == RobotGlyph.iconName {
                    RobotGlyph(color: Theme.textSecondary, size: 18)
                } else if icon == ContermGlyph.iconName {
                    ContermGlyph().fill(Theme.textSecondary).frame(width: 22, height: 22)
                } else {
                    Image(systemName: icon)
                        .foregroundStyle(Theme.textSecondary)
                        .font(.system(size: 16, weight: .regular))
                }
            }
            .frame(width: 28)
        }
        .padding(.leading, PaletteMetrics.fieldInset)
        .padding(.trailing, 22)
        .frame(height: PaletteMetrics.fieldHeight)
    }

    /// The key hints the current mode shows at the bar's trailing edge.
    @ViewBuilder var modeKeyHints: some View {
        switch state.paletteMode {
        case .notesList:
            HStack(spacing: 4) {
                keyHint("⌘⌫ delete")
                keyHint("esc")
            }
        case .noteEdit:
            EmptyView()
        case .commands, .sessions, .agents, .shellHistory, .sshHosts, .clipboard, .groups:
            keyHint("esc")
        }
    }

    func keyHint(_ s: String) -> some View {
        let liquid = prefs.liquidDrop
        return Text(s)
            .font(liquid ? Drop.mono(10.5, .medium)
                         : .system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, liquid ? 8 : 6).padding(.vertical, liquid ? 3 : 2)
            .background(Capsule().fill(Theme.stroke))
    }

    // MARK: - Style-dependent metrics

    /// Inset of a mode's list inside its panel.
    var panelPadding: CGFloat { prefs.liquidDrop ? PaletteMetrics.panelPadding : 8 }
    /// Height a mode's list may reach before it scrolls.
    var listMaxHeight: CGFloat { prefs.liquidDrop ? PaletteMetrics.listMaxHeight : 360 }
}

// MARK: - Presenter

/// Mounts the palette over a dim and sequences its drops the way
/// `BriefingPresenter` does for cards: mount closed for a frame, open, let
/// the content through once the drops have formed; on dismissal hide the
/// content, let the drops collapse, unmount. The field is mounted — and
/// first responder — from the first frame, so keys typed while the drop is
/// still forming land in the query.
struct PalettePresenter: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mounted = false
    @State private var open = false
    @State private var revealed = false
    /// Bumped on every open/close so a deferred step can't act on a later one.
    @State private var generation = 0
    /// Identity of the mounted palette. A reopen during the collapse gets a
    /// fresh palette (query reset, focus reclaimed) instead of the dying one.
    @State private var session = 0

    var body: some View {
        Group {
            if mounted {
                ZStack {
                    Color.black.opacity(PaletteMetrics.sceneDim)
                        .ignoresSafeArea()
                        .onTapGesture { state.togglePalette() }
                        .opacity(open ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: open)
                    VStack {
                        CommandPalette()
                            .id(session)
                            .environment(\.liquidDropOpen, open)
                            .environment(\.liquidRevealed, revealed)
                            .padding(.top, 96)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { if state.paletteOpen { present() } }
        .onChange(of: state.paletteOpen) { _, isOpen in
            if isOpen { present() } else { dismiss() }
        }
    }

    private func present() {
        generation += 1
        let gen = generation
        session += 1
        mounted = true
        revealed = false
        DispatchQueue.main.async {
            if gen == generation { open = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.04 : 0.10)) {
            if gen == generation { revealed = true }
        }
    }

    private func dismiss() {
        generation += 1
        let gen = generation
        revealed = false
        open = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            if gen == generation { mounted = false }
        }
    }
}
