import Foundation
import Testing
@testable import Conterm

/// The first thing Orbit says on entry. It is computed from two endpoints with
/// nothing observed in between, so what it does and does not count as a change
/// is the whole design.
struct OrbitSinceTests {
    private let left = Date(timeIntervalSince1970: 1_000)
    private let now = Date(timeIntervalSince1970: 2_000)

    private func snap(_ at: Date, _ sessions: [String: String],
                      names: [String: String] = [:], hosts: [String] = []) -> OrbitSnapshot {
        OrbitSnapshot(at: at, sessions: sessions, names: names, hosts: hosts)
    }

    private func diff(_ before: OrbitSnapshot, _ after: OrbitSnapshot,
                      _ finished: [OrbitChange.FinishedTask] = []) -> [OrbitChange] {
        OrbitChange.diff(from: before, to: after, finished: finished)
    }

    @Test func aSessionThatStartedWaitingIsReported() {
        let changes = diff(snap(left, ["pane:a": "working"]),
                           snap(now, ["pane:a": "attention"], names: ["pane:a": "conterm"]))
        #expect(changes.count == 1)
        #expect(changes[0].kind == .needsYou)
        #expect(changes[0].title == "conterm")
    }

    @Test func aSessionAlreadyWaitingWhenYouLeftIsNotNews() {
        // You knew. Reporting it again buries the thing you didn't know.
        let changes = diff(snap(left, ["pane:a": "attention"]),
                           snap(now, ["pane:a": "attention"]))
        #expect(changes.isEmpty)
    }

    @Test func aSessionThatFinishedIsReported() {
        let changes = diff(snap(left, ["pane:a": "working"]),
                           snap(now, ["pane:a": "idle"], names: ["pane:a": "deploy"]))
        #expect(changes.map(\.kind) == [.finished])
        #expect(changes[0].detail == "finished")
    }

    @Test func aBusySessionThatWentAwayIsReportedByItsOldName() {
        let changes = diff(snap(left, ["pane:a": "working"], names: ["pane:a": "build"]),
                           snap(now, [:]))
        #expect(changes.map(\.kind) == [.finished])
        #expect(changes[0].title == "build")
        #expect(changes[0].detail == "closed")
    }

    @Test func anIdleSessionThatWentAwayIsNotNews() {
        // Closing a shell you weren't running anything in is not an event.
        #expect(diff(snap(left, ["pane:a": "idle"]), snap(now, [:])).isEmpty)
    }

    @Test func onlyTasksThatFinishedAfterYouLeftCount() {
        let old = OrbitChange.FinishedTask(id: UUID(), label: "old", targets: ["a"],
                                           failed: false, at: left.addingTimeInterval(-60))
        let new = OrbitChange.FinishedTask(id: UUID(), label: "site.yml", targets: ["web1"],
                                           failed: true, at: left.addingTimeInterval(60))
        let changes = diff(snap(left, [:]), snap(now, [:]), [old, new])
        #expect(changes.map(\.kind) == [.taskFailed])
        #expect(changes[0].title == "site.yml")
        #expect(changes[0].detail == "failed on web1")
    }

    @Test func hostsComingAndGoingAreBothReported() {
        let changes = diff(snap(left, [:], hosts: ["web1", "db1"]),
                           snap(now, [:], hosts: ["web1", "cache1"]))
        #expect(Set(changes.map(\.title)) == ["cache1", "db1"])
        #expect(changes.first { $0.title == "cache1" }?.kind == .hostNew)
        #expect(changes.first { $0.title == "db1" }?.kind == .hostGone)
    }

    @Test func whatWantsADecisionSortsFirst() {
        let failed = OrbitChange.FinishedTask(id: UUID(), label: "t", targets: ["a"],
                                              failed: true, at: now)
        let changes = diff(snap(left, ["pane:a": "working", "pane:b": "working"],
                                hosts: ["gone1"]),
                           snap(now, ["pane:a": "attention", "pane:b": "idle"],
                                names: ["pane:a": "needs", "pane:b": "done"],
                                hosts: ["new1"]),
                           [failed])
        #expect(changes.map(\.kind) == [.needsYou, .taskFailed, .finished, .hostGone, .hostNew])
    }

    @Test func anUnchangedFleetHasNothingToSay() {
        let s = snap(left, ["pane:a": "idle"], names: ["pane:a": "x"], hosts: ["web1"])
        #expect(diff(s, snap(now, s.sessions, names: s.names, hosts: s.hosts)).isEmpty)
    }

    @Test func aSnapshotWithFieldsMissingStillDecodes() {
        // A snapshot is a convenience; losing one must never throw away a visit.
        let data = Data(#"{"at":0}"#.utf8)
        let decoded = try? JSONDecoder().decode(OrbitSnapshot.self, from: data)
        #expect(decoded != nil)
        #expect(decoded?.sessions.isEmpty == true)
        #expect(decoded?.hosts.isEmpty == true)
    }
}
