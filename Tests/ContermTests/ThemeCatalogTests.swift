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

    // MARK: - Follow-macOS resolution

    @Test func fixedThemeWinsWhenNotFollowing() {
        #expect(ThemeCatalog.effectiveThemeID(
            fixed: "Fixed", light: "L", dark: "D",
            followsSystem: false, isDark: true) == "Fixed")
        #expect(ThemeCatalog.effectiveThemeID(
            fixed: nil, light: "L", dark: "D",
            followsSystem: false, isDark: false) == nil)
    }

    @Test func followingPicksSlotForAppearance() {
        #expect(ThemeCatalog.effectiveThemeID(
            fixed: "Fixed", light: "L", dark: "D",
            followsSystem: true, isDark: true) == "D")
        #expect(ThemeCatalog.effectiveThemeID(
            fixed: "Fixed", light: "L", dark: "D",
            followsSystem: true, isDark: false) == "L")
    }

    @Test func followingFallsBackToOtherSlot() {
        #expect(ThemeCatalog.effectiveThemeID(
            fixed: nil, light: "L", dark: nil,
            followsSystem: true, isDark: true) == "L")
        #expect(ThemeCatalog.effectiveThemeID(
            fixed: nil, light: nil, dark: "D",
            followsSystem: true, isDark: false) == "D")
        #expect(ThemeCatalog.effectiveThemeID(
            fixed: "Fixed", light: nil, dark: nil,
            followsSystem: true, isDark: false) == nil)
    }
}
