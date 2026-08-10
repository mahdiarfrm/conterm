import Foundation
import Testing
@testable import Conterm

/// Orbit's stores decode with `try?` and fall back to empty, so a decode
/// failure is silent data loss: one added field would drop every saved space
/// or the whole plan history. These pin the tolerance that prevents it.
struct OrbitPersistenceTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Spaces

    @Test func spaceDecodesWithoutLinksOrFlows() throws {
        // A board written before `links` and `flows` existed.
        let space = try decode(OrbitSpace.self, """
        {"id":"1771D95D-9C22-4477-80B3-8A7B2FC1D3E6","name":"Space 1",
         "members":["host:root@10.0.0.1"],
         "positions":{"host:root@10.0.0.1":{"x":1.5,"y":-2.5}},
         "notes":[]}
        """)
        #expect(space.name == "Space 1")
        #expect(space.members == ["host:root@10.0.0.1"])
        #expect(space.positions["host:root@10.0.0.1"]?.x == 1.5)
        #expect(space.links.isEmpty)
        #expect(space.flows.isEmpty)
    }

    @Test func spaceListSurvivesAPartialSchema() throws {
        // The whole array must load — the store keeps `[OrbitSpace]`, so one
        // unreadable member used to take every space with it.
        let spaces = try decode([OrbitSpace].self, """
        [{"name":"Old"},
         {"id":"2771D95D-9C22-4477-80B3-8A7B2FC1D3E6","name":"New",
          "members":[],"positions":{},"notes":[],"links":[],"flows":[]}]
        """)
        #expect(spaces.count == 2)
        #expect(spaces[0].name == "Old")
        #expect(spaces[0].flows.isEmpty)
    }

    @Test func flowStepDefaultsItsNewerFields() throws {
        let step = try decode(FlowStep.self, #"{"kind":"ansible","payload":"site.yml"}"#)
        #expect(step.kind == "ansible")
        #expect(step.payload == "site.yml")
        #expect(step.targets.isEmpty)
        #expect(step.continueOnFailure == false)
        #expect(step.become == false)
    }

    @Test func flowDecodesWithoutSteps() throws {
        let flow = try decode(OrbitFlow.self, #"{"name":"Deploy"}"#)
        #expect(flow.name == "Deploy")
        #expect(flow.steps.isEmpty)
    }

    // MARK: - Plan

    @MainActor
    @Test func actionDecodesWithoutNewerFields() throws {
        // A plan entry written before `held`, `afterAnyOutcome`, `output`,
        // `agentTrigger` and `steerPaneID` existed.
        let a = try decode(OrbitScheduler.Action.self, """
        {"id":"32FFEC65-E547-4D72-AF52-77F2B4D6F1CD","kind":"run",
         "payload":"ls","targets":["admin@10.0.0.1"],
         "become":false,"check":false,"status":"failed",
         "createdAt":806954769.396579}
        """)
        #expect(a.kind == .run)
        #expect(a.payload == "ls")
        #expect(a.status == .failed)
        #expect(a.held == false)
        #expect(a.afterAnyOutcome == false)
        #expect(a.output == nil)
        #expect(a.agentTrigger == nil)
        #expect(a.isTerminal)
    }

    @MainActor
    @Test func actionRoundTripsEveryField() throws {
        var a = OrbitScheduler.Action(id: UUID(), kind: .ansible, payload: "site.yml",
                                      become: true, check: true,
                                      targets: ["web1", "web2"],
                                      runAt: Date(timeIntervalSinceReferenceDate: 900_000),
                                      dependsOn: UUID(), createdAt: Date())
        a.afterAnyOutcome = true
        a.held = true
        a.status = .running
        a.output = "ok"
        a.resultNote = "2 ok"
        a.agentTrigger = .init(paneID: UUID(), phase: "attention", label: "web1")

        let back = try JSONDecoder().decode(OrbitScheduler.Action.self,
                                            from: JSONEncoder().encode(a))
        #expect(back.id == a.id)
        #expect(back.kind == .ansible)
        #expect(back.become && back.check)
        #expect(back.targets == ["web1", "web2"])
        #expect(back.runAt == a.runAt)
        #expect(back.dependsOn == a.dependsOn)
        #expect(back.afterAnyOutcome)
        #expect(back.held)
        #expect(back.output == "ok")
        #expect(back.resultNote == "2 ok")
        #expect(back.agentTrigger == a.agentTrigger)
    }

    @MainActor
    @Test func actionLabelNamesEachKind() throws {
        func make(_ kind: OrbitScheduler.Kind, _ payload: String) -> OrbitScheduler.Action {
            OrbitScheduler.Action(id: UUID(), kind: kind, payload: payload,
                                  targets: [], createdAt: Date())
        }
        #expect(make(.run, "uptime").label == "uptime")
        #expect(make(.run, "").label == "Connect")
        #expect(make(.ansible, "/etc/ansible/site.yml").label == "site.yml")
        #expect(make(.copy, "/tmp/bundle.tgz").label == "scp bundle.tgz")
    }
}
