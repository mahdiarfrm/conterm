import AppKit
import SwiftUI

/// Driving the map from the keyboard.
///
/// Orbit is a place you work, and a place you work in with one hand on a
/// trackpad is a place you work in slowly. Every verb the action bar offers has
/// a key, and every key does the same thing the bar would: it acts on whatever
/// the bar is aimed at.
///
/// The keys are bare letters. Nothing on this canvas takes typed text unless a
/// field is open, and the monitor in `Main.swift` checks that before it claims
/// anything — see `OrbitKey.isEditing`.
enum OrbitKey: String, CaseIterable {
    // Getting around
    case nextNode, prevNode, hints
    case panUp, panDown, panLeft, panRight
    case zoomIn, zoomOut, zoomReset
    case fit, minimap

    // Views
    case viewLive, viewFleet, sessions

    // Verbs on whatever the bar is aimed at
    case primary, connect, run, playbook, overview, inspect

    // Panels
    case routines, history, deck, focusTerminal, help

    /// What the help panel shows, and the order it shows it in. Every case must
    /// appear here — `OrbitKeyTests` pins that, so a shortcut cannot be added
    /// without being documented.
    static let sections: [(String, [(String, [OrbitKey], String)])] = [
        ("Getting around", [
            ("⌘K", [], "Find a host, session, cluster or routine"),
            ("G", [hints], "Label every node — type a label to aim at it"),
            ("⇥ / ⇧⇥", [nextNode, prevNode], "Aim at the next / previous node"),
            ("↑ ↓ ← →", [panUp, panDown, panLeft, panRight],
             "Walk to the next node that way, or pan when nothing is aimed"),
            ("+ / −", [zoomIn, zoomOut], "Zoom in / out"),
            ("0", [zoomReset], "Zoom back to 100%"),
            ("F", [fit], "Fit the whole graph in view"),
            ("M", [minimap], "Show or hide the minimap"),
            ("⎋", [], "Step back: focus, then the aim, then the selection"),
        ]),
        ("Views", [
            ("1", [viewLive], "Live — what's happening now"),
            ("2", [viewFleet], "Fleet — every host you've reached"),
            ("S", [sessions], "The session list"),
        ]),
        ("Acting on what's aimed at", [
            ("⏎", [primary], "Do the obvious thing: connect, steer, or drill in"),
            ("C", [connect], "Connect — a terminal on the canvas"),
            ("R", [run], "Run a command on the selection"),
            ("P", [playbook], "Ansible playbook"),
            ("O", [overview], "Details"),
            ("E", [inspect], "What's running on it"),
        ]),
        ("Panels", [
            ("L", [routines], "Routines"),
            ("Y", [history], "What has run"),
            ("T", [deck], "Expand the timeline"),
            ("⇧⌘F", [focusTerminal], "Fill the canvas with the docked terminal"),
            ("⌘K", [], "The search field is the other way to reach a host by name"),
            ("?", [help], "This panel"),
        ]),
    ]

    /// Every key the list documents.
    static var documented: Set<OrbitKey> {
        Set(sections.flatMap { $0.1.flatMap { $0.1 } })
    }

    /// Whether a bare letter belongs to something being typed into rather than
    /// to the map.
    ///
    /// Anything that accepts text input owns its own keys — the map's fields
    /// (search, the command bar, a note, a rename) and, importantly, a docked
    /// terminal, whose `SurfaceView` is not an `NSText` but is an
    /// `NSTextInputClient`. Checking only for `NSText` ate every letter typed
    /// into a session on the canvas.
    @MainActor
    static var isEditing: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText || responder is NSTextInputClient
    }

    /// The key for a bare character, or nil if that character means nothing
    /// here. Modifier-bearing shortcuts are matched in `Main.swift`, where the
    /// modifiers are known.
    static func plain(_ char: String) -> OrbitKey? {
        switch char {
        case "g": return .hints
        case "f": return .fit
        case "m": return .minimap
        case "1": return .viewLive
        case "2": return .viewFleet
        case "s": return .sessions
        case "c": return .connect
        case "r": return .run
        case "p": return .playbook
        case "o": return .overview
        case "e": return .inspect
        case "l": return .routines
        case "y": return .history
        case "t": return .deck
        case "?": return .help
        case "0": return .zoomReset
        case "+", "=": return .zoomIn
        case "-", "_": return .zoomOut
        default: return nil
        }
    }
}

