import SwiftUI

/// The palette's non-command modes: sessions, agents (fleet view),
/// tab groups, shell history, SSH hosts, and notes.
extension CommandPalette {
    // MARK: - Sessions mode

    /// One row in the sessions list: a single pane somewhere across
    /// all open windows. Sorted so the current pane comes first,
    /// then the rest of the current tab's panes, then other tabs in
    /// this window, then other windows.
    struct SessionRow: Identifiable {
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


    var allSessions: [SessionRow] {
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
    func groupSortKey(_ gid: UUID?) -> Int {
        guard let gid else { return Int.max }
        return tabGroups.groups.firstIndex(where: { $0.id == gid }) ?? (Int.max - 1)
    }

    var filteredSessions: [SessionRow] {
        let all = allSessions
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { row in
            row.tabLabel.lowercased().contains(q) ||
            row.dirLabel.lowercased().contains(q) ||
            (row.remoteHost?.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder var sessionsView: some View {
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

    func anyGroupsPresent(_ rows: [SessionRow]) -> Bool {
        // Show section headers if at least one row has a group.
        // A single-section "Ungrouped" header is just noise.
        rows.contains { $0.groupID != nil }
    }

    // MARK: - Agents mode (fleet view)

    /// Every pane with a live agent, across all windows. Sorted so
    /// the agents that need a human come first, then the ones still
    /// working, then the ones sitting ready; within a phase, stable
    /// window → tab → pane order.
    var allAgents: [SessionRow] {
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

    func phaseRank(_ p: AgentStatus.Phase) -> Int {
        switch p {
        case .attention:   return 0
        case .working:     return 1
        case .interrupted: return 2
        case .ready:       return 3
        case .idle:        return 4
        }
    }

    var filteredAgents: [SessionRow] {
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

    @ViewBuilder var agentsView: some View {
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
                                PaletteAgentRow(
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

    func jumpToFocusedAgent() {
        let rows = filteredAgents
        guard !rows.isEmpty else { return }
        var i = state.paletteFocusedIndex % rows.count
        if i < 0 { i += rows.count }
        jump(to: rows[i])
    }

    // MARK: - Groups mode (manage tab groups)

    var groupsHeader: some View {
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

    @ViewBuilder var groupsView: some View {
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
    func tabs(inGroup id: UUID) -> [Tab] {
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
    func sessionGroupMenu(for row: SessionRow) -> some View {
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
    func beginGroupEdit(_ gid: UUID) {
        if state.paletteOpen { state.togglePalette() }
        DispatchQueue.main.async { state.beginRenameGroup(gid) }
    }

    @ViewBuilder
    func sessionSectionHeader(groupID: UUID?, count: Int) -> some View {
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

    func jumpToFocusedSession() {
        let rows = filteredSessions
        guard !rows.isEmpty else { return }
        var i = state.paletteFocusedIndex % rows.count
        if i < 0 { i += rows.count }
        jump(to: rows[i])
    }

    func jump(to row: SessionRow) {
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
    func friendlyDirLabel(for cwd: String?) -> String {
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
    static let history: [HistoryEntry] = ShellHistory.loadAll()

    var filteredShellHistory: [HistoryEntry] {
        guard !query.isEmpty else { return Self.history }
        let q = query.lowercased()
        return Self.history.filter { $0.command.lowercased().contains(q) }
    }

    @ViewBuilder var shellHistoryView: some View {
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

    func historyRow(entry: HistoryEntry, isFocused: Bool) -> some View {
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

    func runFocusedHistoryEntry() {
        let rows = filteredShellHistory
        guard !rows.isEmpty else { return }
        var i = state.paletteFocusedIndex % rows.count
        if i < 0 { i += rows.count }
        runHistory(rows[i])
    }

    func runHistory(_ entry: HistoryEntry) {
        state.togglePalette()
        Self.runInActivePane(state: state, command: entry.command)
    }

    // MARK: - SSH hosts mode

    /// Parsed once per process from ~/.ssh/config (and any Include
    /// files). If the user edits ssh config, a Conterm restart picks
    /// up the change.
    static let sshHosts: [SSHHost] = SSHHosts.loadAll()

    struct SSHRow: Identifiable, Hashable {
        let host: SSHHost
        let isRecent: Bool
        var id: String { (isRecent ? "r-" : "a-") + host.alias }
    }

    /// Builds the full SSH row list: recents from shell history and
    /// palette clicks, followed by the remaining `~/.ssh/config`
    /// hosts. Reads the history file, so call from
    /// `refreshSSHRowsIfNeeded()` rather than from a SwiftUI body.
    func computeAllSSHRows() -> [SSHRow] {
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
    func refreshSSHRowsIfNeeded() {
        cachedAllSSHRows = computeAllSSHRows()
    }

    var filteredSSHRows: [SSHRow] {
        guard !query.isEmpty else { return cachedAllSSHRows }
        let q = query.lowercased()
        return cachedAllSSHRows.filter { row in
            row.host.alias.lowercased().contains(q) ||
            (row.host.hostname?.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder var sshHostsView: some View {
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

    func sshSectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    func sshHostRow(row: SSHRow, isFocused: Bool) -> some View {
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

    func connectFocusedSSHHost() {
        let rows = filteredSSHRows
        guard !rows.isEmpty else { return }
        var i = state.paletteFocusedIndex % rows.count
        if i < 0 { i += rows.count }
        connectToSSHHost(rows[i].host)
    }

    func connectToSSHHost(_ host: SSHHost) {
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

    var filteredNotes: [Note] {
        state.notes.filtered(query)
    }

    @ViewBuilder var notesListView: some View {
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

    func openFocusedNote() {
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

    func createAndEdit() {
        let n = state.notes.create()
        withAnimation(Theme.Spring.soft) {
            state.paletteMode = .noteEdit(noteID: n.id)
        }
    }

    // MARK: - Note-edit mode

    @ViewBuilder func noteEditView(id: UUID) -> some View {
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

    func deleteAndBack(_ id: UUID) {
        state.notes.delete(id)
        withAnimation(Theme.Spring.soft) {
            state.paletteMode = .notesList
        }
    }

}
