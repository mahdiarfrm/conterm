import Foundation
import Testing
@testable import Conterm

/// Turning work already done into a routine you can run again.
struct RoutineCaptureTests {

    private func step(_ payload: String, _ targets: [String] = [],
                      kind: String = "run") -> FlowStep {
        FlowStep(kind: kind, payload: payload, targets: targets)
    }

    // MARK: - Lifting the targets

    /// The difference between a routine and a saved action: the machines are
    /// an input, so it can run somewhere else next time.
    @Test func targetsBecomeAnInput() throws {
        let r = try #require(Routine.captured([step("uptime", ["web-01", "web-02"])]))
        #expect(r.steps[0].targets == ["{{hosts}}"])
        let input = try #require(r.inputs.first)
        #expect(input.key == "hosts")
        #expect(input.kind == .hosts)
        #expect(input.defaultValue == "web-01, web-02")
        #expect(r.referencedKeys == ["hosts"])
    }

    /// Captured and then launched with its own defaults must reach exactly the
    /// hosts it was captured on.
    @Test func launchingWithDefaultsReachesTheSameHosts() throws {
        let r = try #require(Routine.captured([step("uptime", ["web-01", "web-02"])]))
        let resolved = r.resolvedSteps(with: ["hosts": r.inputs[0].defaultValue])
        #expect(resolved[0].targets == ["web-01", "web-02"])
        #expect(resolved[0].payload == "uptime")
    }

    /// Steps aimed at different machines meant different machines. Collapsing
    /// them into one list would run every step everywhere.
    @Test func stepsWithDifferentTargetsKeepThem() throws {
        let r = try #require(Routine.captured([step("build", ["ci-01"]),
                                               step("deploy", ["web-01"])]))
        #expect(r.inputs.isEmpty)
        #expect(r.steps[0].targets == ["ci-01"])
        #expect(r.steps[1].targets == ["web-01"])
    }

    @Test func stepsSharingTargetsAreLiftedTogether() throws {
        let r = try #require(Routine.captured([step("pull", ["web-01"]),
                                               step("restart", ["web-01"])]))
        #expect(r.inputs.count == 1)
        #expect(r.steps.allSatisfy { $0.targets == ["{{hosts}}"] })
    }

    /// A local step has no targets and must not gain any.
    @Test func untargetedStepsStayUntargeted() throws {
        let r = try #require(Routine.captured([step("make", []),
                                               step("upload", ["web-01"])]))
        #expect(r.steps[0].targets.isEmpty)
    }

    /// Already parameterised: nothing to lift, and no second input.
    @Test func alreadyParameterisedTargetsAreLeftAlone() throws {
        let r = try #require(Routine.captured([step("uptime", ["{{box}}"])]))
        #expect(r.inputs.isEmpty)
        #expect(r.steps[0].targets == ["{{box}}"])
    }

    // MARK: - Naming

    @Test func nameComesFromTheCommand() {
        #expect(Routine.suggestedName(for: [step("systemctl restart nginx")])
                == "systemctl restart nginx")
    }

    /// `sudo` is the step's `become` flag, not part of what it is for.
    @Test func nameDropsSudo() {
        #expect(Routine.suggestedName(for: [step("sudo apt update")]) == "apt update")
    }

    @Test func nameOfAPlaybookIsItsFile() {
        #expect(Routine.suggestedName(for: [step("/srv/plays/deploy.yml", kind: "ansible")])
                == "deploy.yml")
    }

    @Test func longCommandsAreTrimmed() {
        let name = Routine.suggestedName(for: [step("a b c d e f g h i j k")])
        #expect(name == "a b c d")
    }

    // MARK: - Nothing to capture

    @Test func emptyCaptureIsNil() {
        #expect(Routine.captured([]) == nil)
        #expect(Routine.captured([step("   ")]) == nil)
    }

    @Test func blankStepsAreDropped() throws {
        let r = try #require(Routine.captured([step(""), step("uptime", ["box"])]))
        #expect(r.steps.count == 1)
        #expect(r.steps[0].payload == "uptime")
    }

    @Test func anExplicitNameWins() throws {
        let r = try #require(Routine.captured([step("uptime")], name: "Morning check"))
        #expect(r.name == "Morning check")
    }

    // MARK: - From a planned action

    @Test func anActionConvertsToAStep() {
        let action = OrbitScheduler.Action(id: UUID(), kind: .ansible,
                                           payload: "site.yml", become: true,
                                           check: true, targets: ["web-01"],
                                           createdAt: Date())
        let step = FlowStep(action)
        #expect(step.kind == "ansible")
        #expect(step.payload == "site.yml")
        #expect(step.become)
        #expect(step.check)
        #expect(step.targets == ["web-01"])
    }
}
