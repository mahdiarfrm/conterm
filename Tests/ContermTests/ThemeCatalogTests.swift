import Testing
import Foundation
@testable import Conterm

/// Theme-id validation used when restoring a per-window theme: an id
/// whose theme file is gone must not survive as a picker selection.
struct ThemeCatalogTests {

    @Test func missingThemeFileValidatesToNil() {
        #expect(ThemeCatalog.validatedThemeID("No Such Theme 000000") == nil)
        #expect(ThemeCatalog.colorLines(forThemeID: "No Such Theme 000000").isEmpty)
    }

    @Test func emptyAndNilValidateToNil() {
        #expect(ThemeCatalog.validatedThemeID(nil) == nil)
        #expect(ThemeCatalog.validatedThemeID("") == nil)
    }
}
