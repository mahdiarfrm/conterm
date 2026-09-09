import Foundation
import Testing
@testable import Conterm

/// What makes a host worth a mark on the map, and what deliberately doesn't.
struct HostHealthTests {

    private func reading(_ mutate: (inout HostHealth) -> Void) -> HostHealth {
        var h = HostHealth(target: "box", at: Date(), reachable: true)
        h.everReachable = true
        mutate(&h)
        return h
    }

    // MARK: - Concerns

    @Test func healthyHostSaysNothing() {
        #expect(reading { _ in }.concerns.isEmpty)
        #expect(reading { _ in }.needsAttention == false)
    }

    @Test func failedUnitsAndRebootBothCount() {
        let h = reading { $0.failedUnits = 2; $0.rebootRequired = true }
        #expect(h.concerns == [.failedUnits, .rebootRequired])
    }

    /// The card wears one glyph, so the worst concern has to come first.
    @Test func unreachableOutranksEverything() {
        let h = reading { $0.reachable = false; $0.failedUnits = 9 }
        #expect(h.concerns == [.unreachable])
    }

    /// A machine this Mac has never logged into non-interactively is a local
    /// configuration fact, not news — otherwise a long shell history paints
    /// the whole map red the first time it is opened.
    @Test func neverReachedHostIsNotAnAlarm() {
        var h = HostHealth(target: "box", at: Date(), reachable: false)
        h.everReachable = false
        #expect(h.concerns.isEmpty)
        h.everReachable = true
        #expect(h.concerns == [.unreachable])
    }

    @Test func diskCountsOnlyOnceItIsNearlyFull() {
        #expect(reading { $0.diskWorst = 0.85 }.concerns.isEmpty)
        #expect(reading { $0.diskWorst = 0.95 }.concerns == [.diskFull])
    }

    /// Load is judged per core: 8 runnable is idle on 32 cores.
    @Test func loadIsRelativeToCores() {
        #expect(reading { $0.loadPerCore = 1.5 }.concerns.isEmpty)
        #expect(reading { $0.loadPerCore = 2.5 }.concerns == [.loadHigh])
    }

    // MARK: - Staleness

    @Test func readingsGoStale() {
        let fresh = HostHealth(target: "box", at: Date(), reachable: true)
        #expect(!fresh.isStale)
        let old = HostHealth(target: "box",
                             at: Date().addingTimeInterval(-HostHealth.staleAfter - 60),
                             reachable: true)
        #expect(old.isStale)
    }

    // MARK: - From a probe

    @Test func aProbeBecomesAReading() {
        var info = HostInfo()
        info.failedUnits = 3
        info.failedNames = ["nginx.service", "cron.service"]
        info.rebootRequired = true
        info.loadAvg = (8, 6, 4)
        info.cores = 4
        info.disks = [HostInfo.Disk(mount: "/", totalKB: 100, usedKB: 50),
                      HostInfo.Disk(mount: "/var", totalKB: 100, usedKB: 95)]

        let h = HostHealth(target: "box", info: info)
        #expect(h.reachable)
        #expect(h.everReachable)
        #expect(h.failedUnits == 3)
        #expect(h.rebootRequired)
        // The fullest filesystem is the one worth reporting, not the first.
        #expect(h.diskMount == "/var")
        #expect(h.loadPerCore == 2.0)
        #expect(h.concerns == [.failedUnits, .diskFull, .rebootRequired, .loadHigh])
    }

    /// Cores are optional on a host that didn't answer with them; dividing by
    /// a missing count must not invent a load.
    @Test func loadNeedsCoresToMeanAnything() {
        var info = HostInfo()
        info.loadAvg = (99, 99, 99)
        #expect(HostHealth(target: "box", info: info).loadPerCore == 0)
    }

    @Test func aFailedProbeKeepsOnlyTheFirstLine() {
        let h = HostHealth.unreachable(target: "box",
                                       note: "ssh: connect refused\nand more detail")
        #expect(h.reachable == false)
        #expect(h.note == "ssh: connect refused")
    }

    // MARK: - Summary

    @Test func summaryNamesEveryConcern() {
        let h = reading { $0.failedUnits = 1; $0.failedNames = ["nginx.service"] }
        #expect(h.summary.contains("nginx.service"))
        #expect(reading { _ in }.summary == "healthy")
    }

    // MARK: - Round trip

    /// The store keeps readings in the instance defaults, so they have to
    /// survive a JSON round trip unchanged.
    @Test func readingSurvivesEncoding() throws {
        let h = reading { $0.failedUnits = 2; $0.diskWorst = 0.91; $0.os = "Ubuntu" }
        let data = try JSONEncoder().encode(h)
        #expect(try JSONDecoder().decode(HostHealth.self, from: data) == h)
    }
}
