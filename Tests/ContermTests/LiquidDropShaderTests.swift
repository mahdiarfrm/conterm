import Metal
import Testing
@testable import Conterm

/// The drop's shader is compiled from source at runtime, so nothing at build
/// time checks it. A source that stops compiling leaves every briefing card
/// on its flat fallback without any error surfacing.
struct LiquidDropShaderTests {

    @Test func sourceCompilesWithEveryEntryPoint() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try device.makeLibrary(source: LiquidDropShader.source, options: nil)
        for name in ["paneVS", "paneFS", "dropVS", "dropFS"] {
            #expect(library.makeFunction(name: name) != nil, "missing \(name)")
        }
    }
}
