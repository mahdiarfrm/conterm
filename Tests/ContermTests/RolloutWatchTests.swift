import Testing
@testable import Conterm

/// RolloutWatch's command and table parsers. The command line arrives
/// from a shell marker with a trailing newline — targets must come out
/// clean anyway.
struct RolloutWatchTests {

    @Test func slashTargetParses() {
        let p = RolloutWatch.parseCommand("kubectl rollout restart deployment/web\n")
        #expect(p.targets == ["web"])
        #expect(p.namespace == nil)
        #expect(!p.isApply)
    }

    @Test func spacedTargetParses() {
        let p = RolloutWatch.parseCommand("kubectl scale deployment web --replicas=5")
        #expect(p.targets == ["web"])
    }

    @Test func namespaceFlagForms() {
        let short = RolloutWatch.parseCommand("kubectl rollout restart deploy/api -n prod")
        #expect(short.targets == ["api"])
        #expect(short.namespace == "prod")
        let joined = RolloutWatch.parseCommand("kubectl set image deployment/api api=img:2 --namespace=staging")
        #expect(joined.targets == ["api"])
        #expect(joined.namespace == "staging")
    }

    @Test func setImageAssignmentIsNotATarget() {
        let p = RolloutWatch.parseCommand("kubectl set image deployment web web=nginx:1.27")
        #expect(p.targets == ["web"])
    }

    @Test func applyWithoutTargetsSweeps() {
        let p = RolloutWatch.parseCommand("kubectl apply -f app.yaml")
        #expect(p.targets.isEmpty)
        #expect(p.isApply)
    }

    @Test func unsupportedKindsIgnored() {
        let p = RolloutWatch.parseCommand("kubectl rollout restart statefulset/db")
        #expect(p.targets.isEmpty)
    }

    @Test func namespacedTableParses() {
        let rows = RolloutWatch.parseTable("default   web   2/3   3   2   5d\nkube-system   coredns   2/2   2   2   9d")
        #expect(rows.count == 2)
        #expect(rows[0].namespace == "default")
        #expect(rows[0].name == "web")
        #expect(rows[0].ready == 2)
        #expect(rows[0].desired == 3)
        #expect(rows[0].updated == 3)
    }

    @Test func bareTableParses() {
        let rows = RolloutWatch.parseTable("web   3/3   3   3   5d",
                                           namespaced: false)
        #expect(rows.count == 1)
        #expect(rows[0].name == "web")
        #expect(rows[0].desired == 3)
    }
}
