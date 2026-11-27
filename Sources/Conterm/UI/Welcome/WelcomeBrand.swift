import AppKit
import SwiftUI

/// The Conterm wordmark at a given height, filled with `style`: the warm
/// cream on a dark page, ink on a light one.
struct WelcomeWordmark: View {
    let style: AnyShapeStyle
    let height: CGFloat

    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "text-logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        return NSImage(size: .zero)
    }()

    /// Width over height of the artwork.
    static var aspect: CGFloat {
        let size = image.size
        return size.height > 0 ? size.width / size.height : 4
    }

    var width: CGFloat { height * Self.aspect }

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(style)
            .frame(width: width, height: height)
    }
}

/// The line under the wordmark: mono, widely tracked, quiet.
struct WelcomeTagline: View {
    let light: Bool

    var body: some View {
        Text("a modern way to connect")
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .tracking(3)
            .foregroundStyle(WelcomeColor.tagline(light))
            .fixedSize()
    }
}
