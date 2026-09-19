import AppKit
import SwiftUI

/// Custom About panel — replaces macOS's stock orderFrontStandardAboutPanel
/// with a glass-chrome window: big icon, version + libghostty build facts,
/// links, credits, laid out in the `Drop` kit's language. It is its own
/// window with nothing of ours behind it, so the surface is the system
/// material, not a `LiquidDrop` — a drop refracts panes, and there are none
/// here.
@MainActor
final class AboutPanel {
    static let shared = AboutPanel()
    private var window: NSWindow?

    private static let panelSize = NSSize(width: 600, height: 470)

    func show() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = Self.panelSize
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // The SwiftUI content fills the whole window so the glass card
        // IS the window. The hosting view uses autoresizing to track
        // window size; the controller does not drive sizing.
        let host = NSHostingView(rootView: AboutWindowContent {
            self.close()
        })
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        win.contentView = host

        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.title = "About Conterm"
        // Force dark — the panel's glass is dark, so default-colored
        // SwiftUI controls (anything using `.primary`) must resolve to
        // light text. Without this the title rendered black-on-dark.
        win.appearance = NSAppearance(named: .darkAqua)
        // Hide ALL standard window buttons — the panel provides its
        // own glass close control. A lone transparent-titlebar traffic
        // light floating over the card looked broken + was hard to hit.
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        // NOTE: corner rounding is done in SwiftUI (clipShape inside
        // AboutWindowContent), not via a CALayer mask on the
        // contentView. A layer mask clips the embedded
        // NSVisualEffectView with aliased (rough) edges; SwiftUI's
        // `.clipShape` is anti-aliased and crisp. We keep the window
        // transparent so only the rounded SwiftUI content shows.

        win.center()
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

/// The SwiftUI body inside the About window. Fills the entire window
/// (so the glass IS the window) and carries its own close control,
/// since all standard window buttons are hidden.
private struct AboutWindowContent: View {
    var onClose: () -> Void

    private static let corner: CGFloat = 30

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full-bleed glass — covers the whole window, no gaps.
            GlassBackground(material: .hudWindow)
            Color.black.opacity(0.22)

            AboutContent()
                .padding(.horizontal, Drop.inset)
                .padding(.top, 58)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Close control top-left, where the traffic light would be,
            // so it's where muscle memory expects.
            DropIconButton(symbol: "xmark", help: "Close (esc)", action: onClose)
                .padding(.top, 16)
                .padding(.leading, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.30), .clear],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        // Anti-aliased rounding of the whole panel (incl. the glass
        // material) — crisper than a CALayer corner mask.
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .preferredColorScheme(.dark)
        // Esc closes, matching standard panel behavior.
        .background(EscClose(action: onClose))
    }
}

/// Invisible helper that wires Esc → close (the window has no standard
/// close button to provide it).
private struct EscClose: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.onCancel = action
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeyView: NSView {
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?() }  // Esc
            else { super.keyDown(with: event) }
        }
    }
}
