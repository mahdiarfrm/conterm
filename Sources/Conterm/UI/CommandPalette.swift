import SwiftUI

/// Command palette. Three modes:
///   • `.commands`  — list of app commands (default, opened with ⌘K)
///   • `.notesList` — browse + filter notes (entered via "Notes" command)
///   • `.noteEdit(id)` — edit a single note's content
///
/// Arrow keys + Enter + Esc throughout. Esc unwinds one level
/// (edit → list → commands → closed).
struct CommandPalette: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @State private var query: String = ""
    @FocusState private var queryFocused: Bool
    /// Flips true one runloop after the panel mounts so the result
    /// rows cascade in (staggered by index). Only the *open* animates
    /// — typing/filtering doesn't re-cascade (rows key off this, not
    /// the query), so it never feels janky mid-search.
    @State private var appeared = false
    /// Cached SSH rows. Refreshed when the user enters SSH mode in
    /// the palette so scrolling and filtering use an in-memory list
    /// instead of re-parsing the shell-history file on every body
    /// re-eval.
    @State private var cachedAllSSHRows: [SSHRow] = []

    var body: some View {
        // Two detached glass bubbles: a thick input bar on top and
        // the results panel below, separated by a gap rather than an
        // in-panel divider. At rest, a strip of learned suggestion
        // bubbles floats between them.
        VStack(spacing: 10) {
            topBar
            if state.paletteMode == .commands && query.isEmpty {
                suggestionStrip
                    .padding(.vertical, 2)
                    .transition(.opacity)
            }
            contentPanel
        }
        .frame(maxWidth: 600)
        .onAppear {
            query = ""; state.paletteFocusedIndex = 0
            appeared = false
            // Focus the field on the next runloop turn — claiming it
            // synchronously races the field's mount and loses, leaving
            // the bar deaf until clicked. The delayed retry covers the
            // slower first present of the panel.
            DispatchQueue.main.async {
                appeared = true
                queryFocused = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                queryFocused = true
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
            DispatchQueue.main.async { queryFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                queryFocused = true
            }
            if mode == .sshHosts { refreshSSHRowsIfNeeded() }
            if mode == .commands { refreshOmniSources() }
            syncTrayState(focusTray: mode == .commands)
        }
        .onChange(of: query) { _, _ in
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

    private func handleDelete() {
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
    @ViewBuilder private var topBar: some View {
        switch state.paletteMode {
        case .noteEdit:
            EmptyView()
        case .groups:
            groupsHeader
                .modifier(PaletteBubble(cornerRadius: 27, darken: 0.14))
        case .commands:
            barBubble("Search commands, files, hosts, history… or math", "magnifyingglass")
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
        }
    }

    private func barBubble(_ placeholder: String, _ icon: String) -> some View {
        searchBar(placeholder: placeholder, icon: icon)
            .modifier(PaletteBubble(cornerRadius: 27, darken: 0.14))
    }

    /// Results bubble. In commands mode an unmatched query collapses
    /// it entirely, leaving the bar floating alone.
    @ViewBuilder private var contentPanel: some View {
        if !(state.paletteMode == .commands && filteredCommands.isEmpty) {
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
                case .groups:
                    groupsView
                }
            }
            .modifier(PaletteBubble(cornerRadius: 26))
        }
    }

    // MARK: - Esc / Enter handling

    private func handleEsc() {
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
        case .groups:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        }
    }

    private func handleEnter() {
        switch state.paletteMode {
        case .commands:        runFocusedCommand();       SoundEffects.shared.play(.paletteConfirm)
        case .notesList:       openFocusedNote();         SoundEffects.shared.play(.paletteConfirm)
        case .noteEdit:        break  // Return passes through to the editor
        case .sessions:        jumpToFocusedSession();    SoundEffects.shared.play(.paletteConfirm)
        case .agents:          jumpToFocusedAgent();      SoundEffects.shared.play(.paletteConfirm)
        case .shellHistory:    runFocusedHistoryEntry();  SoundEffects.shared.play(.paletteConfirm)
        case .sshHosts:        connectFocusedSSHHost();   SoundEffects.shared.play(.paletteConfirm)
        case .groups:          break  // managed via inline buttons
        }
    }

    private func clampFocus() {
        let count: Int
        switch state.paletteMode {
        case .commands:  count = filteredCommands.count
        case .notesList: count = filteredNotes.count + 1  // +1 for "new note"
        case .noteEdit:  return
        case .sessions:  count = filteredSessions.count
        case .agents:    count = filteredAgents.count
        case .shellHistory: count = filteredShellHistory.count
        case .sshHosts:     count = filteredSSHRows.count
        case .groups:    return
        }
        guard count > 0 else { state.paletteFocusedIndex = 0; return }
        var i = state.paletteFocusedIndex % count
        if i < 0 { i += count }
        if i != state.paletteFocusedIndex { state.paletteFocusedIndex = i }
    }

    // MARK: - Commands mode

    @ViewBuilder private var commandsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                        CommandRow(
                            command: command,
                            index: index,
                            isFocused: !state.paletteTrayFocused
                                && index == state.paletteFocusedIndex
                        )
                        .id("cmd-\(index)")
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(
                            .spring(response: 0.42, dampingFraction: 0.82)
                                .delay(min(Double(index) * 0.028, 0.22)),
                            value: appeared)
                        .onTapGesture { runCommand(command) }
                        .onHover { hovering in
                            if hovering && state.paletteHoverArmed {
                                state.paletteTrayFocused = false
                                state.paletteFocusedIndex = index
                            }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onChange(of: state.paletteFocusedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("cmd-\(i)", anchor: .center)
                }
            }
        }
    }

    /// What the default ⌘K view shows. Empty query: learned top picks
    /// first, then the command list. Any query: a unified search
    /// across commands, SSH hosts, recent files in the pane's cwd,
    /// shell history, and notes — plus a live calculator row when the
    /// query is arithmetic. Everything is synthesized into `Command`
    /// rows so focus, Enter, and rendering need no special cases.
    private var filteredCommands: [Command] {
        // Empty query keeps the command list in its configured order —
        // learned picks live in the suggestion strip above, not here.
        guard !query.isEmpty else { return commands }
        return omniResults(for: query)
    }

    // MARK: - Omni search

    private struct CwdFile {
        let name: String
        let path: String
        let mtime: Date
    }

    /// Refreshed each time the palette opens: SSH rows (history +
    /// ~/.ssh/config) and the active pane's directory listing, newest
    /// first. Cached so per-keystroke filtering never touches disk.
    @State private var cachedCwdFiles: [CwdFile] = []

    private func refreshOmniSources() {
        refreshSSHRowsIfNeeded()
        cachedCwdFiles = Self.loadRecentFiles(
            in: state.selectedTab?.paneTree.activePane?.cwd)
    }

    private static func loadRecentFiles(in cwd: String?) -> [CwdFile] {
        guard let cwd, !cwd.isEmpty else { return [] }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: cwd),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items
            .compactMap { url -> CwdFile? in
                guard let m = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return nil }
                return CwdFile(name: url.lastPathComponent,
                               path: url.path, mtime: m)
            }
            .sorted { $0.mtime > $1.mtime }
            .prefix(200)
            .map { $0 }
    }

    private func omniResults(for q: String) -> [Command] {
        let ql = q.lowercased()
        var rows: [Command] = []

        rows += commands.filter { $0.title.lowercased().contains(ql) }

        // SSH hosts are a small set — show every match. History and
        // files can be huge, so those stay capped (the list scrolls,
        // but a thousand-row dump would bury the other sources).
        rows += cachedAllSSHRows
            .filter {
                $0.host.alias.lowercased().contains(ql)
                || ($0.host.hostname?.lowercased().contains(ql) ?? false)
            }
            .map { sshResultRow($0.host) }

        rows += cachedCwdFiles
            .filter { $0.name.lowercased().contains(ql) }
            .prefix(8)
            .map(fileResultRow)

        rows += Self.history
            .filter { $0.command.lowercased().contains(ql) }
            .prefix(8)
            .map(historyResultRow)

        rows += state.notes.filtered(q).prefix(5).map(noteResultRow)

        // Learned ordering: anything the user keeps picking floats up;
        // untouched rows keep their source order (stable sort). Score
        // each row once up front — recomputing inside the comparator
        // would call score() (Date + pow) O(n·log n) times per keystroke.
        let now = Date()
        let ranked = rows.enumerated()
            .map { (offset: $0.offset, element: $0.element,
                    score: FrecencyStore.shared.score($0.element.id, now: now)) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.offset < b.offset
            }
            .map(\.element)

        // The calculator/converter answer always leads — it's the one
        // result the user can read without selecting anything.
        if let a = QuickMath.answer(q) {
            return [calcResultRow(expression: q, answer: a)] + ranked
        }
        return ranked
    }

    private func calcResultRow(expression: String,
                               answer: (display: String, insert: String)) -> Command {
        let expr = expression.trimmingCharacters(in: .whitespaces)
        // Title carries "expr = answer"; CommandRow renders the
        // expression dim and light, the answer prominent.
        return Command(id: "calc", icon: "equal.circle",
                       title: "\(expr) = \(answer.display)",
                       subtitle: "Calculator · ↩ types the result into the terminal",
                       shortcut: "",
                       run: { [weak state] in
                           guard let state else { return }
                           Self.insertInActivePane(state: state,
                                                   text: answer.insert)
                       })
    }

    private func sshResultRow(_ host: SSHHost) -> Command {
        Command(id: "ssh.\(host.alias)", icon: "network",
                title: host.alias,
                subtitle: "SSH · \(host.hostname ?? "connect in a new tab")",
                shortcut: "",
                run: { connectToSSHHost(host) })
    }

    private func fileResultRow(_ f: CwdFile) -> Command {
        Command(id: "file.\(f.path)", icon: "doc",
                title: f.name,
                subtitle: "File · \(Self.ageFormatter.localizedString(for: f.mtime, relativeTo: Date())) · ↩ types the path",
                shortcut: "",
                run: { [weak state] in
                    guard let state else { return }
                    Self.insertInActivePane(state: state,
                                            text: shellQuote(f.path))
                })
    }

    private func historyResultRow(_ entry: HistoryEntry) -> Command {
        Command(id: "hist.\(entry.command)", icon: "clock.arrow.circlepath",
                title: entry.command,
                subtitle: "History · run in this pane",
                shortcut: "",
                run: { runHistory(entry) })
    }

    private func noteResultRow(_ note: Note) -> Command {
        let firstLine = note.content
            .split(separator: "\n", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return Command(id: "note.\(note.id.uuidString)", icon: "note.text",
                       title: firstLine.isEmpty ? "Untitled note" : firstLine,
                       subtitle: "Note · open in editor",
                       shortcut: "",
                       run: {
                           withAnimation(Theme.Spring.soft) {
                               state.paletteMode = .noteEdit(noteID: note.id)
                           }
                       })
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// The suggestion strip's seven picks: the strongest frecency keys,
    /// resolved back into rows; keys whose target no longer exists
    /// resolve to nil and drop out. Until the learned picks fill all
    /// seven slots, the core destinations pad the strip.
    private func suggestionRows() -> [Command] {
        var rows: [Command] = []
        var seen = Set<String>()
        for key in FrecencyStore.shared.top(20) where rows.count < 7 {
            if let row = resolveSuggestion(key),
               seen.insert(row.id).inserted {
                rows.append(row)
            }
        }
        for id in ["sessions", "agents", "notes", "ssh_hosts", "shell_history",
                   "tab_groups", "settings", "tabs_orientation", "new_tab",
                   "reveal_finder"]
        where rows.count < 7 {
            if !seen.contains(id),
               let c = commands.first(where: { $0.id == id }) {
                seen.insert(id)
                rows.append(c)
            }
        }
        return rows
    }

    /// Mirror the tray's visibility into AppState so the event
    /// monitor can route ↑/↓/←/→ between the two zones.
    private func syncTrayState(focusTray: Bool) {
        let visible = state.paletteMode == .commands && query.isEmpty
        state.paletteTrayCount = visible ? suggestionRows().count : 0
        if state.paletteTrayCount == 0 {
            state.paletteTrayFocused = false
        } else if focusTray {
            state.paletteTrayFocused = true
            state.paletteTrayIndex = 0
        }
        if state.paletteTrayIndex >= max(state.paletteTrayCount, 1) {
            state.paletteTrayIndex = 0
        }
    }

    /// One glass tray of the five learned picks, sitting between the
    /// search bar and the results panel. The caption is a left-hand
    /// cell rather than a header row, so the tray stays exactly one
    /// segment tall. ←/→ walk the segments; ↓ drops into the list.
    @ViewBuilder private var suggestionStrip: some View {
        let rows = suggestionRows()
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Header pinned top-left: the sparkles glyph and a label
                // whose letters roll up out of a blur, clock-digit style.
                // Each element reveals itself, so there's no container-wide
                // animation fighting the per-circle ones.
                HStack(spacing: 6) {
                    RollUpReveal(delay: 0.04) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.highlight, Theme.accentOnDark],
                                               startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.accentOnDark.opacity(0.5), radius: 4)
                    }
                    // Fixed-light over the bare terminal (no panel bed). A
                    // legibility shadow keeps it readable over a bright
                    // terminal too, where plain white would wash out.
                    RollUpText(
                        "Suggestions",
                        font: .system(size: 11, weight: .semibold, design: .rounded),
                        color: Color.white.opacity(0.7),
                        startDelay: 0.10)
                    .shadow(color: .black.opacity(0.55), radius: 2.5)
                }
                .padding(.leading, 6)

                // Each pick is its own glass circle in an equal-width cell,
                // so the row spreads evenly across the palette; each rolls
                // up out of a blur, staggered down the row.
                HStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, cmd in
                        CircleSuggestion(
                            command: cmd,
                            index: i,
                            isFocused: state.paletteTrayFocused
                                && state.paletteTrayIndex == i
                        ) {
                            runCommand(cmd)
                        }
                        .frame(maxWidth: .infinity)
                        .onHover { hovering in
                            if hovering && state.paletteHoverArmed {
                                state.paletteTrayFocused = true
                                state.paletteTrayIndex = i
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // Soft dark scrim under the fixed-light header + labels so they
            // stay legible over a bright terminal, where the shadow alone
            // wasn't enough. Feathered by its own shadow → a glow-bed, not a
            // hard box; invisible over a dark terminal.
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .shadow(color: .black.opacity(0.3), radius: 12)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resolveSuggestion(_ key: String) -> Command? {
        if key == "calc" { return nil }
        if key.hasPrefix("ssh.") {
            let alias = String(key.dropFirst(4))
            let host = cachedAllSSHRows.first { $0.host.alias == alias }?.host
                ?? SSHHost(alias: alias, hostname: nil)
            return sshResultRow(host)
        }
        if key.hasPrefix("hist.") {
            let cmd = String(key.dropFirst(5))
            return historyResultRow(HistoryEntry(command: cmd))
        }
        if key.hasPrefix("file.") {
            let path = String(key.dropFirst(5))
            guard let f = cachedCwdFiles.first(where: { $0.path == path })
            else { return nil }   // only suggest files from the current cwd
            return fileResultRow(f)
        }
        if key.hasPrefix("note.") {
            guard let id = UUID(uuidString: String(key.dropFirst(5))),
                  let note = state.notes.notes.first(where: { $0.id == id })
            else { return nil }
            return noteResultRow(note)
        }
        return commands.first { $0.id == key }
    }

    private var commands: [Command] {
        let list: [Command] = [
            // Pinned-at-top quick actions for the current pane's cwd.
            // These are the two most frequent "I want to look at this
            // directory in another tool" operations, so they shouldn't
            // be buried under the section navigators.
            Command(id: "reveal_finder", icon: "folder",
                    assetName: "finder",
                    title: "Open in Finder",
                    subtitle: "Open this pane's directory in Finder",
                    shortcut: "",
                    run: { openCurrentDir(in: .finder) }),
            Command(id: "open_cursor", icon: "cursorarrow",
                    assetName: "cursor-mark",
                    title: "Open in Cursor",
                    subtitle: "Open this pane's directory in Cursor",
                    shortcut: "",
                    run: { openCurrentDir(in: .cursor) }),
            Command(id: "sessions", icon: "rectangle.3.group",
                    title: "Sessions",
                    subtitle: "Jump to any pane in any window",
                    shortcut: "",
                    run: {
                        withAnimation(Theme.Spring.soft) {
                            state.paletteMode = .sessions
                        }
                    }),
            Command(id: "ssh_hosts", icon: "network",
                    title: "SSH",
                    subtitle: "Connect to a saved host",
                    shortcut: "",
                    run: {
                        withAnimation(Theme.Spring.soft) {
                            state.paletteMode = .sshHosts
                        }
                    }),
            Command(id: "tab_groups", icon: "square.stack.3d.up",
                    title: "Tab Groups",
                    subtitle: "Create, rename, recolor & reorder groups",
                    shortcut: "",
                    run: {
                        withAnimation(Theme.Spring.soft) {
                            state.paletteMode = .groups
                        }
                    }),
            Command(id: "shell_history", icon: "clock.arrow.circlepath",
                    title: "Shell History",
                    subtitle: "Re-run a recent command in this pane",
                    shortcut: "",
                    run: {
                        withAnimation(Theme.Spring.soft) {
                            state.paletteMode = .shellHistory
                        }
                    }),
            Command(id: "agents", icon: RobotGlyph.iconName,
                    title: "Agents",
                    subtitle: "Open the agent command center",
                    shortcut: "⌘⇧A",
                    run: {
                        state.togglePalette()
                        state.openAgentCenter(tab: .live)
                    }),
            Command(id: "notes", icon: "note.text",
                    title: "Notes",
                    subtitle: "Browse and edit your saved notes",
                    shortcut: "",
                    run: {
                        withAnimation(Theme.Spring.soft) {
                            state.paletteMode = .notesList
                        }
                    }),
            Command(id: "new_note", icon: "square.and.pencil",
                    title: "New Note", shortcut: "",
                    run: {
                        let n = state.notes.create()
                        withAnimation(Theme.Spring.soft) {
                            state.paletteMode = .noteEdit(noteID: n.id)
                        }
                    }),
            Command(id: "new_tab", icon: "plus.square.on.square",
                    title: "New Tab", shortcut: "⌘T",
                    run: { state.addTab() }),
            Command(id: "close_tab", icon: "xmark.square",
                    title: "Close Tab or Pane", shortcut: "⌘W",
                    run: { state.closeActivePaneOrTab() }),
            Command(id: "rename_tab", icon: "pencil",
                    title: "Rename Tab", shortcut: "",
                    run: {
                        if let t = state.selectedTab {
                            state.beginRename(t)
                        }
                    }),
            Command(id: "split_v", icon: "rectangle.split.2x1",
                    title: "Split Right", shortcut: "⌘D",
                    run: { state.splitSelected(direction: .horizontal) }),
            Command(id: "split_h", icon: "rectangle.split.1x2",
                    title: "Split Down", shortcut: "⌘⇧D",
                    run: { state.splitSelected(direction: .vertical) }),
            Command(id: "settings", icon: "slider.horizontal.3",
                    title: "Settings", shortcut: "⌘,",
                    run: { state.toggleSettings() }),
            Command(id: "tabs_orientation", icon: "rectangle.lefthalf.inset.filled",
                    title: "Cycle Layout: Horizontal / Vertical / Agents", shortcut: "",
                    run: {
                        withAnimation(Theme.Spring.soft) {
                            state.prefs.cycleTabOrientation()
                        }
                    }),
            Command(id: "toggle_palette", icon: "command",
                    title: "Close Command Palette", shortcut: "⌘K",
                    run: { state.togglePalette() }),
            Command(id: "quit", icon: "power",
                    title: "Quit Conterm", shortcut: "⌘Q",
                    run: { NSApp.terminate(nil) }),
        ]
        // Hidden commands (Settings → Palette) drop out of the ⌘K list;
        // their keyboard shortcuts / menu items still work.
        return reordered(list).filter { !prefs.hiddenPaletteCommands.contains($0.id) }
    }

    /// Apply `prefs.paletteCommandOrder` to the built-in command list:
    /// IDs the user has explicitly ordered come first (in their
    /// chosen order); everything else follows in built-in order. New
    /// commands shipped in later releases stay visible automatically.
    private func reordered(_ all: [Command]) -> [Command] {
        let order = prefs.paletteCommandOrder
        guard !order.isEmpty else { return all }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var result: [Command] = []
        var seen = Set<String>()
        for id in order {
            if let c = byID[id] {
                result.append(c)
                seen.insert(id)
            }
        }
        for c in all where !seen.contains(c.id) { result.append(c) }
        return result
    }

    /// Static metadata (id + display title + icon) for every built-in
    /// command, used by the Settings → Palette reorder UI. Kept in
    /// sync with the live `commands` array above by being the same
    /// list of IDs in the same default order.
    static let catalog: [(id: String, title: String, icon: String)] = [
        ("reveal_finder",    "Open in Finder",              "folder"),
        ("open_cursor",      "Open in Cursor",              "cursorarrow"),
        ("sessions",         "Sessions",                    "rectangle.3.group"),
        ("ssh_hosts",        "SSH",                         "network"),
        ("tab_groups",       "Tab Groups",                  "square.stack.3d.up"),
        ("shell_history",    "Shell History",               "clock.arrow.circlepath"),
        ("agents",           "Agents",                      RobotGlyph.iconName),
        ("notes",            "Notes",                       "note.text"),
        ("new_note",         "New Note",                    "square.and.pencil"),
        ("new_tab",          "New Tab",                     "plus.square.on.square"),
        ("close_tab",        "Close Tab or Pane",           "xmark.square"),
        ("rename_tab",       "Rename Tab",                  "pencil"),
        ("split_v",          "Split Right",                 "rectangle.split.2x1"),
        ("split_h",          "Split Down",                  "rectangle.split.1x2"),
        ("settings",         "Settings",                    "slider.horizontal.3"),
        ("tabs_orientation", "Toggle Top / Side Tab Bar",   "rectangle.lefthalf.inset.filled"),
        ("toggle_palette",   "Toggle Palette",              "command"),
        ("quit",             "Quit",                        "power"),
    ]

    private func runCommand(_ command: Command) {
        // Commands that switch palette mode shouldn't close the
        // palette; omni rows whose run manages palette state itself
        // (ssh/history close it via runInNewTab/runHistory, notes
        // switch mode) must not be double-toggled.
        let staysOpen = ["notes", "new_note", "sessions", "agents",
                         "shell_history", "ssh_hosts", "tab_groups"]
        let managesPalette = command.id.hasPrefix("ssh.")
            || command.id.hasPrefix("hist.")
            || command.id.hasPrefix("note.")
        if !staysOpen.contains(command.id) && !managesPalette {
            state.togglePalette()
        }
        // Selection feeds the frecency ranking (skip the calculator —
        // its row isn't resolvable as a suggestion).
        if command.id != "calc" {
            FrecencyStore.shared.bump(command.id)
        }
        command.run()
    }

    private func runFocusedCommand() {
        if state.paletteTrayCount > 0, state.paletteTrayFocused {
            let rows = suggestionRows()
            guard !rows.isEmpty else { return }
            runCommand(rows[min(state.paletteTrayIndex, rows.count - 1)])
            return
        }
        let list = filteredCommands
        guard !list.isEmpty else { return }
        var i = state.paletteFocusedIndex % list.count
        if i < 0 { i += list.count }
        runCommand(list[i])
    }

    // MARK: - Open-current-dir actions

    private enum OpenTarget { case finder, cursor }

    private func openCurrentDir(in target: OpenTarget) {
        // Pull cwd from the active pane in the active tab.
        guard let cwd = state.selectedTab?.paneTree.activePane?.cwd,
              !cwd.isEmpty else {
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: cwd)
        switch target {
        case .finder:
            NSWorkspace.shared.open(url)
        case .cursor:
            // Prefer the `cursor` CLI on PATH; fall back to `open -a Cursor`
            // so users without the shell shim still get launched.
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["sh", "-c",
                "cursor \(shellQuote(cwd)) 2>/dev/null || open -a Cursor \(shellQuote(cwd))"]
            try? task.run()
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Sessions mode

    /// One row in the sessions list: a single pane somewhere across
    /// all open windows. Sorted so the current pane comes first,
    /// then the rest of the current tab's panes, then other tabs in
    /// this window, then other windows.
    fileprivate struct SessionRow: Identifiable {
        let id: UUID            // pane.id
        let windowIndex: Int    // 1-based
        let tabIndex: Int       // 1-based within its window
        let paneIndex: Int      // 1-based within its tab (matches ⌥N)
        let paneCount: Int      // total panes in this tab
        let tabLabel: String
        let dirLabel: String    // friendly cwd ("~/Documents/...")
        let remoteHost: String? // non-nil when SSH'd
        let isActive: Bool      // currently active in its window
        let isCurrent: Bool     // current pane in current window
        let groupID: UUID?      // tab group membership, nil = ungrouped
        weak var window: NSWindow?
        weak var pane: Pane?
        weak var owningState: AppState?
        weak var owningTab: Tab?
    }

    @EnvironmentObject private var tabGroups: TabGroupStore

    private var allSessions: [SessionRow] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        var rows: [SessionRow] = []
        let currentState = state
        for (wi, wc) in appDelegate.windows.enumerated() {
            for (ti, tab) in wc.state.tabs.enumerated() {
                let leaves = tab.paneTree.root.leaves()
                for (pi, pane) in leaves.enumerated() {
                    let isActive = (tab.paneTree.activePaneID == pane.id)
                                && (wc.state.selectedID == tab.id)
                    let isCurrent = (wc.state === currentState) && isActive
                    rows.append(SessionRow(
                        id: pane.id,
                        windowIndex: wi + 1,
                        tabIndex: ti + 1,
                        paneIndex: pi + 1,
                        paneCount: leaves.count,
                        tabLabel: tab.title,
                        dirLabel: friendlyDirLabel(for: pane.cwd),
                        remoteHost: pane.remoteHost,
                        isActive: isActive,
                        isCurrent: isCurrent,
                        groupID: tab.groupID,
                        window: wc.window,
                        pane: pane,
                        owningState: wc.state,
                        owningTab: tab
                    ))
                }
            }
        }
        // Sort: group order first (defined-in-store order, ungrouped
        // last), then within a group: current → active → tab/pane
        // order. Section headers in the view are emitted at the
        // boundaries.
        return rows.sorted { a, b in
            let ga = groupSortKey(a.groupID)
            let gb = groupSortKey(b.groupID)
            if ga != gb { return ga < gb }
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            if a.isActive  != b.isActive  { return a.isActive }
            if a.windowIndex != b.windowIndex { return a.windowIndex < b.windowIndex }
            if a.tabIndex    != b.tabIndex    { return a.tabIndex < b.tabIndex }
            return a.paneIndex < b.paneIndex
        }
    }

    /// Stable sort key for a session's group: position in the store's
    /// group order; ungrouped sessions get a large key so they fall
    /// to the bottom of the list.
    private func groupSortKey(_ gid: UUID?) -> Int {
        guard let gid else { return Int.max }
        return tabGroups.groups.firstIndex(where: { $0.id == gid }) ?? (Int.max - 1)
    }

    private var filteredSessions: [SessionRow] {
        let all = allSessions
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { row in
            row.tabLabel.lowercased().contains(q) ||
            row.dirLabel.lowercased().contains(q) ||
            (row.remoteHost?.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder private var sessionsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    let rows = filteredSessions
                    // Only emit section headers when there's actually
                    // more than one bucket to look at — a window with
                    // zero groups + only ungrouped panes shouldn't get
                    // a redundant "Ungrouped" header.
                    let showSections = anyGroupsPresent(rows)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if showSections,
                           index == 0
                           || rows[index - 1].groupID != row.groupID {
                            sessionSectionHeader(
                                groupID: row.groupID,
                                count: rows[index..<rows.count]
                                    .prefix(while: { $0.groupID == row.groupID })
                                    .count
                            )
                            .id("ses-header-\(row.groupID?.uuidString ?? "none")")
                        }
                        SessionRowView(
                            row: row,
                            groupColor: row.groupID.flatMap { gid in
                                tabGroups.group(id: gid).map {
                                    TabGroup.color(forKey: $0.colorKey)
                                }
                            },
                            isFocused: index == state.paletteFocusedIndex
                        )
                        .id("ses-\(index)")
                        .onTapGesture { jump(to: row) }
                        .onHover { hovering in
                            if hovering && state.paletteHoverArmed {
                                state.paletteFocusedIndex = index
                            }
                        }
                        .contextMenu { sessionGroupMenu(for: row) }
                    }
                    if rows.isEmpty {
                        Text(query.isEmpty
                             ? "No open panes."
                             : "Nothing matches “\(query)”.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(20)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onChange(of: state.paletteFocusedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("ses-\(i)", anchor: .center)
                }
            }
        }
    }

    private func anyGroupsPresent(_ rows: [SessionRow]) -> Bool {
        // Show section headers if at least one row has a group.
        // A single-section "Ungrouped" header is just noise.
        rows.contains { $0.groupID != nil }
    }

    // MARK: - Agents mode (fleet view)

    /// Every pane with a live agent, across all windows. Sorted so
    /// the agents that need a human come first, then the ones still
    /// working, then the ones sitting ready; within a phase, stable
    /// window → tab → pane order.
    private var allAgents: [SessionRow] {
        allSessions
            .filter { ($0.pane?.agent.phase ?? .idle) != .idle }
            .sorted { a, b in
                let pa = phaseRank(a.pane?.agent.phase ?? .idle)
                let pb = phaseRank(b.pane?.agent.phase ?? .idle)
                if pa != pb { return pa < pb }
                if a.windowIndex != b.windowIndex { return a.windowIndex < b.windowIndex }
                if a.tabIndex    != b.tabIndex    { return a.tabIndex < b.tabIndex }
                return a.paneIndex < b.paneIndex
            }
    }

    private func phaseRank(_ p: AgentStatus.Phase) -> Int {
        switch p {
        case .attention:   return 0
        case .working:     return 1
        case .interrupted: return 2
        case .ready:       return 3
        case .idle:        return 4
        }
    }

    private var filteredAgents: [SessionRow] {
        let rows = allAgents
        guard !query.isEmpty else { return rows }
        let q = query.lowercased()
        return rows.filter { row in
            row.tabLabel.lowercased().contains(q)
            || row.dirLabel.lowercased().contains(q)
            || (row.remoteHost?.lowercased().contains(q) ?? false)
            || (row.pane?.agent.tool.displayName.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder private var agentsView: some View {
        let rows = filteredAgents
        if rows.isEmpty {
            // Outside the ScrollView: a greedy scroll container would
            // stretch the bubble to its 360pt cap for one line of
            // text. Full width keeps the bubble from shrinking to a
            // sliver; content-hugging height keeps it shallow.
            Text(query.isEmpty
                 ? "No agents running."
                 : "Nothing matches “\(query)”.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if let pane = row.pane {
                                AgentRowView(
                                    pane: pane,
                                    row: row,
                                    isFocused: index == state.paletteFocusedIndex
                                )
                                .id("agent-\(index)")
                                .onTapGesture { jump(to: row) }
                                .onHover { hovering in
                                    if hovering && state.paletteHoverArmed {
                                        state.paletteFocusedIndex = index
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)
                .onChange(of: state.paletteFocusedIndex) { _, i in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("agent-\(i)", anchor: .center)
                    }
                }
            }
        }
    }

    private func jumpToFocusedAgent() {
        let rows = filteredAgents
        guard !rows.isEmpty else { return }
        var i = state.paletteFocusedIndex % rows.count
        if i < 0 { i += rows.count }
        jump(to: rows[i])
    }

    // MARK: - Groups mode (manage tab groups)

    private var groupsHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 14, weight: .medium))
            Text("Tab Groups")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                _ = tabGroups.create()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("New")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Theme.accentSoft))
            }
            .buttonStyle(.plain)
            keyHint("esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    @ViewBuilder private var groupsView: some View {
        ScrollView {
            VStack(spacing: 6) {
                if tabGroups.groups.isEmpty {
                    Text("No groups yet. Tap New, or right-click a session to start one.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    ForEach(Array(tabGroups.groups.enumerated()), id: \.element.id) { index, group in
                        GroupManageRow(
                            group: group,
                            tabs: tabs(inGroup: group.id),
                            isFirst: index == 0,
                            isLast: index == tabGroups.groups.count - 1,
                            onRecolor: { tabGroups.cycleColor(group.id) },
                            onRename:  { newName in tabGroups.rename(group.id, to: newName) },
                            onMoveUp:  { withAnimation(Theme.Spring.snappy) { tabGroups.move(group.id, by: -1) } },
                            onMoveDown:{ withAnimation(Theme.Spring.snappy) { tabGroups.move(group.id, by: 1) } },
                            onDelete:  { withAnimation(Theme.Spring.snappy) { tabGroups.delete(group.id) } },
                            onRemoveTab: { tab in
                                withAnimation(Theme.Spring.snappy) {
                                    tab.groupID = nil
                                    tabGroups.objectWillChange.send()
                                }
                            }
                        )
                    }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 360)
    }

    /// Tabs (across all windows) assigned to a group, in window/tab order.
    private func tabs(inGroup id: UUID) -> [Tab] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        var result: [Tab] = []
        for wc in appDelegate.windows {
            for tab in wc.state.tabs where tab.groupID == id { result.append(tab) }
        }
        return result
    }

    /// Right-click menu on a session row: move the row's TAB into a
    /// group, spin off a new group, or remove it from its group. Group
    /// membership lives on `Tab.groupID`; mutating it re-sorts the
    /// sessions list. We nudge `tabGroups` so the palette (which
    /// observes it) recomputes immediately.
    @ViewBuilder
    private func sessionGroupMenu(for row: SessionRow) -> some View {
        if let tab = row.owningTab {
            // Tab groups are TAB-level, not pane-level: every pane in
            // this tab moves together. The menu says "tab" + names the
            // tab so it's clear you're grouping the whole tab, even
            // though you right-clicked one of its panes.
            Menu("Tab “\(tab.title)”") {
                Text(row.paneCount > 1
                     ? "Grouping moves all \(row.paneCount) panes in this tab"
                     : "Add this tab to a group")
                Divider()
                if !tabGroups.groups.isEmpty {
                    ForEach(tabGroups.groups) { g in
                        Button {
                            tab.groupID = g.id
                            tabGroups.objectWillChange.send()
                        } label: {
                            Label("Move tab to “\(g.name)”", systemImage: "circle.fill")
                        }
                    }
                    Divider()
                }
                Button("New Group from This Tab") {
                    let g = tabGroups.create()
                    tab.groupID = g.id
                }
                if let gid = tab.groupID, let g = tabGroups.group(id: gid) {
                    Divider()
                    Button("Rename / Color / Delete “\(g.name)”…") {
                        beginGroupEdit(gid)
                    }
                    Button("Remove Tab from Group") {
                        tab.groupID = nil
                        tabGroups.objectWillChange.send()
                    }
                }
            }
        }
    }

    /// Close the palette, then open the group rename/color/delete
    /// overlay. Deferred so the palette's dismissal doesn't fight the
    /// overlay for first responder.
    private func beginGroupEdit(_ gid: UUID) {
        if state.paletteOpen { state.togglePalette() }
        DispatchQueue.main.async { state.beginRenameGroup(gid) }
    }

    @ViewBuilder
    private func sessionSectionHeader(groupID: UUID?, count: Int) -> some View {
        let group = groupID.flatMap { tabGroups.group(id: $0) }
        let color: Color = group.map { TabGroup.color(forKey: $0.colorKey) }
                                ?? Theme.textSecondary
        let label = group?.name ?? "Ungrouped"
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.5), radius: 3)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("·")
                .foregroundStyle(Theme.textSecondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            // Edit affordance — only on real groups. Opens the
            // rename / color / delete overlay. Discoverable click
            // target alongside the right-click menu below.
            if let gid = groupID, group != nil {
                Button {
                    beginGroupEdit(gid)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rename, recolor, or delete this group")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if let gid = groupID, group != nil {
                Button("Rename / Color / Delete…") { beginGroupEdit(gid) }
            }
        }
    }

    private func jumpToFocusedSession() {
        let rows = filteredSessions
        guard !rows.isEmpty else { return }
        var i = state.paletteFocusedIndex % rows.count
        if i < 0 { i += rows.count }
        jump(to: rows[i])
    }

    private func jump(to row: SessionRow) {
        // Close palette FIRST so focus can land on the pane.
        state.togglePalette()
        // Switch the target window's tab + active pane, then bring
        // that window front + focus the pane.
        if let s = row.owningState, let tab = row.owningTab, let pane = row.pane {
            s.select(tab.id)
            tab.paneTree.focus(pane)
        }
        if let win = row.window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        // Defer the focus pull so SwiftUI has time to mount the pane.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            row.owningState?.focusActiveSurface()
        }
    }

    /// Friendly label used by SessionRowView. Shadows the same logic
    /// in TerminalContainer (kept in sync — small helper).
    @MainActor
    private func friendlyDirLabel(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        let home = NSHomeDirectory()
        var p = cwd
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/").map(String.init)
        if parts.count <= 3 { return p }
        return ".../" + parts.suffix(2).joined(separator: "/")
    }

    // MARK: - Shell history mode

    /// Loaded once at palette open from `~/.zsh_history` / `~/.bash_history`.
    /// Static so the parse cost happens at most once per process.
    private static let history: [HistoryEntry] = ShellHistory.loadAll()

    private var filteredShellHistory: [HistoryEntry] {
        guard !query.isEmpty else { return Self.history }
        let q = query.lowercased()
        return Self.history.filter { $0.command.lowercased().contains(q) }
    }

    @ViewBuilder private var shellHistoryView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    let rows = filteredShellHistory
                    ForEach(Array(rows.prefix(500).enumerated()), id: \.element.id) { index, entry in
                        historyRow(entry: entry,
                                    isFocused: index == state.paletteFocusedIndex)
                            .id("hist-\(index)")
                            .onTapGesture { runHistory(entry) }
                            .onHover { hovering in
                                if hovering && state.paletteHoverArmed {
                                state.paletteFocusedIndex = index
                            }
                            }
                    }
                    if rows.isEmpty {
                        Text(query.isEmpty
                             ? "No shell history found in ~/.zsh_history or ~/.bash_history."
                             : "Nothing matches “\(query)”.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(20)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onChange(of: state.paletteFocusedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("hist-\(i)", anchor: .center)
                }
            }
        }
    }

    private func historyRow(entry: HistoryEntry, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .frame(width: 18)
            Text(entry.command)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Theme.selectionFill : .clear)
        )
    }

    private func runFocusedHistoryEntry() {
        let rows = filteredShellHistory
        guard !rows.isEmpty else { return }
        var i = state.paletteFocusedIndex % rows.count
        if i < 0 { i += rows.count }
        runHistory(rows[i])
    }

    private func runHistory(_ entry: HistoryEntry) {
        state.togglePalette()
        Self.runInActivePane(state: state, command: entry.command)
    }

    // MARK: - SSH hosts mode

    /// Parsed once per process from ~/.ssh/config (and any Include
    /// files). If the user edits ssh config, a Conterm restart picks
    /// up the change.
    private static let sshHosts: [SSHHost] = SSHHosts.loadAll()

    private struct SSHRow: Identifiable, Hashable {
        let host: SSHHost
        let isRecent: Bool
        var id: String { (isRecent ? "r-" : "a-") + host.alias }
    }

    /// Builds the full SSH row list: recents from shell history and
    /// palette clicks, followed by the remaining `~/.ssh/config`
    /// hosts. Reads the history file, so call from
    /// `refreshSSHRowsIfNeeded()` rather than from a SwiftUI body.
    private func computeAllSSHRows() -> [SSHRow] {
        let hostByAlias = Dictionary(uniqueKeysWithValues:
            Self.sshHosts.map { ($0.alias, $0) })
        var seen = Set<String>()
        var recents: [String] = []
        for alias in SSHHistory.recentTargets() + SSHRecents.load() {
            if seen.insert(alias).inserted { recents.append(alias) }
        }
        let recentRows = recents.map { alias -> SSHRow in
            let host = hostByAlias[alias] ?? SSHHost(alias: alias, hostname: nil)
            return SSHRow(host: host, isRecent: true)
        }
        let recentSet = Set(recents)
        let restRows = Self.sshHosts
            .filter { !recentSet.contains($0.alias) }
            .map { SSHRow(host: $0, isRecent: false) }
        return recentRows + restRows
    }

    /// Rebuilds `cachedAllSSHRows` from the latest shell history
    /// and `~/.ssh/config`. Called once each time the user enters
    /// SSH mode in the palette.
    private func refreshSSHRowsIfNeeded() {
        cachedAllSSHRows = computeAllSSHRows()
    }

    private var filteredSSHRows: [SSHRow] {
        guard !query.isEmpty else { return cachedAllSSHRows }
        let q = query.lowercased()
        return cachedAllSSHRows.filter { row in
            row.host.alias.lowercased().contains(q) ||
            (row.host.hostname?.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder private var sshHostsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    let rows = filteredSSHRows
                    if rows.isEmpty {
                        Text(query.isEmpty
                             ? "No SSH hosts found in ~/.ssh/config."
                             : "Nothing matches “\(query)”.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(20)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            // Insert a "Recents" / "All hosts" header
                            // when the section flips.
                            if index == 0 && row.isRecent {
                                sshSectionHeader("Recent")
                            } else if index > 0
                                       && row.isRecent != rows[index - 1].isRecent {
                                sshSectionHeader("All hosts")
                            }
                            sshHostRow(row: row,
                                       isFocused: index == state.paletteFocusedIndex)
                                .id("ssh-\(index)")
                                .onTapGesture { connectToSSHHost(row.host) }
                                .onHover { hovering in
                                    if hovering && state.paletteHoverArmed {
                                state.paletteFocusedIndex = index
                            }
                                }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onChange(of: state.paletteFocusedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("ssh-\(i)", anchor: .center)
                }
            }
        }
    }

    private func sshSectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func sshHostRow(row: SSHRow, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.isRecent ? "clock" : "network")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.host.alias)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if let h = row.host.hostname, h != row.host.alias {
                    Text(h)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isFocused ? Theme.selectionFill : .clear)
        )
        .contentShape(Rectangle())
    }

    private func connectFocusedSSHHost() {
        let rows = filteredSSHRows
        guard !rows.isEmpty else { return }
        var i = state.paletteFocusedIndex % rows.count
        if i < 0 { i += rows.count }
        connectToSSHHost(rows[i].host)
    }

    private func connectToSSHHost(_ host: SSHHost) {
        SSHRecents.push(host.alias)
        Self.runInNewTab(state: state, command: "ssh \(host.alias)")
    }

    // MARK: - Sending shell commands into a pane

    /// Open a new tab and run `command` in its shell once the
    /// surface is mounted. Newline is appended so the command runs
    /// immediately.
    @MainActor
    static func runInNewTab(state: AppState, command: String) {
        state.togglePalette()
        let tab = state.addTab()
        // Pane controller mounts via SwiftUI's NSViewRepresentable
        // lifecycle; retry every 50ms until it's there.
        var attempts = 0
        @MainActor func attempt() {
            attempts += 1
            if let pane = tab.paneTree.activePane,
               let ctrl = pane.controller {
                ctrl.typeText(command)
                ctrl.sendReturn()
                return
            }
            if attempts < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    Task { @MainActor in attempt() }
                }
            }
        }
        attempt()
    }

    /// Run `command` in the currently-active pane of the selected tab.
    /// Newline appended so the shell executes it.
    @MainActor
    static func runInActivePane(state: AppState, command: String) {
        guard let pane = state.selectedTab?.paneTree.activePane,
              let ctrl = pane.controller else { return }
        ctrl.typeText(command)
        ctrl.sendReturn()
    }

    /// Type `text` into the active pane WITHOUT a newline — used by
    /// results that compose into the prompt (calculator answers,
    /// file paths) rather than execute.
    @MainActor
    static func insertInActivePane(state: AppState, text: String) {
        guard let pane = state.selectedTab?.paneTree.activePane,
              let ctrl = pane.controller else { return }
        ctrl.typeText(text)
    }

    // MARK: - Notes-list mode

    private var filteredNotes: [Note] {
        state.notes.filtered(query)
    }

    @ViewBuilder private var notesListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    // Always-present "New note" row at the top.
                    NewNoteRow(isFocused: state.paletteFocusedIndex == 0)
                        .id("note-0")
                        .onTapGesture { createAndEdit() }
                        .onHover { if $0 { state.paletteFocusedIndex = 0 } }

                    ForEach(Array(filteredNotes.enumerated()), id: \.element.id) { index, note in
                        let rowIndex = index + 1   // because "new note" is row 0
                        NoteRow(note: note, isFocused: rowIndex == state.paletteFocusedIndex)
                            .id("note-\(rowIndex)")
                            .onTapGesture {
                                withAnimation(Theme.Spring.soft) {
                                    state.paletteMode = .noteEdit(noteID: note.id)
                                }
                            }
                            .onHover { if $0 { state.paletteFocusedIndex = rowIndex } }
                    }

                    if filteredNotes.isEmpty && !query.isEmpty {
                        Text("No notes match \"\(query)\"")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(16)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onChange(of: state.paletteFocusedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("note-\(i)", anchor: .center)
                }
            }
        }
    }

    private func openFocusedNote() {
        let i = state.paletteFocusedIndex
        if i == 0 {
            createAndEdit()
            return
        }
        let list = filteredNotes
        let noteIdx = i - 1
        guard noteIdx >= 0, noteIdx < list.count else { return }
        withAnimation(Theme.Spring.soft) {
            state.paletteMode = .noteEdit(noteID: list[noteIdx].id)
        }
    }

    private func createAndEdit() {
        let n = state.notes.create()
        withAnimation(Theme.Spring.soft) {
            state.paletteMode = .noteEdit(noteID: n.id)
        }
    }

    // MARK: - Note-edit mode

    @ViewBuilder private func noteEditView(id: UUID) -> some View {
        if let note = state.notes.notes.first(where: { $0.id == id }) {
            NoteEditor(noteID: id,
                        initialContent: note.content,
                        onDelete: { deleteAndBack(id) },
                        onCommit: { content in
                            state.notes.update(id, content: content)
                        })
                .frame(height: 360)
        } else {
            Text("Note no longer exists")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(40)
                .frame(height: 200)
        }
    }

    private func deleteAndBack(_ id: UUID) {
        state.notes.delete(id)
        withAnimation(Theme.Spring.soft) {
            state.paletteMode = .notesList
        }
    }

    // MARK: - Building blocks

    private func searchBar(placeholder: String, icon: String) -> some View {
        HStack(spacing: 10) {
            if icon == RobotGlyph.iconName {
                RobotGlyph(color: Theme.textSecondary, size: 17)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(Theme.textSecondary)
                    .font(.system(size: 15, weight: .medium))
            }
            NeonCaretField(text: $query, placeholder: placeholder, fontSize: 16)
                .frame(height: 24)
            Spacer()
            switch state.paletteMode {
            case .commands:
                keyHint("esc")
            case .notesList:
                HStack(spacing: 4) {
                    keyHint("⌘⌫ delete")
                    keyHint("esc")
                }
            case .noteEdit:
                EmptyView()
            case .sessions:
                keyHint("esc")
            case .agents:
                keyHint("esc")
            case .shellHistory:
                keyHint("esc")
            case .sshHosts:
                keyHint("esc")
            case .groups:
                keyHint("esc")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func keyHint(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.stroke))
    }
}

