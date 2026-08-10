import Foundation
import Testing
@testable import Conterm

/// The ranking behind ⌘K. Ordering is the whole feature: a query that returns
/// the right node in position four is a query you have to read, and reading a
/// list is what the field exists to replace.
@MainActor
struct OrbitSearchTests {
    private func rank(_ text: String, _ query: String) -> Int? {
        OrbitOverlay.searchRank(text, query)
    }

    @Test func exactBeatsPrefixBeatsContains() {
        let exact = rank("web1", "web1")!
        let prefix = rank("web1-staging", "web1")!
        let contains = rank("old-web1x", "web1")!
        #expect(exact < prefix)
        #expect(prefix < contains)
    }

    @Test func aWordBoundaryOutranksAMidWordHit() {
        // Hosts are named with separators, so the segment you remember is the
        // one you type: `02` means sib-02, not xx02yy.
        #expect(rank("sib-02", "02")! < rank("xx02yy", "02")!)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(rank("Web1", "web1") == rank("web1", "web1"))
        #expect(rank("web1", "WEB") != nil)
    }

    @Test func subsequenceMatchesButRanksLast() {
        let scattered = rank("staging-bastion", "sgb")
        #expect(scattered != nil)
        #expect(scattered! > rank("sgb-host", "sgb")!)
    }

    @Test func unrelatedTextDoesNotMatch() {
        #expect(rank("web1", "zzz") == nil)
        // Out of order is not a subsequence — otherwise every query matches
        // almost everything and the ranking stops meaning anything.
        #expect(rank("abc", "cba") == nil)
    }

    @Test func anEmptyQueryMatchesEverythingEqually() {
        #expect(rank("web1", "") == 0)
        #expect(rank("anything at all", "") == 0)
    }

    @Test func subsequenceNeedsEveryCharacter() {
        #expect(OrbitOverlay.isSubsequence("abc", of: "axbxc"))
        #expect(!OrbitOverlay.isSubsequence("abcd", of: "axbxc"))
        #expect(OrbitOverlay.isSubsequence("", of: "anything"))
    }
}
