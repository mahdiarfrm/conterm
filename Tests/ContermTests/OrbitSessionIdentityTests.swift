import Foundation
import Testing
@testable import Conterm

/// A session is the subject of the map and a host is where it runs, so the two
/// cards must never read the same. This is the rule that keeps them apart.
@MainActor
struct OrbitSessionIdentityTests {

    private func remoteShell(host: String, remoteCwd: String? = nil) -> Pane {
        let pane = Pane()
        pane.remoteHost = host
        if let remoteCwd {
            pane.cwd = remoteCwd
            pane.cwdIsRemote = true
        }
        return pane
    }

    @Test func aRemoteShellIsNeverTitledByItsHost() {
        let pane = remoteShell(host: "elastic-01")
        // The host's own card is called `elastic-01`. If the session's card is
        // too, the map holds two cards nobody can tell apart — so it is named
        // by the connection instead.
        #expect(OrbitModel.paneLabel(pane) == "on elastic-01")
        #expect(OrbitModel.paneLabel(pane) != "elastic-01")
    }

    @Test func anUnlocatedRemoteShellDoesNotRepeatItselfInTheSubtitle() {
        // The label already says which machine, so the subtitle saying it again
        // gives the card two lines that carry one fact.
        let pane = remoteShell(host: "elastic-01")
        #expect(OrbitModel.paneSubtitle(pane, isCurrent: false) == nil)
    }

    @Test func aReportedRemoteDirectoryTitlesTheSession() {
        // Once the far end reports a directory, that is the honest identity and
        // the host moves to the subtitle.
        let pane = remoteShell(host: "elastic-01", remoteCwd: "/srv/app")
        #expect(OrbitModel.paneLabel(pane).hasSuffix("app"))
        #expect(OrbitModel.paneLabel(pane) != "shell")
        #expect(OrbitModel.paneSubtitle(pane, isCurrent: false) == "on elastic-01")
    }

    @Test func aLocalSessionKeepsItsDirectory() {
        let pane = Pane()
        pane.cwd = "/Users/x/Documents/conterm"
        #expect(OrbitModel.paneLabel(pane).hasSuffix("conterm"))
        #expect(OrbitModel.paneSubtitle(pane, isCurrent: false) == nil)
    }

    @Test func sessionsLeadTheMacsRingAheadOfHosts() {
        // Ring order is the map's headline: the work first, the machines it
        // runs against after.
        let session = MapNode(id: "pane:1", kind: .pane(UUID()), label: "app",
                              subtitle: nil, status: .working, pane: nil)
        let host = MapNode(id: "host:web1", kind: .host(target: "web1", active: true),
                           label: "web1", subtitle: nil, status: .neutral, pane: nil)
        #expect(OrbitLayout.sortKey(session) < OrbitLayout.sortKey(host))
    }

    @Test func anIdleHostStillSortsBehindAConnectedOne() {
        let live = MapNode(id: "host:a", kind: .host(target: "a", active: true),
                           label: "a", subtitle: nil, status: .neutral, pane: nil)
        let idle = MapNode(id: "host:b", kind: .host(target: "b", active: false),
                           label: "b", subtitle: nil, status: .neutral, pane: nil)
        #expect(OrbitLayout.sortKey(live) < OrbitLayout.sortKey(idle))
    }
}

/// Numbering on a card is only information when it separates two cards that
/// would otherwise read identically.
@MainActor
struct OrbitCardOrdinalTests {
    private let view = OrbitOverlay()

    private func node(_ id: String, _ kind: MapNode.Kind, _ label: String) -> MapNode {
        MapNode(id: id, kind: kind, label: label, subtitle: nil, status: .neutral, pane: nil)
    }

    @Test func uniquelyNamedHostsCarryNoNumber() {
        let graph = OrbitOverlay.Graph(nodes: [
            node("host:a", .host(target: "a", active: true), "sib-02"),
            node("host:b", .host(target: "b", active: true), "elastic-01"),
            node("host:c", .host(target: "c", active: true), "jira"),
        ], edges: [])
        let ordinals = view.kindOrdinals(graph)
        #expect(ordinals.isEmpty)
        #expect(view.kindTag(graph.nodes[0], ordinals: ordinals) == "HOST")
    }

    @Test func repeatedNamesAreNumbered() {
        // Remote shells are all called `shell`, which is exactly the case the
        // ordinal exists for.
        let graph = OrbitOverlay.Graph(nodes: [
            node("pane:1", .pane(UUID()), "shell"),
            node("pane:2", .pane(UUID()), "shell"),
        ], edges: [])
        let ordinals = view.kindOrdinals(graph)
        #expect(ordinals.count == 2)
        #expect(Set(ordinals.values) == [1, 2])
        #expect(view.kindTag(graph.nodes[0], ordinals: ordinals) == "SHELL 1")
    }

    @Test func sameNameDifferentKindIsNotAmbiguous() {
        // A host and a session sharing a name is the collision the labelling
        // rule prevents; if it ever happens, numbering them together would
        // read as though they were the same kind of thing.
        let graph = OrbitOverlay.Graph(nodes: [
            node("host:a", .host(target: "a", active: true), "web1"),
            node("pane:1", .pane(UUID()), "web1"),
        ], edges: [])
        #expect(view.kindOrdinals(graph).isEmpty)
    }

    @Test func theMacIsNeverNumberedOrTagged() {
        let graph = OrbitOverlay.Graph(nodes: [
            node("mac", .mac, "This Mac"),
        ], edges: [])
        let ordinals = view.kindOrdinals(graph)
        #expect(ordinals.isEmpty)
        #expect(view.kindTag(graph.nodes[0], ordinals: ordinals) == nil)
    }
}
