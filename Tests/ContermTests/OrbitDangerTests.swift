import Foundation
import Testing
@testable import Conterm

/// What counts as production. Everything destructive in Orbit asks this before
/// it acts, so a false negative here is a silent scale-to-zero on a live
/// cluster and a false positive is a confirmation nobody reads.
@MainActor
struct OrbitDangerTests {

    /// The patterns come from a preference, so each test states its own and
    /// puts the user's back.
    private func withPatterns(_ value: String, _ body: () -> Void) {
        let key = "conterm.kubeDangerPatterns"
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(value, forKey: key)
        body()
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    @Test func aContextNamedForProductionIsFlagged() {
        withPatterns("prod") {
            #expect(Danger.matches("prod"))
            #expect(Danger.matches("prod-eu"))
            #expect(Danger.matches("gke_acme_us-east1_production"))
            #expect(!Danger.matches("staging"))
            #expect(!Danger.matches("dev-cluster"))
            #expect(!Danger.matches(nil))
        }
    }

    @Test func severalPatternsAreHonoured() {
        withPatterns("prod, live, canary") {
            #expect(Danger.matches("eu-live-1"))
            #expect(Danger.matches("canary"))
            #expect(!Danger.matches("test"))
        }
    }

    @Test func matchingIgnoresCase() {
        withPatterns("prod") {
            #expect(Danger.matches("PROD-EU"))
            #expect(Danger.matches("Production"))
        }
    }

    @Test func onlyTheFlaggedHostsAreReported() {
        withPatterns("prod") {
            let flagged = Danger.hosts(["web1", "prod-db", "staging-2", "app@prod"])
            #expect(flagged == ["prod-db", "app@prod"])
        }
    }

    @Test func aFleetWithNothingFlaggedGatesNothing() {
        withPatterns("prod") {
            #expect(Danger.hosts(["web1", "web2", "staging"]).isEmpty)
        }
    }

    @Test func anEmptyPatternListStillMeansProduction() {
        // Blanking the field must not quietly disable every gate in the app.
        withPatterns("   ,  ") {
            #expect(Danger.matches("prod-1"))
        }
    }
}