extension OrbitOverlay {

    /// Carry out whatever the key monitor named. Everything here goes through
    /// the same functions the buttons call, so a shortcut can never drift from
    /// what the bar does.
    func runOrbitKey(_ key: OrbitKey) {
        switch key {
        case .nextNode:  aimAtNeighbour(1)
        case .prevNode:  aimAtNeighbour(-1)
        case .hints:     toggleHints()
        // With a node aimed the arrows walk the graph; with nothing aimed there
        // is nothing to walk, so they move the camera instead.
        case .panUp:     aimDirection(dx: 0, dy: -1)
        case .panDown:   aimDirection(dx: 0, dy: 1)
        case .panLeft:   aimDirection(dx: -1, dy: 0)
        case .panRight:  aimDirection(dx: 1, dy: 0)
        // Unanimated, like the pan: the cards interpolate and the `Canvas`
        // behind them does not, so a glide separates the wires from the nodes
        // they join.
        case .zoomIn:    zoom = min(zoom + 0.2, 2.6)
        case .zoomOut:   zoom = max(zoom - 0.2, 0.45)
        case .zoomReset: zoom = 1
        case .fit:       fitToContent(liveGraph())
        case .minimap:   withAnimation(Theme.Spring.snappy) { showMinimap.toggle() }

        case .viewLive:
            withAnimation(Theme.Spring.soft) {
                state.orbitFocusSession = nil; spaces.currentID = nil; autoView = "live"
            }
        case .viewFleet:
            withAnimation(Theme.Spring.soft) {
                state.orbitFocusSession = nil; spaces.currentID = nil; autoView = "fleet"
            }
        case .sessions:
            withAnimation(Theme.Spring.snappy) { showSessions.toggle() }

        case .primary:
            guard let n = barNode else { return }
            handleTap(n.id, in: liveGraph())
        case .connect:   aimedHostAction { openFloating(target: $0) }
        case .run:       withAnimation(Theme.Spring.snappy) { commandOpen = true }
        case .playbook:
            guard !selectedHosts.isEmpty else { return }
            withAnimation(Theme.Spring.snappy) { inspector = .ansible }
        case .overview:
            guard let t = aimedHost else { return }
            state.openHostOverview(paneHost: t)
        case .inspect:
            guard let t = aimedHost else { return }
            toggleExpand("host:\(t)", target: t)

        case .routines:
            withAnimation(Theme.Spring.snappy) {
                showRoutines.toggle(); editingRoutine = nil; routineHistory = nil
            }
        case .history:  withAnimation(Theme.Spring.snappy) { showHistory.toggle() }
        case .deck:     withAnimation(Theme.Spring.snappy) { deckExpanded.toggle() }
        case .focusTerminal: toggleFocusedPreview()
        case .help:     withAnimation(Theme.Spring.snappy) { showHelp.toggle() }
        }
    }

    /// The single host the bar is aimed at, if that is what it is aimed at.
    var aimedHost: String? {
        if case .host(let t, _)? = barNode?.kind { return t }
        return selectedHosts.count == 1 ? selectedHosts.first : nil
    }

    func aimedHostAction(_ act: (String) -> Void) {
        guard let t = aimedHost else { return }
        act(t)
    }

    /// Unanimated, for the reason `centerOn` is: the cards interpolate and the
    /// `Canvas` behind them does not, so a glide separates the wires from the
    /// nodes they join.
    func nudgePan(dx: CGFloat, dy: CGFloat) {
        pan.width += dx; pan.height += dy
        sim.wake()
    }

    /// Walk the graph's nodes in a stable order, aiming the bar at each. Sorted
    /// by id rather than by position, because a position-ordered walk reshuffles
    /// under you every time the simulation settles a little further.
    func aimAtNeighbour(_ delta: Int) {
        let nodes = liveGraph().nodes
            .filter { !isGroup($0) && !isNote($0) }
            .sorted { $0.id < $1.id }
        guard !nodes.isEmpty else { return }
        let i = barNode.flatMap { b in nodes.firstIndex { $0.id == b.id } }
        let next = i.map { ($0 + delta + nodes.count) % nodes.count }
            ?? (delta > 0 ? 0 : nodes.count - 1)
        let node = nodes[next]
        withAnimation(Theme.Spring.snappy) { barNode = node }
        hoveredID = node.id
        centerOn(node.id)
    }
}
