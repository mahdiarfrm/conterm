import Foundation
import Testing
@testable import Conterm

/// The per-node keys drawn on the cards. One key each, held by ⌥ — so what
/// matters is that they are distinct, stable, and that a crowded map hands out
/// the ones it has rather than inventing sequences nobody would type.
@MainActor
struct OrbitHintTests {

    @Test func aSmallFleetGetsOneLetterEach() {
        #expect(OrbitOverlay.hintLabels(count: 5) == ["a", "s", "d", "f", "g"])
    }

    @Test func everyLabelIsASingleKey() {
        // The whole design is ⌥ plus one key. A two-key sequence is a mode with
        // extra steps, which is what this replaced.
        #expect(OrbitOverlay.hintLabels(count: 9).allSatisfy { $0.count == 1 })
    }

    @Test func aCrowdedMapHandsOutWhatItHas() {
        // Nine keys, nine labels. Past that the map is better answered by ⌘K or
        // Tab, and the tenth card simply wears nothing.
        let n = OrbitOverlay.hintAlphabet.count
        #expect(OrbitOverlay.hintLabels(count: 40).count == n)
        #expect(OrbitOverlay.hintLabels(count: n + 1).count == n)
    }

    @Test func labelsAreDistinct() {
        for n in [1, 5, 9] {
            let labels = OrbitOverlay.hintLabels(count: n)
            #expect(labels.count == n)
            #expect(Set(labels).count == n, "duplicate label at count \(n)")
        }
    }

    @Test func labelsAreStableForTheSameCount() {
        // The point is muscle memory: the same fleet gives the same keys every
        // time you look at it.
        #expect(OrbitOverlay.hintLabels(count: 7) == OrbitOverlay.hintLabels(count: 7))
        // And a shorter list is a prefix of a longer one, so adding a node
        // never renames the cards above it.
        #expect(OrbitOverlay.hintLabels(count: 4)
                == Array(OrbitOverlay.hintLabels(count: 8).prefix(4)))
    }

    @Test func theKeysAreHomeRow() {
        // Your hands should not move to use them.
        #expect(OrbitOverlay.hintAlphabet.allSatisfy { "asdfghjkl;".contains($0) })
    }

    @Test func noneOfThemCollideWithTheOtherOptionShortcut() {
        // ⌥ already means "focus pane N" for the digits, and that is the one
        // conflict that matters — the bare-letter verbs are a different
        // modifier state and cannot clash.
        for key in OrbitOverlay.hintAlphabet {
            #expect(Int(String(key)) == nil, "\(key) would collide with ⌥\(key)")
        }
    }

    @Test func nothingAskedForIsNothingGiven() {
        #expect(OrbitOverlay.hintLabels(count: 0).isEmpty)
    }
}
