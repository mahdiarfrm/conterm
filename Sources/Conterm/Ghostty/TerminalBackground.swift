extension Ghostty {
    /// The background on screen: the config's, unless the program set its
    /// own. libghostty keeps an OSC 11 color across config changes.
    struct TerminalBackground {
        struct RGB: Equatable, Sendable { var r, g, b: UInt8 }

        var base: RGB
        private var program: RGB?

        init(base: RGB) { self.base = base }

        /// OSC 111 is reported as a change to the default color, so that
        /// value ends the override.
        mutating func programSet(_ color: RGB) {
            program = color == base ? nil : color
        }

        var isLight: Bool {
            let c = program ?? base
            return !ThemeCatalog.isDark(r: c.r, g: c.g, b: c.b)
        }
    }
}
