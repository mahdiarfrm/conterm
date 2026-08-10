import Foundation
import Testing
@testable import Conterm

/// The shortcut table. A key that does something and is written down nowhere is
/// a key nobody presses, so the help panel and the bindings are pinned to each
/// other here.
struct OrbitKeyTests {

    @Test func everyShortcutIsDocumented() {
        let missing = Set(OrbitKey.allCases).subtracting(OrbitKey.documented)
        #expect(missing.isEmpty, "undocumented shortcuts: \(missing.map(\.rawValue).sorted())")
    }

    @Test func everyDocumentedKeyIsRealMissing() {
        // The other direction: the panel cannot promise a key that does nothing.
        #expect(OrbitKey.documented.isSubset(of: Set(OrbitKey.allCases)))
    }

    @Test func bareLettersMapToTheirVerb() {
        #expect(OrbitKey.plain("c") == .connect)
        #expect(OrbitKey.plain("r") == .run)
        #expect(OrbitKey.plain("p") == .playbook)
        #expect(OrbitKey.plain("o") == .overview)
        #expect(OrbitKey.plain("e") == .inspect)
        #expect(OrbitKey.plain("f") == .fit)
        #expect(OrbitKey.plain("m") == .minimap)
        #expect(OrbitKey.plain("1") == .viewLive)
        #expect(OrbitKey.plain("2") == .viewFleet)
        #expect(OrbitKey.plain("n") == .newShell)
        #expect(OrbitKey.plain("a") == .newAgent)
    }

    @Test func bothZoomSpellingsWork() {
        // `=` is where `+` lives without the shift, and `_` where `−` does; a
        // shortcut that needs a modifier to type is a shortcut that gets typed
        // wrong.
        #expect(OrbitKey.plain("+") == .zoomIn)
        #expect(OrbitKey.plain("=") == .zoomIn)
        #expect(OrbitKey.plain("-") == .zoomOut)
        #expect(OrbitKey.plain("_") == .zoomOut)
    }

    @Test func unboundCharactersClaimNothing() {
        // Anything not bound has to fall through, or a key the map does not use
        // is silently swallowed instead of reaching whatever would.
        for c in ["b", "d", "g", "j", "q", "v", "z", "9", "/"] {
            #expect(OrbitKey.plain(c) == nil, "\(c) should not be bound")
        }
    }

    @Test func everyBareLetterBindingIsDocumented() {
        let bound = "fm12sancrpoelyt?0+-=_".map { OrbitKey.plain(String($0)) }
        for key in bound.compactMap({ $0 }) {
            #expect(OrbitKey.documented.contains(key),
                    "\(key.rawValue) is bound but not in the help panel")
        }
    }
}
