import Testing
@testable import Conterm

/// Follow-system mode rewrites the managed block with one slot's colors;
/// `slotToApply` decides which slot, or whether to leave the block alone.
struct ThemeFollowTests {
    @Test func picksTheSlotForTheAppearance() {
        #expect(ThemeCatalog.slotToApply(fromConfig: false, light: "L", dark: "D",
                                         lightAppearance: true, current: "D") == "L")
        #expect(ThemeCatalog.slotToApply(fromConfig: false, light: "L", dark: "D",
                                         lightAppearance: false, current: "L") == "D")
    }

    @Test func leavesTheBlockAlone() {
        // "Use theme from terminal config" owns the colors.
        #expect(ThemeCatalog.slotToApply(fromConfig: true, light: "L", dark: "D",
                                         lightAppearance: true, current: nil) == nil)
        // Empty slot: keep whatever is applied rather than blanking it.
        #expect(ThemeCatalog.slotToApply(fromConfig: false, light: nil, dark: "D",
                                         lightAppearance: true, current: "D") == nil)
        // Already applied: no config rewrite and reload.
        #expect(ThemeCatalog.slotToApply(fromConfig: false, light: "L", dark: "D",
                                         lightAppearance: true, current: "L") == nil)
    }
}
