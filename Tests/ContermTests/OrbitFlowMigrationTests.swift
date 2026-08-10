import Foundation
import Testing
@testable import Conterm

/// Flows were retired into the routine library. Nothing writes one any more, so
/// the only thing that still has to work is *reading* a board saved before the
/// change — if that decode breaks, the sequences it holds are gone before
/// anything gets the chance to lift them.
struct OrbitFlowMigrationTests {

    private func decodeSpace(_ json: String) -> OrbitSpace? {
        try? JSONDecoder().decode(OrbitSpace.self, from: Data(json.utf8))
    }

    @Test func aBoardSavedWithFlowsStillDecodesThem() {
        let space = decodeSpace("""
        {"id":"\(UUID().uuidString)","name":"prod","members":[],
         "flows":[{"id":"\(UUID().uuidString)","name":"deploy",
                   "steps":[{"id":"\(UUID().uuidString)","kind":"ansible",
                             "payload":"site.yml","targets":["web1","web2"],
                             "become":true,"check":false,"continueOnFailure":false}]}]}
        """)
        #expect(space?.flows.count == 1)
        #expect(space?.flows.first?.name == "deploy")
        let step = space?.flows.first?.steps.first
        #expect(step?.payload == "site.yml")
        #expect(step?.targets == ["web1", "web2"])
        #expect(step?.become == true)
    }

    @Test func aBoardWithNoFlowsDecodesToNone() {
        let space = decodeSpace("""
        {"id":"\(UUID().uuidString)","name":"staging","members":["host:web1"]}
        """)
        #expect(space?.flows.isEmpty == true)
        #expect(space?.members == ["host:web1"])
    }

    @Test func aFlowsStepsBecomeARoutinesStepsUnchanged() {
        // The lift is a rename, not a translation: what ran before must run the
        // same way afterwards.
        let steps = [
            FlowStep(kind: "run", payload: "systemctl restart app", targets: ["web1"]),
            FlowStep(kind: "ansible", payload: "site.yml", targets: ["web1", "web2"],
                     continueOnFailure: true),
        ]
        let flow = OrbitFlow(name: "deploy", steps: steps)
        let routine = Routine(name: flow.name, steps: flow.steps)
        #expect(routine.steps.count == 2)
        #expect(routine.steps.map(\.payload) == ["systemctl restart app", "site.yml"])
        #expect(routine.steps[1].continueOnFailure)
        #expect(routine.name == "deploy")
    }
}
