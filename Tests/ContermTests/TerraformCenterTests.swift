import Foundation
import Testing
@testable import Conterm

/// TerraformCenter's reading of `terraform show -json`. The fixture is a
/// trimmed capture from terraform 1.14.3 covering the three shapes that
/// matter: an update, a replace (which terraform encodes as a delete and a
/// create, not as its own action), and a create.
@MainActor
struct TerraformCenterTests {

    private func plan(_ json: String) -> TerraformCenter.Plan? {
        TerraformCenter.parsePlan(Data(json.utf8), dir: "/infra/prod",
                                  command: "terraform plan")
    }

    private let fixture = """
    {
     "format_version": "1.2",
     "terraform_version": "1.14.3",
     "resource_changes": [
      {"address": "terraform_data.a", "type": "terraform_data", "name": "a",
       "change": {"actions": ["update"],
        "before": {"id": "805488", "input": "hello", "output": "hello",
                   "triggers_replace": null},
        "after": {"id": "805488", "input": "CHANGED",
                  "triggers_replace": null}}},
      {"address": "terraform_data.b", "type": "terraform_data", "name": "b",
       "change": {"actions": ["delete", "create"],
        "before": {"id": "3d5650", "input": "world", "output": "world",
                   "triggers_replace": null},
        "after": {"input": "world", "triggers_replace": ["v2"]}}},
      {"address": "terraform_data.c", "type": "terraform_data", "name": "c",
       "change": {"actions": ["create"], "before": null,
        "after": {"input": "new", "triggers_replace": null}}},
      {"address": "terraform_data.d", "type": "terraform_data", "name": "d",
       "change": {"actions": ["delete"],
        "before": {"id": "aaa", "input": "old"}, "after": null}},
      {"address": "terraform_data.e", "type": "terraform_data", "name": "e",
       "change": {"actions": ["no-op"], "before": {"input": "same"},
        "after": {"input": "same"}}}
     ],
     "output_changes": {"greeting": {"actions": ["update"]},
                        "stable": {"actions": ["no-op"]}}
    }
    """

    @Test func countsFollowTerraformsOwnPhrasing() throws {
        let p = try #require(plan(fixture))
        #expect(p.terraformVersion == "1.14.3")
        #expect(p.toAdd == 1)
        #expect(p.toChange == 1)
        // A replace destroys as surely as a delete does, so it counts here.
        #expect(p.toDestroy == 2)
        #expect(p.summary == "1 to add · 1 to change · 2 to destroy")
    }

    /// Terraform has no "replace" action: it emits the delete/create pair,
    /// in either order depending on create_before_destroy.
    @Test func deleteCreatePairIsAReplace() throws {
        let p = try #require(plan(fixture))
        let b = try #require(p.resources.first { $0.address == "terraform_data.b" })
        #expect(b.action == .replace)
    }

    /// Destroy leads, then replace — the card is read for its destroys.
    @Test func resourcesSortByConsequence() throws {
        let p = try #require(plan(fixture))
        #expect(p.resources.map(\.action) == [.destroy, .replace, .create, .update])
    }

    /// no-op rows are noise: terraform emits them, the card never shows them.
    @Test func noOpsAreDropped() throws {
        let p = try #require(plan(fixture))
        #expect(!p.resources.contains { $0.address == "terraform_data.e" })
        #expect(!p.outputsChanged.contains("stable"))
        #expect(p.outputsChanged == ["greeting"])
    }

    @Test func updatesNameTheAttributesThatDiffer() throws {
        let p = try #require(plan(fixture))
        let a = try #require(p.resources.first { $0.address == "terraform_data.a" })
        // `output` is absent from `after` (unknown until apply) — absent and
        // present-with-a-value are different, so it counts as changed.
        #expect(a.changedNames == ["input", "output"])
    }

    /// The card shows both sides, so both sides have to survive parsing.
    @Test func changedAttributesCarryBothSides() throws {
        let p = try #require(plan(fixture))
        let a = try #require(p.resources.first { $0.address == "terraform_data.a" })
        let input = try #require(a.changed.first { $0.name == "input" })
        #expect(input.before == "hello")
        #expect(input.after == "CHANGED")
        // Absent on one side reads as unset, never as the string "null".
        let output = try #require(a.changed.first { $0.name == "output" })
        #expect(output.before == "hello")
        #expect(output.after == nil)
    }

    /// Creates and destroys carry no attribute list: "everything" and
    /// "nothing" are the honest answers, and neither is worth rendering.
    @Test func createsAndDestroysListNoAttributes() throws {
        let p = try #require(plan(fixture))
        let c = try #require(p.resources.first { $0.address == "terraform_data.c" })
        let d = try #require(p.resources.first { $0.address == "terraform_data.d" })
        #expect(c.changed.isEmpty)
        #expect(d.changed.isEmpty)
    }

    @Test func aPlanWithNothingToDoReadsAsEmpty() throws {
        let p = try #require(plan("""
        {"terraform_version": "1.14.3", "resource_changes": [],
         "output_changes": {}}
        """))
        #expect(p.isEmpty)
        #expect(p.toAdd == 0 && p.toChange == 0 && p.toDestroy == 0)
    }

    @Test func garbageIsNotAPlan() {
        #expect(plan("not json at all") == nil)
    }

    @Test func dirLabelIsTheDirectoryName() throws {
        let p = try #require(plan(fixture))
        #expect(p.dirLabel == "prod")
    }
}
