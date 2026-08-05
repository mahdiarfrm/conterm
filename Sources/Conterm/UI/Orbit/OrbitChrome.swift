import AppKit
import Combine
import SwiftUI

/// The mode's own surfaces: header, situation bar, controls, the action
/// dock the selection aims, and the space switcher.
extension OrbitOverlay {

    /// The bundled Eurostile Bold Extended (`Sources/Conterm/Resources`),
    /// registered once for the process. Falls back to a wide, heavy system face
    /// if the file is missing.
    var orbitTitleFont: Font {
        OrbitFont.register()
        for name in ["EurostileBQ-BoldExtended", "Eurostile Bold Extended",
                     "Eurostile BQ"] where NSFont(name: name, size: 17) != nil {
            return .custom(name, size: 17)
        }
        return .system(size: 16, weight: .heavy, design: .rounded).width(.expanded)
    }

    var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // The mode switcher lives in Orbit's chrome (the tab bar that
                // normally holds it is collapsed in this mode), so you can jump
                // straight to another layout — same as agents mode. No
                // scaleEffect: it leaves phantom layout bounds that read as a gap.
                LayoutModeSwitcher()
                Spacer()
                Button { withAnimation(Theme.Spring.snappy) { showHelp.toggle() } } label: {
                    Image(systemName: showHelp ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(showHelp ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("How Orbit works")
                layoutToggle
                Button {
                    autoResolveNames.toggle()
                    if autoResolveNames { resolveAllNames() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: autoResolveNames ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Auto-resolve hosts").font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(autoResolveNames ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(autoResolveNames ? Theme.accent.opacity(0.14) : chromeFill(prefs)))
                    .overlay(Capsule().strokeBorder(autoResolveNames ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Continuously fetch & cache each host's real hostname from the server")
            }
            // The tab bar is collapsed in Orbit mode, so the canvas reaches the
            // window top; the header clears the native traffic lights on the left
            // and sits on their line (their vertical centre), not below them.
            .padding(.leading, 82).padding(.trailing, 20).padding(.top, 13)
            // Wordmark centered over the bar, independent of the left/right
            // controls' widths.
            .overlay(alignment: .top) {
                HStack(spacing: 9) {
                    OrbitMark(color: Theme.accent, size: 18)
                    Text("Orbit").font(orbitTitleFont).tracking(-0.5)
                        .foregroundStyle(Theme.textPrimary)
                    Text("BETA")
                        .font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(Capsule().fill(.white))
                }
                .padding(.top, 15)
            }
            // Centered under the wordmark with breathing room, not at the bottom
            // where the toolbar and timeline would cover it.
            situationBar
                .frame(maxWidth: .infinity)
                .padding(.top, 11)
            // What changed while you were gone, before what is true now — the
            // present is what the graph is for.
            sincePanel
                .padding(.top, 10)
            Spacer()
        }
        .allowsHitTesting(true)
    }

    /// What this mode is and how to work it. Short on purpose: the map should
    /// teach itself, and this is for the parts that can't — the gestures.
    @ViewBuilder
    var helpPanel: some View {
        if showHelp {
            ZStack(alignment: .top) {
                Color.black.opacity(0.2).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { showHelp = false } }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        OrbitMark(color: Theme.accent, size: 15)
                        Text("How Orbit works")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button { withAnimation(Theme.Spring.snappy) { showHelp = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                    helpSection("The three views", [
                        "Live — what's happening now: your sessions, the hosts you're connected to, anything mid-run.",
                        "Fleet — every host you've connected to, for when the question is \"which machine?\"",
                        "Spaces — boards you compose yourself from hosts, sessions and clusters.",
                    ])
                    helpSection("Acting on things", [
                        "Click anything to select it; the bar at the bottom carries what you can do to it.",
                        "Sessions ride the ring closest to your Mac — a host is where a session runs, not the other way round.",
                        "Right-click or double-click any node to aim that bar at it.",
                        "Click a running session to narrow the map to it; the Mac node takes you back.",
                    ])
                    helpSection("Going deeper", [
                        "A host can show what's running on it — containers, VMs, kubelet.",
                        "A cluster expands into its nodes, and a node into its pods.",
                        "Each level only refreshes while it's open.",
                    ])
                    helpSection("Getting around", [
                        "⌘K finds anything by name — a host you've never connected to, a session, a routine. Return brings it to the middle.",
                        "Scroll to pan, pinch or ± to zoom, ↺ to re-frame everything.",
                        "Esc steps back out: focus, then the aimed bar, then the selection.",
                    ])
                }
                .padding(18)
                .frame(width: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                .padding(.top, 76)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    func helpSection(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(OrbitFont.face(8)).tracking(0.6)
                .foregroundStyle(Theme.accent.opacity(0.9))
            ForEach(lines, id: \.self) { l in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").foregroundStyle(Theme.textSecondary)
                    Text(l).font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Physics vs structure, switchable while you look at it. Which reads better
    /// is a judgement about the real graph, so it's a control, not a decision.
    var layoutToggle: some View {
        HStack(spacing: 2) {
            layoutSegment("Physics", .physics)
            layoutSegment("Orbital", .structured)
        }
        .padding(2)
        .background(Capsule().fill(chromeFill(prefs)))
        .help("How nodes are arranged: organic spring layout, or a fixed orbital one")
    }

    func layoutSegment(_ title: String, _ value: OrbitSim.Layout) -> some View {
        let on = sim.layout == value
        return Button {
            layoutMode = value.rawValue
            withAnimation(Theme.Spring.soft) { sim.layout = value }
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// What Orbit answers the moment you walk in: the live situation first —
    /// who needs you, what's working, what the plan is doing — and each count is
    /// the way in to it. It names the verbs only when nothing is running.
    @ViewBuilder
    var situationBar: some View {
        if linkMode {
            // Armed: the map is waiting for a target, and that has to be said
            // somewhere you're already looking.
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 9, weight: .bold))
                Text("Tap a node to link it to this note · Esc to cancel")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(chromeFill(prefs)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
        } else if let focused = state.orbitFocusSession {
            // Focus hides the rest of the fleet, so leaving it has to be a
            // button you can see, not a sentence you have to have read.
            Button {
                withAnimation(Theme.Spring.snappy) {
                    state.orbitFocusSession = nil
                    inspector = .none
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .bold))
                    Text("Viewing \(sessionName(focused)) · show the whole fleet")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(chromeFill(prefs)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            fleetSituation
        }
    }

    /// What this view holds, counted from the view itself — so it reads
    /// differently in Live, in Fleet and on a board. Anything that wants you
    /// comes first and is clickable; the rest is a quiet inventory.
    @ViewBuilder
    var fleetSituation: some View {
        let graph = liveGraph()
        let sessions = graph.nodes.filter { $0.isSession }
        let needsYou = sessions.filter { $0.status == .attention }
        let working = sessions.filter { $0.status == .working }
        let agents = sessions.filter { $0.status != .neutral }
        let shells = sessions.count - agents.count
        let hosts = graph.nodes.filter { if case .host = $0.kind { return true }; return false }
        let running = scheduler.actions.filter { $0.status == .running }
        let queued = scheduler.actions.filter { $0.status == .pending && !$0.held }

        HStack(spacing: 7) {
            if !needsYou.isEmpty {
                situationPill("\(needsYou.count) need you", Theme.warning) { focusSession(needsYou[0]) }
            }
            if !working.isEmpty {
                situationPill("\(working.count) working", Theme.accent) { focusSession(working[0]) }
            }
            if !running.isEmpty {
                situationPill("\(running.count) running", Theme.accent) {
                    withAnimation(Theme.Spring.snappy) { pinnedActionID = running[0].id }
                }
            }
            if !queued.isEmpty {
                situationPill("\(queued.count) queued", Theme.textSecondary) {
                    withAnimation(Theme.Spring.snappy) { pinnedActionID = queued[0].id }
                }
            }
            let quiet = agents.count - needsYou.count - working.count
            let counts: [(String, Int, String)] = [
                ("sparkle", quiet, "agents"),
                ("terminal", shells, "shells"),
                ("externaldrive.connected.to.line.below.fill", hosts.count, "hosts"),
                ("shippingbox.fill", count(of: graph) { if case .container = $0 { return true }; return false }, "containers"),
                ("macwindow.on.rectangle", count(of: graph) { if case .vm = $0 { return true }; return false }, "VMs"),
                ("circle.grid.2x2.fill", count(of: graph) { if case .pod = $0 { return true }; return false }, "pods"),
                ("cube.transparent", count(of: graph) { if case .cluster = $0 { return true }; return false }, "clusters"),
            ].filter { $0.1 > 0 }
            ForEach(counts, id: \.2) { c in
                inventoryPill(c.0, c.1, c.2)
            }
            if counts.isEmpty && needsYou.isEmpty && working.isEmpty
                && running.isEmpty && queued.isEmpty {
                Text(hintText)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
        }
    }

    func count(of graph: Graph, _ match: (MapNode.Kind) -> Bool) -> Int {
        graph.nodes.reduce(0) { $0 + (match($1.kind) ? 1 : 0) }
    }

    /// A glyph and a number: what this view holds, at a glance. Quieter than the
    /// pills that want you — this is inventory, not a call to act.
    func inventoryPill(_ glyph: String, _ n: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
            Text("\(n)")
                .font(OrbitFont.face(9))
                .foregroundStyle(Theme.textPrimary.opacity(0.75))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(chromeFill(prefs)))
        .help("\(n) \(label)")
    }

    func situationPill(_ text: String, _ tint: Color,
                               _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(text).font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(chromeFill(prefs)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Open a session from the situation bar — the count is only useful if it
    /// takes you to the thing it counted.
    func focusSession(_ node: MapNode) {
        guard let pane = node.pane else { return }
        steerInput = ""
        withAnimation(Theme.Spring.snappy) {
            hoveredID = node.id
            state.orbitFocusSession = pane.id
            inspector = .agent(pane.id)
        }
        sim.wake()
    }

    var hintText: String {
        if linkMode {
            return "Tap a node to link it to this note · Esc to cancel · tap a line's middle to remove it"
        }
        if state.orbitFocusSession != nil {
            return "Pinned to this session · tap it to steer · Space menu → Live map for the whole fleet"
        }
        if scheduler.hasHeld {
            return "Drag a task onto another to chain · onto a host to target it · ⌥-drop = continue on failure · Run flow"
        }
        if spaces.current != nil {
            return "Add hosts, sessions or clusters · drag to arrange · tap one to act on it"
        }
        if isFleetView {
            return "Every host you've connected to · tap to select · Run, Playbook or Connect"
        }
        return "What's running now · tap to act · Space menu → Fleet for every host"
    }

    /// Floating flow-authoring bar: appears once tasks are staged. Run releases
    /// the whole chain from its roots; Clear discards the staged tasks.
    @ViewBuilder
    var flowControls: some View {
        if scheduler.hasHeld {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.62, green: 0.52, blue: 0.96))
                    Text("\(scheduler.heldActions.count) staged")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Divider().frame(height: 14).opacity(0.4)
                    Button {
                        scheduler.releaseHeld(); driveScheduler(); sim.wake()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                            Text("Run flow").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.accent))
                    }.buttonStyle(.plain)
                    Button {
                        for a in scheduler.heldActions { scheduler.cancel(a.id) }
                        sim.wake()
                    } label: {
                        Text("Clear").font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                .padding(.top, 84)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    var controls: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                // The space switcher lives with the view controls rather than the
                // header: which board you're on and how you're looking at it are
                // the same question.
                HStack(spacing: 2) {
                    // A key nobody is told about is a key nobody presses.
                    zoomButton("magnifyingglass") { state.toggleOrbitSearch() }
                        .help("Find a host, session or routine (⌘K)")
                    zoomButton(showSessions ? "rectangle.stack.fill" : "rectangle.stack") {
                        withAnimation(Theme.Spring.snappy) { showSessions.toggle() }
                    }
                    Divider().frame(height: 16).opacity(0.35).padding(.horizontal, 2)
                    spacesMenu
                    Divider().frame(height: 16).opacity(0.35).padding(.horizontal, 2)
                    zoomButton(showHistory ? "clock.arrow.circlepath" : "clock") {
                        withAnimation(Theme.Spring.snappy) { showHistory.toggle() }
                    }
                    // Routines are yours, not a board's, so they are reachable
                    // from the always-present controls rather than the rail a
                    // saved space brings with it.
                    zoomButton(showRoutines ? "list.bullet.rectangle.fill"
                                            : "list.bullet.rectangle") {
                        withAnimation(Theme.Spring.snappy) {
                            showRoutines.toggle(); editingRoutine = nil; routineHistory = nil
                        }
                    }
                    Divider().frame(height: 16).opacity(0.35).padding(.horizontal, 2)
                    zoomButton("minus") { zoom = max(zoom - 0.2, 0.45) }
                    zoomButton("arrow.counterclockwise") { zoom = 1; pan = .zero; sim.releaseAll() }
                    zoomButton("plus") { zoom = min(zoom + 0.2, 2.6) }
                }
                .padding(4).background(Capsule().fill(chromeFill(prefs)))
                .padding(.trailing, 18).padding(.bottom, controlsBottom)
            }
        }
    }

    func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.Spring.snappy, action) } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary).frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// The contextual action dock: the answer to "what can I do here." It rises
    /// from the bottom whenever nodes are ⌘-selected and names every action the
    /// selection affords — run, connect, playbook, copy, health, overview —
    /// with a command field wired to the primary Run/Connect action.
    @ViewBuilder
    var actionDock: some View {
        // A mixed selection is its own subject: the verbs that make sense are
        // the ones that apply to *several things at once*, not the ones that
        // belong to whichever card happened to be clicked last.
        if selection.count > 1, !selectedOthers.isEmpty {
            multiNodeBar
        } else if let aimed = barNode, !isHostNode(aimed) {
            // Re-read it from the live graph so status and subtitle stay current
            // while the bar is up; fall back to the node as aimed.
            let node = liveGraph().nodes.first { $0.id == aimed.id } ?? aimed
            // The bar is aimed at one node: it carries that node's own verbs.
            // Hosts fall through to the selection bar below, which already is
            // the host bar and can act on several at once.
            nodeBar(node)
        } else if !selectedHosts.isEmpty {
            let n = selectedHosts.count
            let hasCommand = !fleetCommand.trimmingCharacters(in: .whitespaces).isEmpty
            VStack {
                Spacer()
                // Ordered by what you came here to do: say what to run, then
                // when, then the heavier tools. Inspecting a single host lives in
                // the inspector beside it, not here — the two had the same
                // buttons, and the bar's job is acting on a selection.
                HStack(spacing: 10) {
                    Button {
                        withAnimation(Theme.Spring.snappy) {
                            selection.removeAll(); inspector = .none; commandOpen = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                            Text("\(n) host\(n == 1 ? "" : "s")")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear the selection")

                    Divider().frame(height: 18).opacity(0.4)

                    // The field is the bar's widest element and is empty most of
                    // the time, so it stays a button until you actually want to
                    // type — then it expands in place and takes focus.
                    if commandOpen {
                        TextField("Run a command…", text: $fleetCommand)
                            .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
                            .frame(width: 210)
                            .focused($commandFocused)
                            .onSubmit { runOnSelection(); commandOpen = false }
                        dockAction("chevron.right.circle.fill", "Run", primary: true,
                                   enabled: hasCommand) { runOnSelection(); commandOpen = false }
                            .help("Run it on \(n == 1 ? "this host" : "all \(n) hosts") now")
                        dockAction("calendar.badge.clock", "Later", enabled: hasCommand,
                                   action: openComposer)
                            .help("Run it at a time, or after another task finishes")
                    } else {
                        dockAction("chevron.right.circle.fill", "Run", primary: true) {
                            withAnimation(Theme.Spring.snappy) { commandOpen = true }
                            commandFocused = true
                        }
                        .help("Type a command to run on the selection")
                    }

                    Divider().frame(height: 18).opacity(0.4)

                    // Connect leads, and it lands on the map: the terminal opens
                    // as a card joined to this host. A window of its own is the
                    // second answer, for when it has to sit beside another app.
                    dockAction("bolt.horizontal.fill", "Connect", primary: true,
                               action: connect)
                        .help(n > 1 ? "Open a pane per host in one tab"
                                    : "Open a terminal on this host, here on the map")
                    if n == 1 {
                        dockAction("macwindow", "Window", action: connectInWindow)
                            .help("Open it in a window of its own instead")
                    }

                    if n == 1, let target = selectedHosts.first {
                        Divider().frame(height: 18).opacity(0.4)
                        dockAction("shippingbox",
                                   isExpanded(target) ? "Hide" : "What's running") {
                            toggleExpand("host:\(target)", target: target)
                        }
                        .help("Containers, VMs and kubelet on this host")
                        dockAction("rectangle.3.group", "Details", action: overviewSelection)
                            .help("The host's full briefing")
                    }

                    Divider().frame(height: 18).opacity(0.4)

                    dockAction("play.fill", "Playbook", asset: "ansible-mark") {
                        withAnimation(Theme.Spring.snappy) { inspector = .ansible }
                    }
                    .help("Run an Ansible playbook against the selection")
                    dockAction("arrow.up.doc", "Send file", action: copySelection)
                        .help("Copy a local file or folder to each host's home directory (scp)")

                    // A board is a thing you arranged, so taking a host off it is
                    // an edit of the board — not of the machine.
                    if spaces.current != nil {
                        dockAction("trash", "Remove") {
                            for t in selectedHosts { spaces.removeMember("host:\(t)") }
                            withAnimation(Theme.Spring.snappy) {
                                selection.removeAll(); inspector = .none; barNode = nil
                            }
                            sim.wake()
                        }
                        .help(n > 1 ? "Take these hosts off this board"
                                    : "Take this host off this board")
                    }
                }
                .popover(isPresented: $showComposer, arrowEdge: .bottom) { composerBody }
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity)
            .animation(Theme.Spring.snappy, value: selectedHosts)
        }
    }

    /// What you can do to several nodes at once. Deliberately short: an action
    /// earns its place here by meaning something for a *set*, and most verbs on
    /// this map are about one machine, one session, one pod.
    @ViewBuilder
    var multiNodeBar: some View {
        let n = selection.count
        let hosts = selectedHosts.count
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button {
                    withAnimation(Theme.Spring.snappy) {
                        selection.removeAll(); inspector = .none; barNode = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("\(n) selected")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        if hosts > 0, hosts < n {
                            Text("· \(hosts) host\(hosts == 1 ? "" : "s")")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear the selection")

                Divider().frame(height: 18).opacity(0.4)

                // Boards are where a set of nodes means something you keep.
                if spaces.current != nil {
                    if n == 2 {
                        let pair = selection.sorted()
                        dockAction("link", "Link", primary: true) {
                            spaces.addLink(from: pair[0], to: pair[1])
                            withAnimation(Theme.Spring.snappy) { selection.removeAll() }
                            sim.wake()
                        }
                        .help("Draw a connection between these two")
                    }
                    dockAction("trash", "Remove") {
                        for id in selection { spaces.removeMember(id) }
                        withAnimation(Theme.Spring.snappy) {
                            selection.removeAll(); inspector = .none; barNode = nil
                        }
                        sim.wake()
                    }
                    .help("Take these off this board")
                } else {
                    dockAction("plus.rectangle.on.rectangle", "Add to a board",
                               primary: true) {
                        withAnimation(Theme.Spring.snappy) { addingHosts = true }
                    }
                    .help("Spaces hold an arrangement you keep — pick one first")
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    func isHostNode(_ n: MapNode) -> Bool {
        if case .host = n.kind { return true }
        return false
    }

    /// The action bar, aimed at a single node. Same shape as the host bar — the
    /// subject on the left, its verbs to the right — so the bar stays the one
    /// place verbs live rather than sprouting a parallel menu per kind.
    @ViewBuilder
    func nodeBar(_ node: MapNode) -> some View {
        VStack {
            Spacer()
            if commandOpen, !suggestions.isEmpty, case .pane = node.kind {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { i, cmd in
                        HStack(spacing: 7) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
                            Text(cmd).font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(i == suggestIndex ? Theme.textPrimary
                                                                   : Theme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(i == suggestIndex ? Theme.selectionFill : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { paneCommand = cmd; commandFocused = true }
                    }
                }
                .frame(width: 340, alignment: .leading)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
                // The highlight is a full-width fill, so it has to be clipped to
                // the container or it squares off the rounded corners.
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .padding(.bottom, 6)
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(Theme.Spring.snappy) { barNode = nil }
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if let d = hostDistro(node) {
                                DistroMark(distro: d, size: 12)
                            } else {
                                Image(systemName: glyph(node))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(node.label)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            if let sub = cardSubtitle(node) {
                                Text(sub).font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: 190, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)   // no dead space after a short name
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")

                Divider().frame(height: 18).opacity(0.4)
                nodeVerbs(node)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    func nodeVerbs(_ node: MapNode) -> some View {
        switch node.kind {
        case .cluster(let ctx, _):
            dockAction("square.stack.3d.up.fill",
                       expandedContexts.contains(ctx) ? "Hide nodes" : "Nodes",
                       primary: true) { toggleContext(ctx) }
            dockAction("rectangle.3.group", "Details") { state.openClusterOverview(context: ctx) }
        case .kubeNode(let name, _):
            if let ctx = kubeContext(ofNodeID: node.id) {
                let open = expandedKubeNodes.contains(KubeDrill.podKey(ctx, name))
                let cordoned = kube.nodes[ctx]?.first { $0.name == name }?.schedulable == false
                dockAction("circle.grid.2x2.fill", open ? "Hide pods" : "Pods", primary: true) {
                    toggleKubeNode(context: ctx, node: name)
                }
                dockAction("doc.text.magnifyingglass", "Describe") {
                    kube.loadNodeDescribe(context: ctx, node: name)
                    withAnimation(Theme.Spring.snappy) { modal = .podLogs(ctx, "", name, "") }
                }
                dockAction(cordoned ? "lock.open" : "lock",
                           cordoned ? "Uncordon" : "Cordon") {
                    let apply = {
                        kube.setCordon(context: ctx, node: name, on: !cordoned)
                        KubeDrill.shared.refreshNodes(context: ctx, force: true)
                        sim.wake()
                    }
                    // Uncordoning only opens a node back up; closing one is what
                    // stops work landing anywhere, so only that side is gated.
                    if cordoned { apply() } else {
                        guarded(ctx, verb: "Cordon", subject: "Cordon \(name)",
                                detail: "New pods stop scheduling onto this node in "
                                    + "\(ctx). Pods already running on it stay, and "
                                    + "anything that cannot be placed elsewhere stays "
                                    + "Pending until the node is uncordoned.",
                                apply)
                    }
                }
                .help(cordoned ? "Let pods schedule here again"
                               : "Stop new pods scheduling here — running ones stay")
            }
        case .pod(let ns, let name):
            if let ctx = kubeContext(ofNodeID: node.id) {
                let open = expandedPods.contains(KubeDrill.containerKey(ctx, ns, name))
                let busy = kube.isBusy(ctx, ns, name)
                let work = kube.workload(ctx, ns, name)
                dockAction("shippingbox.fill", open ? "Hide containers" : "Containers",
                           primary: true) {
                    togglePod(context: ctx, namespace: ns, pod: name)
                }
                dockAction("doc.text.magnifyingglass", "Describe") {
                    kube.loadDescribe(context: ctx, namespace: ns, pod: name)
                    withAnimation(Theme.Spring.snappy) { modal = .podLogs(ctx, ns, name, "") }
                }
                .help("kubectl describe — events, conditions, why it isn't running")

                // Everything below acts on the *workload*, not this one pod, so
                // it only appears once we know what owns it.
                if let work {
                    if work.scalable {
                        dockAction("arrow.up.left.and.arrow.down.right",
                                   "Scale \(work.replicas ?? 0)", enabled: !busy) {
                            scaleDraft = work.replicas ?? 0
                            scaleTarget = (ctx, ns, name)
                        }
                        .help("Set \(work.label)'s replica count")
                    }
                    if work.restartable {
                        dockAction("arrow.clockwise", "Restart", enabled: !busy) {
                            guarded(ctx, verb: "Restart",
                                    subject: "Roll \(work.label)",
                                    detail: "Every pod of \(work.label) in \(ctx) is "
                                        + "replaced, in the controller's order. "
                                        + "Requests are served throughout only if the "
                                        + "workload's surge and availability settings "
                                        + "allow it.") {
                                kube.rolloutRestart(context: ctx, namespace: ns, pod: name,
                                                    workload: work)
                                sim.wake()
                            }
                        }
                        .help("Roll \(work.label) — every pod replaced in order")
                    }
                }
                dockAction("trash", "Delete", enabled: !busy) {
                    confirmingPodDelete = (ctx, ns, name)
                }
                .help(work?.restartable == true
                      ? "Delete this pod — \(work!.kind) replaces it"
                      : "Delete this pod")
            }
        case .podContainer(let ns, let pod, let name):
            if let ctx = kubeContext(ofNodeID: node.id) {
                dockAction("text.alignleft", "Logs", primary: true) {
                    kube.loadLogs(context: ctx, namespace: ns, pod: pod, container: name)
                    withAnimation(Theme.Spring.snappy) { modal = .podLogs(ctx, ns, pod, name) }
                }
                dockAction("terminal", "Shell") {
                    openPodShell(context: ctx, namespace: ns, pod: pod, container: name)
                }
                .help("kubectl exec into this container")
                dockAction("circle.grid.2x2.fill", pod) {
                    withAnimation(Theme.Spring.snappy) { barNode = nil }
                }
            }
        case .vm:
            if let host = parentHostTarget(of: node.id) {
                dockAction("info.circle", "Info", primary: true) {
                    withAnimation(Theme.Spring.snappy) { inspector = .vm(node.label, host) }
                }
                dockAction("externaldrive.connected.to.line.below.fill",
                           Self.hostShort(host)) {
                    withAnimation(Theme.Spring.snappy) { barNode = nil }
                    toggleHostSelection(host)
                }
            }
        case .container:
            // Resolved once: finding the parent walks the whole live graph, and
            // this bar is rebuilt on every frame it is up.
            if let host = parentHostTarget(of: node.id) {
                let name = node.label
                let busy = containers.isBusy(host: host, container: name)
                // Only a host whose probe named a runtime gets the verbs — the
                // rest keep Info, rather than a row of buttons that quietly
                // do nothing.
                if let runtime = containerRuntime(ofHost: host) {
                    let up = node.status == .ready
                    // The verb that changes with state leads, so the bar offers
                    // what you came for instead of making you read it first.
                    dockAction(up ? "stop.fill" : "play.fill", up ? "Stop" : "Start",
                               primary: true, enabled: !busy) {
                        runContainer(up ? .stop : .start, name, on: host, runtime: runtime)
                    }
                    .help(up ? "Stop this container" : "Start this container")
                    if up {
                        dockAction("arrow.clockwise", "Restart", enabled: !busy) {
                            runContainer(.restart, name, on: host, runtime: runtime)
                        }
                        dockAction("terminal", "Shell") {
                            openContainerShell(name, on: host, runtime: runtime)
                        }
                        .help("Open a shell inside this container")
                    }
                    dockAction("text.alignleft", "Logs") {
                        containers.loadLogs(container: name, host: host, runtime: runtime)
                        withAnimation(Theme.Spring.snappy) { modal = .containerLogs(host, name) }
                    }
                    dockAction("info.circle", "Info") {
                        withAnimation(Theme.Spring.snappy) { inspector = .vm(name, host) }
                    }
                    .help("Image, state, resource use — and Remove")
                } else {
                    dockAction("info.circle", "Info", primary: true) {
                        withAnimation(Theme.Spring.snappy) { inspector = .vm(name, host) }
                    }
                }
                dockAction("externaldrive.connected.to.line.below.fill",
                           Self.hostShort(host)) {
                    withAnimation(Theme.Spring.snappy) { barNode = nil }
                    toggleHostSelection(host)
                }
            }
        case .pane:
            if let p = node.pane {
                if p.agent.phase != .idle {
                    dockAction("bubble.left.and.text.bubble.right", "Steer", primary: true) {
                        steerInput = ""
                        withAnimation(Theme.Spring.snappy) { inspector = .agent(p.id) }
                    }
                    dockAction("scope", "Focus") {
                        withAnimation(Theme.Spring.snappy) {
                            state.orbitFocusSession = p.id
                            barNode = nil
                        }
                    }
                }
                // A quick-send, and only that: the fastest way to fire one
                // command without opening anything. Answering a prompt — Esc,
                // arrows, reading what came back — is Terminal's job, which
                // shows the session's real screen and takes the keyboard.
                if commandOpen {
                    TextField("Type into this shell…", text: $paneCommand)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .frame(width: 230)
                        .focused($commandFocused)
                        .onSubmit { sendToShell(p) }
                        // ↑/↓ walk the suggestions (and your history when the
                        // field is empty); ⇥ completes without sending.
                        .onKeyPress(.upArrow) { moveSuggestion(-1); return .handled }
                        .onKeyPress(.downArrow) { moveSuggestion(1); return .handled }
                        .onKeyPress(.tab) {
                            if let s = currentSuggestion { paneCommand = s; suggestIndex = 0 }
                            return .handled
                        }
                        .onChange(of: paneCommand) { _, _ in suggestIndex = 0 }
                    if let r = p.lastCommand, r.at > sentAt {
                        // The shell reports each command's exit status over
                        // OSC 133, so a mistake reads as one here rather than
                        // silently doing nothing.
                        HStack(spacing: 4) {
                            Image(systemName: r.exitCode == 0 ? "checkmark.circle.fill"
                                                              : "xmark.octagon.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(r.exitCode == 0
                                 ? String(format: "%.1fs", Double(r.durationNs) / 1e9)
                                 : "exit \(r.exitCode)")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(r.exitCode == 0 ? okGreen : failRed)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(chromeFill(prefs)))
                    }
                    // An empty field sends a bare Return, so a prompt waiting
                    // on "Enter to confirm" can be answered without opening
                    // the session.
                    dockAction("return", paneCommand.isEmpty ? "Enter" : "Send", primary: true) {
                        sendToShell(p)
                    }
                    .help(paneCommand.isEmpty ? "Press Return in this session"
                                              : "Run this in the session")
                    // The field is the widest thing on the bar; having opened it,
                    // you need a way to put it away that isn't guessing at Esc.
                    dockAction("xmark", "") {
                        withAnimation(Theme.Spring.snappy) { commandOpen = false }
                        paneCommand = ""
                    }
                    .help("Close the command field")
                } else {
                    dockAction("keyboard", "Type…", primary: p.agent.phase == .idle) {
                        withAnimation(Theme.Spring.snappy) { commandOpen = true }
                        commandFocused = true
                        sentAt = Date.distantFuture
                        loadHistoryPool()
                    }
                    .help("Send a command to this session")
                }
                dockAction("macwindow", "Terminal",
                           primary: previewPanes.contains { $0.id == p.id }) { openPreview(p) }
                    .help("Open this session's real terminal on the map")
                if p.agent.phase == .idle {
                    dockAction("sparkle", "Claude") { startAgent("claude", in: p) }
                        .help("Run claude in this shell")
                    dockAction("chevron.left.forwardslash.chevron.right", "opencode") {
                        startAgent("opencode", in: p)
                    }
                    .help("Run opencode in this shell")
                }
                if let host = p.remoteHost {
                    dockAction("externaldrive.connected.to.line.below.fill", Self.hostShort(host)) {
                        withAnimation(Theme.Spring.snappy) { barNode = nil }
                        toggleHostSelection(host)
                    }
                }
                dockAction("xmark.circle", "Close") { closeSession(p) }
                    .help("End this session — its pane closes too")
            }
        case .shellCmd:
            let tid = node.id.hasPrefix("shell:") ? String(node.id.dropFirst(6)) : node.id
            dockAction("text.alignleft", "Output", primary: true) {
                withAnimation(Theme.Spring.snappy) { modal = .shell(tid) }
            }
        case .note:
            dockAction("pencil", "Edit", primary: true) {
                if case .note(let t) = node.kind { noteDraft = t }
                withAnimation(Theme.Spring.snappy) { editingNote = node.id }
            }
            // Links are part of a board's arrangement, so they only mean
            // something in a saved space.
            if spaces.current != nil {
                dockAction("link", linkMode ? "Cancel link" : "Link to…", primary: linkMode) {
                    withAnimation(Theme.Spring.snappy) {
                        if linkMode { linkMode = false; pendingLinkFrom = nil }
                        else { linkMode = true; pendingLinkFrom = node.id; barNode = nil }
                    }
                }
                .help("Connect this note to another node — tap the node to link it")
            }
            dockAction("trash", "Delete") {
                spaces.removeNote(node.id)
                withAnimation(Theme.Spring.snappy) { barNode = nil }
                sim.wake()
            }
        case .mac:
            // Starting work shouldn't mean leaving the map to make a tab first.
            dockAction("plus.rectangle", "New shell", primary: true) { newSession(nil) }
                .help("Open a terminal session here")
            dockAction("sparkle", "New Claude") { newSession("claude") }
                .help("Open a session and start claude in it")
            dockAction("scope", "Whole fleet") {
                withAnimation(Theme.Spring.snappy) {
                    state.orbitFocusSession = nil; barNode = nil
                }
            }
            dockAction("arrow.counterclockwise", "Reset view") { resetView() }
        default:
            dockAction("arrow.counterclockwise", "Reset view", primary: true) { resetView() }
        }
    }
}
