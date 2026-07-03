import AppKit
import SwiftUI

/// A static snapshot of the desktop wallpaper, cropped to this window's
/// position on its screen, painted as the bottom layer of an OPAQUE
/// window. Liquid Glass mounted above it lenses this picture instead of
/// the live desktop, so the glass look survives while the window skips
/// WindowServer's per-present re-blend (the cost of a non-opaque window
/// under a streaming pane).
///
/// The crop tracks window moves/resizes and screen changes; the decoded
/// wallpaper is cached and re-read only when its file changes or the
/// app re-activates (wallpaper swaps happen outside the app).
struct WallpaperUnderlay: NSViewRepresentable {
    func makeNSView(context: Context) -> WallpaperUnderlayView {
        WallpaperUnderlayView()
    }
    func updateNSView(_ v: WallpaperUnderlayView, context: Context) {}
}

final class WallpaperUnderlayView: NSView {
    private var observers: [NSObjectProtocol] = []
    private var cachedURL: URL?
    private var cachedModified: Date?
    private var cachedImage: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        // Fallback bed for color-only wallpapers / load failures: a deep
        // neutral the glass can still read against.
        layer?.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.06,
                                         blue: 0.09, alpha: 1).cgColor
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        observers.forEach(nc.removeObserver)
        observers = []
        guard let window else { return }
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
        ]
        for n in names {
            observers.append(nc.addObserver(forName: n, object: window,
                                            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // Wallpaper changes happen while some other app is frontmost;
        // re-check whenever we come back.
        observers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func layout() {
        super.layout()
        refresh()
    }

    private func refresh() {
        guard let window, let screen = window.screen else { return }
        guard let image = wallpaperImage(for: screen) else {
            layer?.contents = nil
            return
        }
        layer?.contents = crop(image, windowFrame: window.frame,
                               screenFrame: screen.frame)
    }

    /// Decoded wallpaper for `screen`, cached by URL + mtime.
    private func wallpaperImage(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if url == cachedURL, modified == cachedModified, let cachedImage {
            return cachedImage
        }
        guard let img = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil,
                                   hints: nil) else { return nil }
        cachedURL = url
        cachedModified = modified
        cachedImage = cg
        return cg
    }

    /// The wallpaper is drawn aspect-fill over the whole screen; return
    /// the sub-image that sits behind `windowFrame`. Screen coordinates
    /// are bottom-left origin, image pixels top-left.
    private func crop(_ image: CGImage, windowFrame: CGRect,
                      screenFrame: CGRect) -> CGImage? {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return nil }
        let scale = max(screenFrame.width / iw, screenFrame.height / ih)
        let overflowX = (iw * scale - screenFrame.width) / 2
        let overflowY = (ih * scale - screenFrame.height) / 2
        let relX = windowFrame.minX - screenFrame.minX
        let relTopY = screenFrame.maxY - windowFrame.maxY
        let cropRect = CGRect(x: (relX + overflowX) / scale,
                              y: (relTopY + overflowY) / scale,
                              width: windowFrame.width / scale,
                              height: windowFrame.height / scale)
        return image.cropping(to: cropRect.intersection(
            CGRect(x: 0, y: 0, width: iw, height: ih)))
    }
}
