import Foundation
import Testing
@testable import Conterm

/// WorktreeWatch's git parsers. The three formats it reads are all
/// delimiter games — NUL-separated status records, tab-separated numstat,
/// and a log stream fenced by control characters — and each has a shape
/// that a naive split gets wrong.
@MainActor
struct WorktreeWatchTests {

    // MARK: - status

    @Test func statusClassifiesEachKind() {
        let raw = " M keep.txt\0?? new.txt\0A  added.txt\0 D gone.txt\0"
        let out = WorktreeWatch.parseStatus(raw)
        #expect(out.map(\.path) == ["keep.txt", "new.txt", "added.txt", "gone.txt"])
        #expect(out.map(\.status) == [.modified, .untracked, .added, .deleted])
    }

    /// A rename carries its origin as a second NUL-separated field. The
    /// listing desynchronises if that field is not consumed.
    @Test func renameConsumesItsOriginField() {
        let raw = "RM new.txt\0old.txt\0 M after.txt\0"
        let out = WorktreeWatch.parseStatus(raw)
        #expect(out.count == 2)
        #expect(out[0].status == .renamed)
        #expect(out[0].path == "new.txt")
        #expect(out[0].renamedFrom == "old.txt")
        // The record after the rename must still be read as a record.
        #expect(out[1].path == "after.txt")
        #expect(out[1].status == .modified)
    }

    /// `RD` classifies as deleted, but it is still a rename record and
    /// still carries an origin field. Consuming that field must not depend
    /// on how the record classifies.
    @Test func renameThenDeleteStillConsumesOrigin() {
        let raw = "RD moved.txt\0origin.txt\0 M next.txt\0"
        let out = WorktreeWatch.parseStatus(raw)
        #expect(out.count == 2)
        #expect(out[0].status == .deleted)
        #expect(out[0].renamedFrom == "origin.txt")
        #expect(out[1].path == "next.txt")
    }

    @Test func stagedReflectsTheIndexColumn() {
        let out = WorktreeWatch.parseStatus("M  staged.txt\0 M unstaged.txt\0?? new.txt\0")
        #expect(out[0].staged)
        #expect(!out[1].staged)
        // Untracked is not "staged" in any sense worth showing.
        #expect(!out[2].staged)
    }

    // MARK: - numstat

    @Test func numstatReadsCounts() {
        let out = WorktreeWatch.parseNumstat("3\t1\tkeep.txt\n10\t0\tsrc/new.swift\n")
        #expect(out.count == 2)
        #expect(out[0].0 == "keep.txt")
        #expect(out[0].1 == 3)
        #expect(out[0].2 == 1)
        #expect(out[1].1 == 10)
    }

    /// Binary files report `-`, which must stay nil rather than becoming 0:
    /// "+0 −0" reads as "nothing changed", which is the opposite of true.
    @Test func binaryCountsStayNil() {
        let out = WorktreeWatch.parseNumstat("-\t-\ticon.png\n")
        #expect(out[0].1 == nil)
        #expect(out[0].2 == nil)
    }

    /// Renames arrive whole or with the unchanged prefix factored into
    /// braces. Both must land on the path `git status` reported, or the
    /// row never merges and the rename shows no counts.
    @Test func renameTargetResolvesBothForms() {
        #expect(WorktreeWatch.renameTarget("keep.txt => other/keep.txt")
                == "other/keep.txt")
        #expect(WorktreeWatch.renameTarget("src/deep/{a.txt => b.txt}")
                == "src/deep/b.txt")
        #expect(WorktreeWatch.renameTarget("src/{old => new}/file.swift")
                == "src/new/file.swift")
        #expect(WorktreeWatch.renameTarget("plain.txt") == "plain.txt")
    }

    @Test func numstatMergesOnTheRenameTarget() {
        let out = WorktreeWatch.parseNumstat("1\t0\tsrc/deep/{a.txt => b.txt}\n")
        #expect(out[0].0 == "src/deep/b.txt")
    }

    // MARK: - log

    /// The record separator leads each commit because numstat rows follow
    /// their header. A trailing separator files every commit's stats under
    /// the next one — and the last commit's under nothing.
    @Test func commitsAttachTheirOwnNumstat() {
        let raw = "\u{1e}abc1234\u{1f}1700000000\u{1f}first commit\n"
            + "2\t2\ta.txt\n1\t0\tb.txt\n\n"
            + "\u{1e}def5678\u{1f}1700000100\u{1f}second commit\n"
            + "10\t3\tc.txt\n"
        let out = WorktreeWatch.parseCommits(raw)
        #expect(out.count == 2)
        #expect(out[0].id == "abc1234")
        #expect(out[0].subject == "first commit")
        #expect(out[0].files == 2)
        #expect(out[0].added == 3)
        #expect(out[0].removed == 2)
        #expect(out[1].id == "def5678")
        #expect(out[1].files == 1)
        #expect(out[1].added == 10)
        #expect(out[1].removed == 3)
    }

    /// A subject can contain anything, tabs and the delimiters' printable
    /// neighbours included; only the control characters fence a record.
    @Test func commitSubjectSurvivesPunctuation() {
        let raw = "\u{1e}abc1234\u{1f}1700000000\u{1f}fix: a => b, and \"quotes\"\n"
        let out = WorktreeWatch.parseCommits(raw)
        #expect(out.count == 1)
        #expect(out[0].subject == "fix: a => b, and \"quotes\"")
    }

    @Test func emptyLogIsNoCommits() {
        #expect(WorktreeWatch.parseCommits("").isEmpty)
    }

    // MARK: - snapshot summary

    @Test func summaryOmitsAZeroFileCountWhenWorkWasCommitted() {
        var snap = WorktreeWatch.Snapshot(root: "/r", branch: "main", baseline: "abc")
        snap.commits = [.init(id: "abc1234", subject: "s", at: Date(),
                              files: 3, added: 40, removed: 5)]
        #expect(snap.summary == "1 commit · +40 −5")
        snap.files = [.init(path: "a.txt", added: 2, removed: 1, status: .modified)]
        #expect(snap.summary == "1 file · 1 commit · +42 −6")
    }
}