/// Shared chrome for the palette's floating glass bubbles: panel
/// background, clip, border, liquid-glass top-edge highlight, drop
/// shadow. `darken` lays an extra wash over the glass so the input
/// bar reads heavier than the results panel.
private struct PaletteBubble: ViewModifier {
    let cornerRadius: CGFloat
    var darken: Double = 0
    @EnvironmentObject private var prefs: Preferences

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // `Glass panels` on → real frosted Liquid Glass. Off
                    // (default) → a solid black panel: an opaque sheet that
                    // doesn't sample the terminal behind it. `darken` sinks
                    // the input bar a touch below the results either way.
                    if prefs.liquidGlassPanels, #available(macOS 26, *) {
                        PaneLiquidGlass(cornerRadius: cornerRadius,
                                        frostiness: 0.85,
                                        light: prefs.lightGlass)
                    } else {
                        Theme.panelBed
                    }
                    if darken > 0 { Color.black.opacity(darken) }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
            .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 12)
    }
}

// MARK: - Suggestion circle

/// One pick in the suggestion strip, rendered as a standalone glass
/// circle with its label beneath. On appear it rolls up out of a blur
/// (clock-digit style), staggered by `index` across the row; focus keeps
/// a steady accent halo.
private struct CircleSuggestion: View {
    let command: Command
    let index: Int
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    // Opaque bed: a flat disc that neither samples the
                    // backdrop nor needs a shadow.
                    Circle().fill(Theme.chipBed)
                    if isFocused { Circle().fill(Theme.accentSoft) }
                    Circle()
                        .strokeBorder(isFocused ? Theme.accent.opacity(0.5)
                                                : Theme.strokeStrong,
                                      lineWidth: 1)
                    icon
                }
                .frame(width: 48, height: 48)
                // Glow only on the focused circle, so the strip carries one
                // shadow filter, not seven.
                .shadow(color: isFocused ? Theme.accentOnDark.opacity(0.5) : .clear,
                        radius: isFocused ? 11 : 0)

                // Fixed-light over the bare terminal (the label sits below
                // the disc, off any panel bed). A legibility shadow keeps it
                // readable over a bright terminal as well as a dark one.
                Text(command.title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(isFocused ? 0.98 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.6), radius: 2.5)
                    .frame(maxWidth: 72)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(command.subtitle ?? command.title)
        .animation(Theme.Spring.snappy, value: isFocused)
        .rollUp(delay: 0.05 + Double(index) * 0.06)
    }

    @ViewBuilder
    private var icon: some View {
        let tint = isFocused ? Theme.accent : Theme.textSecondary
        if let asset = command.assetName,
           let templated = CommandRow.bundledTemplateImage(named: asset) {
            Image(nsImage: templated)
                .resizable()
                .interpolation(.high)
                .frame(width: 21, height: 21)
                .foregroundStyle(tint)
        } else if command.icon == RobotGlyph.iconName {
            RobotGlyph(color: tint, size: 22)
        } else {
            Image(systemName: command.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Roll-up reveal

/// Clock-digit reveal: content rises into place out of a blur with a
/// soft settle, the way the old stats widget tumbled its numbers. Runs
/// once per appearance (guarded against SwiftUI's repeat `onAppear`),
/// and replays each time the view is freshly inserted.
private struct RollUpReveal<Content: View>: View {
    let delay: Double
    @ViewBuilder var content: Content

    @State private var shown = false
    @State private var ran = false

    var body: some View {
        content
            .blur(radius: shown ? 0 : 5)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 9)
            .onAppear {
                guard !ran else { return }
                ran = true
                withAnimation(.spring(response: 0.5, dampingFraction: 0.68).delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Reveal this view with the clock-digit roll-up. See `RollUpReveal`.
    func rollUp(delay: Double) -> some View {
        RollUpReveal(delay: delay) { self }
    }
}

/// A label whose characters roll up out of a blur one after another, so
/// the word assembles like rolling clock digits instead of typing out.
private struct RollUpText: View {
    let text: String
    let font: Font
    let color: Color
    var startDelay: Double = 0.0
    var step: Double = 0.045

    init(_ text: String, font: Font, color: Color,
         startDelay: Double = 0.0, step: Double = 0.045) {
        self.text = text
        self.font = font
        self.color = color
        self.startDelay = startDelay
        self.step = step
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { i, ch in
                Text(String(ch))
                    .font(font)
                    .foregroundStyle(color)
                    .fixedSize()
                    .rollUp(delay: startDelay + Double(i) * step)
            }
        }
    }
}

// MARK: - Row primitives

private struct Command: Identifiable {
    let id: String
    let icon: String
    /// Optional bundled-asset name. When set, the row renders the
    /// asset as a template image (so it picks up the row's tint) and
    /// the SF Symbol `icon` is ignored. Used for the Cursor brand mark.
    let assetName: String?
    let title: String
    /// Optional smaller, dimmer second line under the title. Used to
    /// describe what a mode-switching command does ("Connect to a
    /// saved host", "Jump to any pane", …) without cluttering the
    /// primary label with a `—` separator.
    let subtitle: String?
    let shortcut: String
    let run: () -> Void

    init(id: String, icon: String, assetName: String? = nil,
         title: String, subtitle: String? = nil,
         shortcut: String, run: @escaping () -> Void) {
        self.id = id
        self.icon = icon
        self.assetName = assetName
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.run = run
    }
}

private struct CommandRow: View {
    let command: Command
    let index: Int
    let isFocused: Bool
    @State private var entered = false

    var body: some View {
        HStack(spacing: 10) {
            commandIcon
                .frame(width: 22)
                .scaleEffect(isFocused ? 1.1 : 1.0)
            VStack(alignment: .leading, spacing: 1) {
                titleText
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = command.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !command.shortcut.isEmpty {
                Text(command.shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isFocused ? Theme.strokeStrong : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
        .opacity(entered ? 1 : 0)
        .offset(y: entered ? 0 : -8)
        .task {
            // Cap the stagger so a row revealed far down a lazy list (high
            // index) still fades in promptly instead of after seconds.
            try? await Task.sleep(nanoseconds: UInt64(min(index, 14)) * 16_000_000)
            withAnimation(Theme.Spring.soft) { entered = true }
        }
    }

    /// The calculator row reads as "your input → result": equation
    /// dim and light, answer prominent. Everything else is the plain
    /// rounded title.
    @ViewBuilder
    private var titleText: some View {
        if command.id == "calc",
           let r = command.title.range(of: " = ", options: .backwards) {
            Text(calcTitle(expr: String(command.title[..<r.lowerBound]),
                           answer: String(command.title[r.upperBound...])))
        } else {
            Text(command.title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func calcTitle(expr: String, answer: String) -> AttributedString {
        var e = AttributedString(expr + " = ")
        e.font = .system(size: 14, weight: .light, design: .rounded)
        e.foregroundColor = Theme.textSecondary.opacity(0.85)
        var a = AttributedString(answer)
        a.font = .system(size: 15, weight: .semibold, design: .rounded)
        a.foregroundColor = Theme.textPrimary
        return e + a
    }

    @ViewBuilder
    private var commandIcon: some View {
        if let asset = command.assetName,
           let templated = Self.bundledTemplateImage(named: asset) {
            // Render the brand mark as a template image so it picks up
            // the row's tint (matches the rest of the palette icons).
            Image(nsImage: templated)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
        } else if command.icon == RobotGlyph.iconName {
            RobotGlyph(color: isFocused ? Theme.accent : Theme.textSecondary,
                       size: 16)
        } else {
            // Always-safe fallback: the SF Symbol. We reach here when
            // the asset can't be loaded — which must NEVER crash.
            Image(systemName: command.icon)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
        }
    }

    /// Cache of loaded brand-mark images, keyed by asset name. The
    /// value is itself optional so a known-missing asset is remembered
    /// and never re-probed. Without this the icon was reloaded from
    /// disk on EVERY row body re-eval (each arrow-key move re-renders
    /// the focused/unfocused rows), minting a fresh NSImage each time
    /// — SwiftUI then crossfaded the "new" image, which read as the
    /// icon blinking. Main-thread only (SwiftUI body), so a plain
    /// MainActor static is safe.
    @MainActor private static var imageCache: [String: NSImage?] = [:]

    /// Load a bundled PNG as a tintable template image. Returns nil
    /// (never crashes) if it's not present. Cached after first load.
    ///
    /// IMPORTANT: this must not touch SwiftPM's `Bundle.module`. That
    /// accessor `fatalError()`s when it can't resolve the generated
    /// `Conterm_Conterm.bundle`, which is exactly what happens on
    /// AirDropped / quarantined / translocated copies — it crashed the
    /// whole app the instant ⌘K rendered this row. We only ever read
    /// the flat copy in `Bundle.main` (Contents/Resources/<name>.png).
    @MainActor
    fileprivate static func bundledTemplateImage(named name: String) -> NSImage? {
        if let cached = imageCache[name] { return cached }
        let img: NSImage? = {
            guard let url = Bundle.main.url(forResource: name,
                                            withExtension: "png"),
                  let i = NSImage(contentsOf: url) else {
                return nil
            }
            i.isTemplate = true
            return i
        }()
        imageCache[name] = img
        return img
    }
}

private struct NewNoteRow: View {
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .frame(width: 22)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .scaleEffect(isFocused ? 1.1 : 1.0)
            Text("New note")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("⏎")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.stroke))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }
}

private struct NoteRow: View {
    let note: Note
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .frame(width: 22)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(formatDate(note.modified))
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isFocused ? Theme.strokeStrong : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        return f
    }()

    private func formatDate(_ d: Date) -> String {
        let interval = Date().timeIntervalSince(d)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval/60))m ago" }
        if interval < 86400 { return "\(Int(interval/3600))h ago" }
        return Self.shortDateFormatter.string(from: d)
    }
}

// MARK: - Group management row

private struct GroupManageRow: View {
    let group: TabGroup
    let tabs: [Tab]
    let isFirst: Bool
    let isLast: Bool
    let onRecolor: () -> Void
    let onRename: (String) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    let onRemoveTab: (Tab) -> Void

    @State private var hovering = false
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let color = TabGroup.color(forKey: group.colorKey)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Color swatch — tap to cycle through the palette.
                Button(action: onRecolor) {
                    Circle()
                        .fill(color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: color.opacity(0.5), radius: 4)
                }
                .buttonStyle(.plain)
                .help("Change colour")

                // Inline-editable name — commits on Enter / focus loss,
                // WITHOUT closing the palette.
                TextField("Group name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitName() }
                    }

                Text("\(tabs.count) tab\(tabs.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    iconButton("chevron.up", disabled: isFirst, action: onMoveUp)
                    iconButton("chevron.down", disabled: isLast, action: onMoveDown)
                    iconButton("trash", danger: true, action: onDelete)
                }
            }

            // The tabs currently in this group — each removable.
            if tabs.isEmpty {
                Text("No tabs — right-click a session to add one")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .padding(.leading, 26)
            } else {
                ForEach(tabs) { tab in
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textSecondary)
                        Text(tab.title.isEmpty ? "shell" : tab.title)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button { onRemoveTab(tab) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Remove from group")
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .onAppear { name = group.name }
        .onChange(of: group.name) { _, new in if !nameFocused { name = new } }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { name = group.name }
        else if trimmed != group.name { onRename(trimmed) }
    }

    private func iconButton(_ name: String, disabled: Bool = false,
                            danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? Theme.textSecondary.opacity(0.3)
                                 : (danger ? Theme.warning : Theme.textSecondary))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Sessions row

private struct SessionRowView: View {
    let row: CommandPalette.SessionRow
    /// Color of the row's tab group, if any. Rendered as a thin
    /// leading vertical bar so each row visually ties to its
    /// section header — and the indicator is still visible even
    /// when sections aren't shown.
    let groupColor: Color?
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Group color bar at the leading edge. Width 2pt; full
            // height of the row. When nil, take the same space with
            // a transparent stand-in so rows align with/without one.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(groupColor ?? .clear)
                .frame(width: 2.5, height: 26)
                .opacity(isFocused ? 0.95 : 0.7)
            // Leading icon — globe for SSH, folder for local cwd, with
            // a soft halo when focused.
            ZStack {
                Circle()
                    .fill(iconBg)
                    .frame(width: 28, height: 28)
                Image(systemName: leadingIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: isFocused ? Theme.accent.opacity(0.45) : .clear,
                    radius: isFocused ? 8 : 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.tabLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if row.isCurrent {
                        Text("here")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.18)))
                    } else if row.isActive {
                        Text("active")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                }
                HStack(spacing: 4) {
                    if let host = row.remoteHost {
                        Image(systemName: "network")
                            .font(.system(size: 9))
                        Text(host)
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(row.dirLabel)
                    }
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            // Trailing locator chips: window/tab, then the pane number
            // (its ⌥N index) shown as "pane N of M" when the tab is
            // split, so it's clear these rows are individual panes
            // inside a tab — grouping still operates on the whole tab.
            HStack(spacing: 4) {
                chip("W\(row.windowIndex)")
                chip("T\(row.tabIndex)")
                chip(row.paneCount > 1
                     ? "⌥\(row.paneIndex)·\(row.paneCount)"
                     : "⌥\(row.paneIndex)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isFocused ? Theme.strokeStrong : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }

    private var leadingIcon: String {
        row.remoteHost != nil ? "globe" : "folder.fill"
    }

    private var iconBg: Color {
        isFocused
            ? Theme.accent.opacity(0.22)
            : Color.white.opacity(0.06)
    }

    private var iconFg: Color {
        isFocused ? Theme.accent : Theme.textSecondary
    }

    @ViewBuilder
    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Theme.stroke))
    }
}

// MARK: - Agent row (agents mode)

/// One running agent. Observes its Pane directly so a phase change
/// while the palette is open (working → needs you) re-renders the
/// row without reopening.
private struct AgentRowView: View {
    @ObservedObject var pane: Pane
    let row: CommandPalette.SessionRow
    let isFocused: Bool

    var body: some View {
        let status = pane.agent
        let accent = status.tool.glowColor
        HStack(alignment: .center, spacing: 10) {
            // Agent mark in a tinted halo; the halo carries the
            // per-tool accent so the list scans by color.
            ZStack {
                Circle()
                    .fill(accent.opacity(isFocused ? 0.26 : 0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: status.tool.fallbackSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: isFocused ? accent.opacity(0.45) : .clear,
                    radius: isFocused ? 8 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(row.tabLabel)
                    Text("·")
                    if let host = row.remoteHost {
                        Image(systemName: "network").font(.system(size: 9))
                        Text(host)
                    } else {
                        Text(row.dirLabel)
                    }
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            phaseBadge(status.phase, accent: accent)

            HStack(spacing: 4) {
                chip("W\(row.windowIndex)")
                chip("T\(row.tabIndex)")
                chip(row.paneCount > 1
                     ? "⌥\(row.paneIndex)·\(row.paneCount)"
                     : "⌥\(row.paneIndex)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isFocused ? Theme.strokeStrong : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }

    @ViewBuilder
    private func phaseBadge(_ phase: AgentStatus.Phase, accent: Color) -> some View {
        switch phase {
        case .attention:
            Text("needs you")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(accent.opacity(0.18)))
        case .working:
            Text("thinking")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.07)))
        case .ready:
            Text("ready")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.07)))
        case .interrupted:
            Text("interrupted")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.07)))
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Theme.stroke))
    }
}

// MARK: - Note editor (note-edit mode)

private struct NoteEditor: View {
    let noteID: UUID
    let initialContent: String
    let onDelete: () -> Void
    let onCommit: (String) -> Void

    @State private var content: String
    @FocusState private var editorFocused: Bool

    init(noteID: UUID, initialContent: String,
         onDelete: @escaping () -> Void,
         onCommit: @escaping (String) -> Void) {
        self.noteID = noteID
        self.initialContent = initialContent
        self.onDelete = onDelete
        self.onCommit = onCommit
        self._content = State(initialValue: initialContent)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 13, weight: .semibold))
                Text(content
                        .split(whereSeparator: \.isNewline)
                        .first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? "Untitled")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button(action: onDelete) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Delete")
                        Text("⌘⌫")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            // Editor
            TextEditor(text: $content)
                .focused($editorFocused)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .onChange(of: content) { _, new in
                    onCommit(new)
                }
        }
        .onAppear {
            DispatchQueue.main.async { editorFocused = true }
        }
    }
}
