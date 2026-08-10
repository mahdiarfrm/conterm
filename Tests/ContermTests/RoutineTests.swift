import Foundation
import Testing
@testable import Conterm

/// Substitution is the whole difference between a saved flow and a routine, and
/// it decides what actually runs on a machine — so the holes, the filling and
/// the target splitting are pinned here.
struct RoutineTests {
    private func routine(_ steps: [FlowStep], inputs: [RoutineInput] = []) -> Routine {
        Routine(name: "r", inputs: inputs, steps: steps)
    }

    @Test func findsEveryReferencedKey() {
        let r = routine([
            FlowStep(payload: "deploy {{branch}} to {{env}}", targets: ["{{hosts}}"]),
            FlowStep(payload: "echo done"),
        ])
        #expect(r.referencedKeys == ["branch", "env", "hosts"])
    }

    @Test func aPayloadWithoutHolesReferencesNothing() {
        #expect(routine([FlowStep(payload: "uptime")]).referencedKeys.isEmpty)
        // An unterminated brace is not a key.
        #expect(Routine.keys(in: "echo {{oops").isEmpty)
        #expect(Routine.keys(in: "{{}}").isEmpty)
    }

    @Test func fillsWithAndWithoutInnerSpaces() {
        #expect(Routine.fill("git checkout {{branch}}", with: ["branch": "main"])
                == "git checkout main")
        #expect(Routine.fill("git checkout {{ branch }}", with: ["branch": "main"])
                == "git checkout main")
    }

    @Test func leavesUnknownHolesAlone() {
        // Better a visible {{typo}} in the command than a silently empty one.
        #expect(Routine.fill("echo {{typo}}", with: ["other": "x"]) == "echo {{typo}}")
    }

    @Test func resolvesStepsIntoWhatWillRun() {
        let r = routine([FlowStep(kind: "run", payload: "systemctl restart {{svc}}",
                                  targets: ["{{hosts}}"])])
        let steps = r.resolvedSteps(with: ["svc": "nginx", "hosts": "web1, web2"])
        #expect(steps.count == 1)
        #expect(steps[0].payload == "systemctl restart nginx")
        // A hosts input is one field the user types; the plan needs a list.
        #expect(steps[0].targets == ["web1", "web2"])
    }

    @Test func splitsHostsOnCommasAndWhitespaceAlike() {
        let r = routine([FlowStep(payload: "uptime", targets: ["{{hosts}}"])])
        #expect(r.resolvedSteps(with: ["hosts": "a b\tc,d ,, e"])[0].targets
                == ["a", "b", "c", "d", "e"])
    }

    @Test func keepsLiteralTargetsThatHaveNoHoles() {
        let r = routine([FlowStep(payload: "uptime", targets: ["web1", "web2"])])
        #expect(r.resolvedSteps(with: [:])[0].targets == ["web1", "web2"])
    }

    @Test func stepKindAndFlagsSurviveResolution() {
        let r = routine([FlowStep(kind: "ansible", payload: "{{book}}.yml", become: true,
                                  check: true, targets: ["web1"], continueOnFailure: true)])
        let s = r.resolvedSteps(with: ["book": "deploy"])[0]
        #expect(s.kind == "ansible")
        #expect(s.payload == "deploy.yml")
        #expect(s.become)
        #expect(s.check)
        #expect(s.continueOnFailure)
    }
}

/// A run is the record you come back for, so its settling rules matter: a run
/// that never finishes is a history that lies.
struct RoutineRunTests {
    private func run(steps: Int, ids: [UUID]) -> RoutineRun {
        var r = RoutineRun(routineID: UUID(), routineName: "r", startedAt: Date())
        r.steps = (0..<steps).map { RoutineRun.Step(label: "s\($0)", targets: ["h"], outcome: nil) }
        r.actionIDs = ids
        return r
    }

    @Test func aFreshRunIsNeitherFinishedNorFailed() {
        let r = run(steps: 2, ids: [UUID(), UUID()])
        #expect(!r.isFinished)
        #expect(!r.failed)
    }

    @Test func oneFailedStepFailsTheRun() {
        var r = run(steps: 2, ids: [UUID(), UUID()])
        r.steps[0].outcome = "ok"
        r.steps[1].outcome = "failed"
        #expect(r.failed)
    }
}
