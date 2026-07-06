import SwiftUI

/// The ⌘K registry + omni search: the command list, its user
/// ordering, run dispatch, and the unified query across commands,
/// SSH hosts, cwd files, shell history, notes, and the calculator.
extension CommandPalette {
    // MARK: - Commands mode

    @ViewBuilder var commandsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                        // Section markers: a "Recently used" caption above the
                        // top-picks band, and a divider where the latest-used
                        // list begins. Decorations only — they take no focus
                        // index, so keyboard nav over the rows is unaffected.
                        if let band = cachedRecentBand {
                            if index == band.lowerBound {
                                omniSectionLabel("Recently used")
                            } else if index == band.upperBound {
                                omniSectionDivider
                            }
                        }
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

    /// Caption that heads the omni "Recently used" band.
    func omniSectionLabel(_ text: String) -> some View {
        PaletteSectionCaption(text: text, icon: "clock.arrow.circlepath",
                              uppercased: true)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    /// Hairline between the top picks and the latest-used list.
    var omniSectionDivider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    var filteredCommands: [Command] {
        // Empty query keeps the command list in its configured order —
        // learned picks live in the suggestion strip above, not here.
        guard !query.isEmpty else { return commands }
        return cachedOmniResults
    }

    // MARK: - Omni search

    struct CwdFile {
        let name: String
        let path: String
        let mtime: Date
    }


    func refreshOmniSources() {
        refreshSSHRowsIfNeeded()
        // The cwd scan stats and sorts every directory entry — kept off
        // the open path so a huge directory can't stall the palette
        // mount; results land in the cache a beat later.
        let cwd = state.selectedTab?.paneTree.activePane?.cwd
        Task.detached(priority: .userInitiated) {
            let files = Self.loadRecentFiles(in: cwd)
            await MainActor.run { cachedCwdFiles = files }
        }
    }

    nonisolated static func loadRecentFiles(in cwd: String?) -> [CwdFile] {
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

    /// What the default ⌘K view shows. Empty query: learned top picks
    /// first, then the command list. Any query: a unified search
    /// across commands, SSH hosts, recent files in the pane's cwd,
    /// shell history, and notes — plus a live calculator row when the
    /// query is arithmetic. Everything is synthesized into `Command`
    /// rows so focus, Enter, and rendering need no special cases.
    func omniResults(for q: String) -> (rows: [Command], recentBand: Range<Int>?) {
        let ql = q.lowercased()
        let frec = FrecencyStore.shared
        // Each row carries a "last used" date for recency ordering: shell
        // history timestamps, file mtimes, and the frecency table's last-pick
        // date for everything else. nil when unknown (trails the dated rows).
        var rows: [(cmd: Command, recency: Date?)] = []

        rows += commands
            .filter { $0.title.lowercased().contains(ql) }
            .map { (cmd: $0, recency: frec.entries[$0.id]?.last) }

        // SSH hosts are a small set — show every match. History and
        // files can be huge, so those stay capped (the list scrolls,
        // but a thousand-row dump would bury the other sources).
        rows += cachedAllSSHRows
            .filter {
                $0.host.alias.lowercased().contains(ql)
                || ($0.host.hostname?.lowercased().contains(ql) ?? false)
            }
            .map { row -> (cmd: Command, recency: Date?) in
                let c = sshResultRow(row.host)
                return (cmd: c, recency: frec.entries[c.id]?.last)
            }

        rows += cachedCwdFiles
            .filter { $0.name.lowercased().contains(ql) }
            .prefix(8)
            .map { (cmd: fileResultRow($0), recency: $0.mtime) }

        rows += Self.history
            .filter { $0.command.lowercased().contains(ql) }
            .prefix(8)
            .map { (cmd: historyResultRow($0), recency: $0.date) }

        rows += state.notes.filtered(q).prefix(5)
            .map { note -> (cmd: Command, recency: Date?) in
                let c = noteResultRow(note)
                return (cmd: c, recency: frec.entries[c.id]?.last)
            }

        // App settings: a bool flips inline, a richer control opens
        // Settings to its section. Capped so a broad query can't bury
        // the other sources under the whole preference list.
        rows += settingsResults(matching: ql).prefix(8)
            .map { (cmd: $0, recency: frec.entries[$0.id]?.last) }

        // Two-tier ordering. Top picks: up to 3 most-used-recently matches by
        // frecency, from ANY source — habitual choices lead. The rest follow
        // newest→oldest by last-used (history timestamp, file mtime, last
        // pick), undated rows trailing in source order. Score once up front;
        // scoring inside the comparator would call score() (Date + pow)
        // O(n·log n) times per keystroke.
        let now = Date()
        let scored = rows.enumerated().map {
            (offset: $0.offset, cmd: $0.element.cmd, recency: $0.element.recency,
             score: frec.score($0.element.cmd.id, now: now))
        }
        let topPicks = scored
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(3)
        let topIDs = Set(topPicks.map { $0.cmd.id })
        let rest = scored
            .filter { !topIDs.contains($0.cmd.id) }
            .sorted { a, b in
                let da = a.recency ?? .distantPast
                let db = b.recency ?? .distantPast
                if da != db { return da > db }
                return a.offset < b.offset
            }
        var ranked = topPicks.map(\.cmd) + rest.map(\.cmd)
        var band: Range<Int>? = topPicks.isEmpty ? nil : 0 ..< topPicks.count

        // The calculator/converter answer always leads — it's the one
        // result the user can read without selecting anything.
        if let a = QuickMath.answer(q) {
            ranked.insert(calcResultRow(expression: q, answer: a), at: 0)
            band = band.map { ($0.lowerBound + 1) ..< ($0.upperBound + 1) }
        }
        return (rows: ranked, recentBand: band)
    }

    func calcResultRow(expression: String,
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

    func sshResultRow(_ host: SSHHost) -> Command {
        Command(id: "ssh.\(host.alias)", icon: "network",
                title: host.alias,
                subtitle: "SSH · \(host.hostname ?? "connect in a new tab")",
                shortcut: "",
                run: { connectToSSHHost(host) })
    }

    func fileResultRow(_ f: CwdFile) -> Command {
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

    func historyResultRow(_ entry: HistoryEntry) -> Command {
        Command(id: "hist.\(entry.command)", icon: "clock.arrow.circlepath",
                title: entry.command,
                subtitle: "History · run in this pane",
                shortcut: "",
                run: { runHistory(entry) })
    }

    func noteResultRow(_ note: Note) -> Command {
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

    static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// The suggestion strip's seven picks: the strongest frecency keys,
    /// resolved back into rows; keys whose target no longer exists
    /// resolve to nil and drop out. Until the learned picks fill all
    /// seven slots, the core destinations pad the strip.
    func suggestionRows() -> [Command] {
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
    func syncTrayState(focusTray: Bool) {
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
    @ViewBuilder var suggestionStrip: some View {
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

    func resolveSuggestion(_ key: String) -> Command? {
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

    var commands: [Command] {
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
            Command(id: "open_vscode", icon: "chevron.left.forwardslash.chevron.right",
                    assetName: "vscode-mark",
                    title: "Open in VS Code",
                    subtitle: "Open this pane's directory in VS Code",
                    shortcut: "",
                    run: { openCurrentDir(in: .vscode) }),
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
    func reordered(_ all: [Command]) -> [Command] {
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
        ("open_vscode",      "Open in VS Code",             "chevron.left.forwardslash.chevron.right"),
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

    func runCommand(_ command: Command) {
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

    func runFocusedCommand() {
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

    enum OpenTarget { case finder, cursor, vscode }

    func openCurrentDir(in target: OpenTarget) {
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
        case .vscode:
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["sh", "-c",
                "code \(shellQuote(cwd)) 2>/dev/null || open -a 'Visual Studio Code' \(shellQuote(cwd))"]
            try? task.run()
        }
    }

}
