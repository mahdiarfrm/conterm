import Foundation
import Testing
@testable import Conterm

/// The git widget's repo label comes from `--git-common-dir`, which is the
/// main repo's `.git` even inside a linked worktree.
struct GitStatusModelTests {
    @Test func repoNameFromCommonDir() {
        #expect(GitStatusModel.repoName(commonDir: "/Users/x/code/conterm/.git") == "conterm")
        #expect(GitStatusModel.repoName(commonDir: "/srv/git/conterm.git") == "conterm")
        #expect(GitStatusModel.repoName(commonDir: "/x/super/.git/modules/sub") == "sub")
        // `proj/.bare` + `proj/.git` holding `gitdir: ./.bare`.
        #expect(GitStatusModel.repoName(commonDir: "/x/proj/.bare") == "proj")
        // A normal checkout in a folder whose name ends in `.git`.
        #expect(GitStatusModel.repoName(commonDir: "/x/site.git/.git") == "site.git")
    }
}
