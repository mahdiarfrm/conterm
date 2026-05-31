import AppKit
import GhosttyKit

/// Translates AppKit input event metadata into libghostty's C enums. Heavy
/// lifting (keycode → key enum) is left to libghostty itself — we only
/// need to forward the modifier bitmask.
enum InputMapping {
    static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    /// Inverse of `mods(from:)` for the four device modifiers
    /// (shift / control / option / command). The translation pipeline
    /// in SurfaceView asks libghostty for the modifier set to apply
    /// during character composition (`ghostty_surface_key_translation_mods`)
    /// and rebuilds an NSEvent with the result, so AppKit composes the
    /// character with Option stripped under `macos-option-as-alt`.
    /// Caps Lock / Num Lock are deliberately excluded — those device-
    /// state bits don't participate in AppKit's character composition
    /// and round-tripping them would only desync the rebuilt event
    /// from the modifier state IME engines expect to see.
    static func eventFlags(fromGhostty mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let raw = mods.rawValue
        if raw & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if raw & GHOSTTY_MODS_CTRL.rawValue  != 0 { flags.insert(.control) }
        if raw & GHOSTTY_MODS_ALT.rawValue   != 0 { flags.insert(.option) }
        if raw & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Pack a scroll event into libghostty's `ghostty_input_scroll_mods_t`
    /// bitfield. Layout (per Ghostty's Zig source):
    ///   bit 0      → precision (1 = trackpad / Magic Mouse continuous)
    ///   bits 1..3  → momentum phase (0=none, 1=began, 2=stationary,
    ///                3=changed, 4=ended, 5=cancelled, 6=mayBegin)
    static func scrollMods(precision: Bool, momentum: NSEvent.Phase) -> Int32 {
        var v: Int32 = 0
        if precision { v |= 0b1 }
        v |= (Int32(momentumCode(momentum)) & 0b111) << 1
        return v
    }

    private static func momentumCode(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began)       { return 1 }
        if phase.contains(.stationary)  { return 2 }
        if phase.contains(.changed)     { return 3 }
        if phase.contains(.ended)       { return 4 }
        if phase.contains(.cancelled)   { return 5 }
        if phase.contains(.mayBegin)    { return 6 }
        return 0
    }
}
