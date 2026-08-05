import AppKit
import Combine
import SwiftUI

/// Getting onto a machine: the docked terminal, floating windows, and the
/// session list they are reached from.
extension OrbitOverlay {

    /// Get onto the selection, on the map. One host opens a session and shows
    /// its live terminal right there on the canvas, joined to the host's card —
    /// the map is where you are, so that is where the terminal belongs. Several
    /// hosts share one tab, a pane each: a preview per host would bury the graph
    /// they are on.
    func connect() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        if targets.count == 1, let t = targets.first {
            newSession("ssh \(t)", showOnMap: true)
        } else {
            state.fleetRun(targets: targets, command: "")
        }
    }

    /// The same session in a window of its own — separate from Conterm's, so it
    /// can sit beside another app while you work.
    func connectInWindow() {
        guard let t = selectedHosts.first else { return }
        openFloating(target: t)
    }

    /// Spawn a real macOS terminal window connected to `target` — native
    /// title bar (drag, minimize, close), floating over Orbit. Closing it (or
    /// exiting the shell) frees the surface through the normal deinit path.
    ///
    /// `running` hands the remote shell a command to become — `ssh -t` so it
    /// gets a TTY, which is what an interactive `docker exec` needs.
    func openFloating(target: String, running remote: String? = nil) {
        let line = remote.map { "ssh -t \(target) \(Self.shellQuote($0))" } ?? "ssh \(target)"
        openFloatingTerminal(title: remote == nil ? "ssh \(target)" : "\(target) · exec",
                             line: line)
    }

    /// A floating terminal running one line. The window is Orbit's, so closing
    /// it — or exiting the shell inside — frees the surface through the normal
    /// deinit path.
    func openFloatingTerminal(title: String, line: String) {
        guard let app = state.ghostty else { return }
        let pane = Pane()
        let controller = makePaneSurface(pane: pane, app: app, state: state,
                                         notifications: notifications, prefs: prefs, fontSize: 11)
        let term = FloatingTerminal(target: title, title: title, pane: pane) { id in
            floatingTerminals.removeAll { $0.id == id }
            publishFloatingPanes()
        }
        controller.onClose = { [weak term] in term?.close() }   // shell exit → close window
        floatingTerminals.append(term)
        // Hand it to the graph now, not only when it closes: a session you
        // opened is one the map has to know about, or it works away in a window
        // with no card standing for it.
        publishFloatingPanes()
        // Let the shell come up before typing at it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            controller.typeText(line); controller.sendReturn()
        }
    }

    /// Single-quote a command for the local shell that types it, closing and
    /// reopening around any quote of its own.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Hand the model the floating sessions. They are real panes carrying the
    /// same shell integration as any other — the graph just can't find them by
    /// walking windows and tabs, because they belong to neither. Registered
    /// here, a `cd` or a `claude` inside one shows up on the map like any
    /// session's would.
    func publishFloatingPanes() {
        // Only sessions that exist *only* in a window: one borrowed from a tab
        // is already found by the graph's own walk.
        OrbitModel.shared.floatingPanes = floatingTerminals.filter(\.ownsPane).map(\.pane)
        OrbitModel.shared.rebuild()
        sim.wake()
    }

    /// Start an agent in an existing shell by typing into it — the session keeps
    /// its directory and history, and the map shows it come alive in place.
    func startAgent(_ command: String, in pane: Pane) {
        send(command, to: pane)
        withAnimation(Theme.Spring.snappy) { barNode = nil }
    }

    /// Your own shell history, loaded once when the field opens. Reading the
    /// files is not free, so it is not re-read per keystroke.
    var suggestions: [String] {
        let q = paneCommand.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = q.isEmpty ? historyPool
                             : historyPool.filter { $0.lowercased().contains(q) }
        return Array(pool.prefix(5))
    }

    var currentSuggestion: String? {
        let s = suggestions
        guard suggestIndex >= 0, suggestIndex < s.count else { return nil }
        return s[suggestIndex]
    }

    func moveSuggestion(_ delta: Int) {
        let n = suggestions.count
        guard n > 0 else { return }
        suggestIndex = max(0, min(n - 1, suggestIndex + delta))
    }

    func loadHistoryPool() {
        guard historyPool.isEmpty else { return }
        Task.detached(priority: .utility) {
            let entries = ShellHistory.loadAll()
            var seen = Set<String>()
            let cmds = entries.map(\.command).filter { c in
                let t = c.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && seen.insert(t).inserted
            }
            await MainActor.run { historyPool = Array(cmds.prefix(400)) }
        }
    }

    /// Send what's in the field, and stay open for the next one.
    /// A new session, without leaving Orbit. It appears on the map as soon as
    /// the graph next rebuilds, and the bar re-aims at it so you can work in it
    /// straight away.
    func newSession(_ command: String?, showOnMap: Bool = false) {
        let tab = state.addTab()
        guard let pane = tab.paneTree.activePane else { return }
        if let command {
            // Wait for the shell before typing at it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                pane.controller?.typeText(command)
                pane.controller?.sendReturn()
            }
        }
        // Give the pane a moment to exist, then aim the bar at its node.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            OrbitModel.shared.rebuild()
            let id = "pane:\(pane.id.uuidString)"
            // On a board, a new session joins the board — you asked for it here,
            // so it belongs here rather than only in Live.
            if spaces.current != nil { addMember(id) }
            if let n = OrbitModel.shared.nodes.first(where: { $0.id == id }) {
                withAnimation(Theme.Spring.snappy) { barNode = n }
            }
            sim.wake()
        }
        // Its terminal, on the map. The tile has to exist before its view can be
        // borrowed, so this waits out the tab's first layout.
        if showOnMap {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openPreview(pane) }
        }
    }

    /// Show an existing session in a window of its own. The surface is welded to
    /// one view, so the window *borrows* that view exactly as the preview does —
    /// and gives it back when it closes, or the pane's tile is left blank.
    /// A session that already has a window is raised rather than re-hosted.
    func openInWindow(_ pane: Pane) {
        if let term = floatingTerminals.first(where: { $0.pane.id == pane.id }) {
            term.raise()
            return
        }
        closePreview(pane)                        // a surface can only be in one place
        guard PaneMounts.shared.canMount(pane.id) else { return }
        state.orbitPreviewPanes.insert(pane.id)   // exempt it from the occlusion pause
        state.syncSurfaceOcclusion()
        let title = OrbitModel.paneLabel(pane)
        let term = FloatingTerminal(target: title, title: title, pane: pane) { id in
            floatingTerminals.removeAll { $0.id == id }
            PaneMounts.shared.sendHome(pane.id)     // home before anything relayouts
            state.orbitPreviewPanes.remove(pane.id)
            state.syncSurfaceOcclusion()
        }
        term.ownsPane = false
        PaneMounts.shared.record(pane.id, at: term.contentBox)
        floatingTerminals.append(term)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pane.controller?.draw() }
    }

    /// End the session a card stands for. The pane closes in its tab (or its
    /// window, if it has one of its own) and the card goes with it on the next
    /// rebuild — a node on the map is a live thing, so removing it means ending
    /// what it stands for, not hiding the card.
    func closeSession(_ pane: Pane) {
        closePreview(pane)
        withAnimation(Theme.Spring.snappy) { barNode = nil }
        if spaces.current != nil { spaces.removeMember("pane:\(pane.id.uuidString)") }

        if let term = floatingTerminals.first(where: { $0.pane.id == pane.id }), term.ownsPane {
            term.close()
        } else {
            for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] {
                guard let tab = wc.state.tabs.first(where: { t in
                    t.paneTree.root.leaves().contains { $0.id == pane.id }
                }) else { continue }
                wc.state.closePane(tab: tab, paneID: pane.id)
                break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            OrbitModel.shared.rebuild(); sim.wake()
        }
    }

    /// A live terminal on the map. Collapsed it sits under its node's card as a
    /// preview; expanded it takes the middle of the screen and keyboard focus.
    /// Both states host the same view, so switching is instant and nothing is
    /// torn down — which is also what keeps it away from the surface-teardown
    /// crash paths.
    @ViewBuilder
    var panePreview: some View {
        // Focus hides the others rather than tiling them behind it: they would
        // be under the focused pane anyway, and a surface nobody can see is
        // still a surface being composited.
        let shown = focusedPreview.map { id in previewPanes.filter { $0.id == id } }
            ?? previewPanes
        ForEach(Array(shown.enumerated()), id: \.element.id) { rank, pane in
            // Docked, not anchored. A terminal is something you work in, so it
            // holds its place in the viewport and the graph moves *under* it —
            // an anchored card slid away under every pan and rescaled on zoom,
            // which is exactly what you don't want of the thing you're typing
            // into. Only the connector follows the node.
            let slot = previewSlot(rank, of: shown.count)
            let size = slot.size
            let pos = CGPoint(x: slot.midX, y: slot.midY)
            let focused = focusedPreview == pane.id
            ZStack {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(friendlyDirLabel(for: pane.cwd ?? "~"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if let host = pane.remoteHost {
                            Text("on " + (HostNameStore.name(for: host)
                                          ?? OrbitModel.hostLabel(host)))
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button { toggleFocusedPreview(pane) } label: {
                            Image(systemName: focused
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(focused ? Theme.accent : Theme.textSecondary)
                                .frame(width: 26, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(focused ? "Back to the dock (⇧⌘F)"
                                      : "Fill the canvas with this terminal (⇧⌘F)")
                        Button { closePreview(pane) } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 26, height: 22)     // a real target
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close — the terminal goes back to its tile")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    PaneHostBox(paneID: pane.id)
                        .frame(height: size.height - 30)   // less the header
                }
                .frame(width: size.width)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { previewFrames[pane.id] = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in previewFrames[pane.id] = f }
                        .onDisappear { previewFrames[pane.id] = nil }
                })
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                .position(pos)
            }
            .transition(.opacity)
        }
    }

    /// Every session Conterm has open, whether or not it's on this board. The
    /// map only shows what a view includes, so panes accumulate out of sight —
    /// this is where you see the whole set, find where each one is used, and
    /// close the ones you're done with.
    @ViewBuilder
    var sessionsPanel: some View {
        if showSessions {
            let rows = allSessions()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("Sessions").font(OrbitFont.face(17)).tracking(-0.4)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(rows.count)").font(OrbitFont.face(11))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        Spacer()
                        Button { withAnimation(Theme.Spring.snappy) { showSessions = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 24, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

                    if rows.isEmpty {
                        Text("No sessions open")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(rows, id: \.pane.id) { row in sessionRow(row) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                // Its own frame, so scrolling the list scrolls the list rather
                // than panning the map underneath it.
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { sessionsFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in sessionsFrame = f }
                })
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
                .padding(.trailing, 18).padding(.top, 58)
                .padding(.bottom, deckClearance)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    struct SessionRow {
        let pane: Pane
        let tab: Tab
        let tag: String          // SHELL 2 / AGENT 1
        let where_: String       // the spaces it's on, or where it lives
    }

    func allSessions() -> [SessionRow] {
        let ordinals = kindOrdinals(Graph(nodes: model.nodes, edges: model.edges))
        var out: [SessionRow] = []
        for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] {
            for tab in wc.state.tabs {
                for pane in tab.paneTree.root.leaves() {
                    let id = "pane:\(pane.id.uuidString)"
                    let node = model.nodes.first { $0.id == id }
                    let tag = node.flatMap { kindTag($0, ordinals: ordinals) }
                        ?? (pane.agent.phase == .idle ? "SHELL" : "AGENT")
                    let boards = spaces.spaces.filter { $0.members.contains(id) }.map(\.name)
                    out.append(SessionRow(pane: pane, tab: tab, tag: tag,
                                          where_: boards.isEmpty ? "Live only"
                                                                 : boards.joined(separator: " · ")))
                }
            }
        }
        // Whoever wants you first, then whatever is working, then the rest.
        // A list of sessions ordered by which window they happen to be in
        // makes you read all of it to find the one that stopped.
        return out.sorted {
            let a = sessionUrgency($0.pane), b = sessionUrgency($1.pane)
            if a != b { return a < b }
            return OrbitModel.paneLabel($0.pane)
                .localizedCaseInsensitiveCompare(OrbitModel.paneLabel($1.pane)) == .orderedAscending
        }
    }

    /// Lower sorts first. Both states that are stopped waiting on a person come
    /// before anything still moving; a plain shell with no agent in it is last.
    func sessionUrgency(_ pane: Pane) -> Int {
        switch pane.agent.phase {
        case .attention:   return 0
        case .interrupted: return 1
        case .working:     return 2
        case .ready:       return 3
        case .idle:        return 4
        }
    }

    func sessionRow(_ row: SessionRow) -> some View {
        let live = row.pane.agent.phase != .idle
        return HStack(spacing: 10) {
            Circle()
                .fill(live ? (row.pane.agent.phase == .attention ? Theme.warning : Theme.accent)
                           : Theme.textSecondary.opacity(0.35))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.tag).font(OrbitFont.face(8.5)).tracking(0.5)
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Text(friendlyDirLabel(for: row.pane.cwd))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(row.where_)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { openInWindow(row.pane) } label: {
                Image(systemName: "macwindow").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open its terminal in a window")
            // The same close the session's own bar performs: this list spans
            // every window, and closing through *this* window's state can only
            // reach its own tabs.
            Button { closeSession(row.pane) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Close this session")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            if let n = model.nodes.first(where: { $0.id == "pane:\(row.pane.id.uuidString)" }) {
                withAnimation(Theme.Spring.snappy) { barNode = n }
            }
        }
    }


    func openPreview(_ pane: Pane) {
        // A floating session's terminal already has a window. Its surface is
        // welded to one view and can only be in one place, so the answer is to
        // raise that window rather than draw an empty card over the map.
        guard PaneMounts.shared.canMount(pane.id) else {
            floatingTerminals.first { $0.pane.id == pane.id }?.raise()
            return
        }
        // Already on the map: bring the keyboard to it rather than opening a
        // second card onto the same surface, which there is only one of.
        guard !previewPanes.contains(where: { $0.id == pane.id }) else {
            focusPreview(pane)
            return
        }
        state.orbitPreviewPanes.insert(pane.id)
        state.syncSurfaceOcclusion()          // wake this pane's renderer
        withAnimation(Theme.Spring.snappy) { previewPanes.append(pane) }
        focusPreview(pane)
        // The surface was paused while Orbit was open, so its last frame is
        // stale. Ask *this* pane for a fresh one: the app-wide redraw only
        // covers the selected tab, and a session in any other tab would open
        // as a blank rectangle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pane.controller?.draw()
        }
        sim.wake()
    }

    /// Grow one docked terminal to fill the canvas, or hand it back to the
    /// band. Nothing is torn down either way — the same host view is reframed,
    /// which is what keeps this away from the surface-teardown crash paths.
    func toggleFocusedPreview(_ pane: Pane) {
        withAnimation(Theme.Spring.soft) {
            focusedPreview = focusedPreview == pane.id ? nil : pane.id
        }
        focusPreview(pane)
    }

    /// Fill the canvas with whichever terminal the keyboard is in, or the only
    /// one docked. Answers ⇧⌘F, where there is no button under the cursor.
    func toggleFocusedPreview() {
        if focusedPreview != nil {
            withAnimation(Theme.Spring.soft) { focusedPreview = nil }
            return
        }
        let target = previewPanes.first { $0.id == state.orbitFocusSession }
            ?? previewPanes.first
        guard let target else { return }
        toggleFocusedPreview(target)
    }

    /// Give one view back to its pane box. Always paired with opening it, and
    /// called on the way out of Orbit too — a host left lent out would leave its
    /// tile blank when you returned.
    func closePreview(_ pane: Pane) {
        guard previewPanes.contains(where: { $0.id == pane.id }) else { return }
        withAnimation(Theme.Spring.snappy) { previewPanes.removeAll { $0.id == pane.id } }
        previewFrames[pane.id] = nil
        if focusedPreview == pane.id { focusedPreview = nil }
        PaneMounts.shared.sendHome(pane.id)
        state.orbitPreviewPanes.remove(pane.id)
        state.syncSurfaceOcclusion()          // back to paused behind Orbit
    }

    /// Hand every borrowed view home at once — leaving Orbit, or closing it.
    func closeAllPreviews() {
        for pane in previewPanes { PaneMounts.shared.sendHome(pane.id) }
        previewPanes.removeAll()
        previewFrames.removeAll()
        focusedPreview = nil
        state.orbitPreviewPanes.removeAll()
        state.syncSurfaceOcclusion()
    }

    func focusPreview(_ pane: Pane) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let v = pane.controller?.view { v.window?.makeFirstResponder(v) }
        }
    }

    func sendToShell(_ pane: Pane) {
        // ⏎ takes the highlighted suggestion when you've arrowed onto one.
        let picked = suggestIndex > 0 ? currentSuggestion : nil
        let cmd = (picked ?? paneCommand).trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else {
            // Nothing typed: just press Return in the session.
            pane.controller?.sendReturn()
            return
        }
        sentAt = Date()
        historyPool.removeAll { $0 == cmd }
        historyPool.insert(cmd, at: 0)      // your own sends rank first next time
        suggestIndex = 0
        send(cmd, to: pane)
        paneCommand = ""
        commandFocused = true
    }

    func send(_ command: String, to pane: Pane) {
        pane.controller?.typeText(command)
        pane.controller?.sendReturn()
        // The shell reports its new directory over OSC when the next prompt
        // draws, which is after the command runs — so look more than once, and
        // the card follows without waiting for the next slow tick.
        for delay in [0.4, 0.9, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                OrbitModel.shared.rebuild()
                sim.wake()
            }
        }
        sim.wake()
    }
}
