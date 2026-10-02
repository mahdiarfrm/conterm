// A clean desktop for screenshots: one borderless window over the whole
// main screen, painted with soft colour fields, sitting above every other
// app's windows. The demo app is activated on top of it, so its glass and
// shadow fall on this and nothing else. SIGUSR1 brings it back to the
// front (another app may have come forward between shots); SIGTERM quits.
import AppKit

final class Fields: NSView {
    override func draw(_ dirty: NSRect) {
        NSColor(srgbRed: 0.027, green: 0.039, blue: 0.086, alpha: 1).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // x, y as fractions of the screen (y up), radius as a fraction of
        // its width, then the colour.
        let fields: [(CGFloat, CGFloat, CGFloat, (CGFloat, CGFloat, CGFloat))] = [
            (0.22, 0.70, 0.52, (0.36, 0.17, 1.00)),
            (0.80, 0.20, 0.55, (1.00, 0.30, 0.18)),
            (0.78, 0.84, 0.38, (0.00, 0.65, 1.00)),
            (0.42, 0.02, 0.38, (1.00, 0.18, 0.58)),
        ]
        for (x, y, r, (red, green, blue)) in fields {
            let colors = [CGColor(colorSpace: space, components: [red, green, blue, 0.95])!,
                          CGColor(colorSpace: space, components: [red, green, blue, 0.45])!,
                          CGColor(colorSpace: space, components: [red, green, blue, 0])!]
            let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                      locations: [0, 0.45, 1])!
            let c = CGPoint(x: bounds.width * x, y: bounds.height * y)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: bounds.width * r, options: [])
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                      backing: .buffered, defer: false)
window.contentView = Fields(frame: NSRect(origin: .zero, size: screen.frame.size))
window.isReleasedWhenClosed = false
window.hasShadow = false
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.orderFrontRegardless()

signal(SIGUSR1, SIG_IGN)
let raise = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
raise.setEventHandler { window.orderFrontRegardless() }
raise.resume()
signal(SIGTERM, SIG_IGN)
let quit = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
quit.setEventHandler { exit(0) }
quit.resume()

app.run()
