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
            case .shellHistory:
                shellHistoryView
            case .sshHosts:
                sshHostsView
            }
        }
        .background(paletteBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .overlay(
            // Liquid-glass top edge highlight.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        .frame(maxWidth: 600)
        .onAppear {
            queryFocused = true; query = ""; state.paletteFocusedIndex = 0
            appeared = false
            DispatchQueue.main.async { appeared = true }
            if state.paletteMode == .sshHosts { refreshSSHRowsIfNeeded() }
        }
        .onChange(of: state.paletteMode) { _, mode in
            // Mode change resets query + focus.
            query = ""
            state.paletteFocusedIndex = 0
            DispatchQueue.main.async { queryFocused = true }
            if mode == .sshHosts { refreshSSHRowsIfNeeded() }
        }
        .onChange(of: query) { _, _ in state.paletteFocusedIndex = 0 }
        .onChange(of: state.paletteFocusedIndex) { _, _ in clampFocus() }
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

    private var paletteBackground: some View {
        ZStack {
            // Liquid-glass-style: a faint blue tint + the system's
            // hudWindow material at low opacity. Less "frosted" than
            // a full-opacity NSVisualEffectView.
            GlassBackground(material: .hudWindow)
                .opacity(0.92)
            Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.22)
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
        case .shellHistory:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        case .sshHosts:
            withAnimation(Theme.Spring.snappy) { state.paletteMode = .commands }
        }
    }

    private func handleEnter() {
        switch state.paletteMode {
        case .commands:        runFocusedCommand()
        case .notesList:       openFocusedNote()
        case .noteEdit:        break  // Enter in editor inserts newline
        case .sessions:        jumpToFocusedSession()
        case .shellHistory:    runFocusedHistoryEntry()
        case .sshHosts:        connectFocusedSSHHost()
        }
    }

    private func clampFocus() {
        let count: Int
        switch state.paletteMode {
        case .commands:  count = filteredCommands.count
        case .notesList: count = filteredNotes.count + 1  // +1 for "new note"
        case .noteEdit:  return
        case .sessions:  count = filteredSessions.count
        case .shellHistory: count = filteredShellHistory.count
        case .sshHosts:     count = filteredSSHRows.count
        }
        guard count > 0 else { state.paletteFocusedIndex = 0; return }
        var i = state.paletteFocusedIndex % count
        if i < 0 { i += count }
        if i != state.paletteFocusedIndex { state.paletteFocusedIndex = i }
    }

    // MARK: - Commands mode

    @ViewBuilder private var commandsView: some View {
        searchBar(placeholder: "Type a command…", icon: "magnifyingglass")
        Divider().opacity(0.4)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                        CommandRow(
                            command: command,
                            index: index,
                            isFocused: index == state.paletteFocusedIndex
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
                            if hovering { state.paletteFocusedIndex = index }
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

    private var filteredCommands: [Command] {
        guard !query.isEmpty else { return commands }
        let q = query.lowercased()
        return commands.filter { $0.title.lowercased().contains(q) }
    }

    private var commands: [Command] {
        let list: [Command] = [
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
            Command(id: "shell_history", icon: "clock.arrow.circlepath",
                    title: "Shell History",
                    subtitle: "Re-run a recent command in this pane",
                    shortcut: "",
                    run: {
                        withAnimation(Theme.Spring.soft) {
                            state.paletteMode = .shellHistory
                        }
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
            Command(id: "reveal_finder", icon: "folder",
                    title: "Reveal in Finder",
                    subtitle: "Open this pane's directory in Finder",
                    shortcut: "",
                    run: { openCurrentDir(in: .finder) }),
            Command(id: "open_cursor", icon: "cursorarrow",
                    assetName: "cursor-mark",
                    title: "Open in Cursor",
                    subtitle: "Open this pane's directory in Cursor",
                    shortcut: "",
                    run: { openCurrentDir(in: .cursor) }),
            Command(id: "settings", icon: "slider.horizontal.3",
                    title: "Settings", shortcut: "⌘,",
                    run: { state.toggleSettings() }),
            Command(id: "tabs_orientation", icon: "rectangle.lefthalf.inset.filled",
                    title: "Toggle Vertical Tabs", shortcut: "",
                    run: {
                        withAnimation(Theme.Spring.soft) {
                            state.prefs.tabOrientation =
                                state.prefs.tabOrientation == .horizontal ? .vertical : .horizontal
                        }
                    }),
            Command(id: "toggle_palette", icon: "command",
                    title: "Close Command Palette", shortcut: "⌘K",
                    run: { state.togglePalette() }),
            Command(id: "quit", icon: "power",
                    title: "Quit Conterm", shortcut: "⌘Q",
                    run: { NSApp.terminate(nil) }),
        ]
        return list
    }

    private func runCommand(_ command: Command) {
        // Commands that switch palette mode shouldn't close the palette.
        // Detect those by id.
        let staysOpen = ["notes", "new_note", "sessions",
                         "shell_history", "ssh_hosts"]
        if !staysOpen.contains(command.id) {
            state.togglePalette()
        }
        command.run()
    }

    private func runFocusedCommand() {
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
        let paneIndex: Int      // 1-based within its tab
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
        searchBar(placeholder: "Filter sessions by tab, dir, or host…",
                  icon: "rectangle.3.group")
        Divider().opacity(0.4)
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
                            if hovering { state.paletteFocusedIndex = index }
                        }
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
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
        searchBar(placeholder: "Fuzzy-search your shell history…",
                  icon: "clock.arrow.circlepath")
        Divider().opacity(0.4)
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
                                if hovering { state.paletteFocusedIndex = index }
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
                .fill(isFocused ? Color.white.opacity(0.08) : .clear)
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
        searchBar(placeholder: "Filter SSH hosts…", icon: "network")
        Divider().opacity(0.4)
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
                                    if hovering { state.paletteFocusedIndex = index }
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
                .fill(isFocused ? Color.white.opacity(0.08) : .clear)
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
                ctrl.sendText(command + "\n")
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
        ctrl.sendText(command + "\n")
    }

    // MARK: - Notes-list mode

    private var filteredNotes: [Note] {
        state.notes.filtered(query)
    }

    @ViewBuilder private var notesListView: some View {
        searchBar(placeholder: "Search notes…", icon: "note.text")
        Divider().opacity(0.4)
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
            Image(systemName: icon)
                .foregroundStyle(Theme.textSecondary)
                .font(.system(size: 14, weight: .medium))
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
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
            case .shellHistory:
                keyHint("esc")
            case .sshHosts:
                keyHint("esc")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func keyHint(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.stroke))
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
                Text(command.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? Color.white.opacity(0.18) : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
        .opacity(entered ? 1 : 0)
        .offset(y: entered ? 0 : -8)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(index) * 16_000_000)
            withAnimation(Theme.Spring.soft) { entered = true }
        }
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
        } else {
            // Always-safe fallback: the SF Symbol. We reach here when
            // the asset can't be loaded — which must NEVER crash.
            Image(systemName: command.icon)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
        }
    }

    /// Load a bundled PNG as a tintable template image. Returns nil
    /// (never crashes) if it's not present.
    ///
    /// IMPORTANT: this must not touch SwiftPM's `Bundle.module`. That
    /// accessor `fatalError()`s when it can't resolve the generated
    /// `Conterm_Conterm.bundle`, which is exactly what happens on
    /// AirDropped / quarantined / translocated copies — it crashed the
    /// whole app the instant ⌘K rendered this row. We only ever read
    /// the flat copy in `Bundle.main` (Contents/Resources/<name>.png).
    private static func bundledTemplateImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name,
                                        withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            return nil
        }
        img.isTemplate = true
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? Color.white.opacity(0.18) : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }

    private func formatDate(_ d: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(d)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval/60))m ago" }
        if interval < 86400 { return "\(Int(interval/3600))h ago" }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        return fmt.string(from: d)
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

            // Trailing locator chips: window/tab/pane indices.
            HStack(spacing: 4) {
                chip("W\(row.windowIndex)")
                chip("T\(row.tabIndex)")
                chip("P\(row.paneIndex)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? Color.white.opacity(0.18) : .clear,
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
