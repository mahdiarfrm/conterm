import AppKit
import CoreImage
import SwiftUI

/// AppKit-backed single-line text field with a custom insertion point.
/// macOS `TextField` ignores `.tint` for the caret, and a recolored caret
/// can only be a solid color — so to get a **grey caret with a faint
/// internal prism** (a static light-dispersion shimmer, not a cycling hue)
/// the caret has to be *drawn*. That needs `drawInsertionPoint`, which lives
/// on `NSTextView`, so the input is a single-line `NSTextView` rather than an
/// `NSTextField` (whose caret rides the shared field editor we don't own).
///
/// Self-focuses on appear; routes Return / ↑ / ↓ back out. In the command
/// palette those are already consumed by the global key monitor, so the
/// callbacks default to no-ops.
struct NeonCaretField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 14
    var onSubmit: () -> Void = {}
    var onUp: () -> Void = {}
    var onDown: () -> Void = {}

    func makeNSView(context: Context) -> PrismCaretTextView {
        let tv = PrismCaretTextView()
        // Force TextKit 1 so the layout manager (used to position the caret
        // layer) is the classic one.
        _ = tv.layoutManager
        tv.wantsLayer = true

        tv.delegate = context.coordinator
        tv.isFieldEditor = true          // single line: Return/Tab end editing
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.isRichText = false
        tv.allowsUndo = true
        tv.focusRingType = .none
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textColor = NSColor(Theme.textPrimary)
        // Grey fallback if the custom draw path is ever bypassed — never the
        // system blue. The prism override paints over this when it runs.
        tv.insertionPointColor = NSColor(white: 0.6, alpha: 1)

        let base = NSFont.systemFont(ofSize: fontSize)
        tv.font = base.fontDescriptor.withDesign(.rounded)
            .map { NSFont(descriptor: $0, size: fontSize) ?? base } ?? base

        // Hug the frame: text starts at the leading edge (the search bar's
        // HStack supplies the surrounding padding), one clipped line.
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainerInset = .zero
        if let container = tv.textContainer {
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 1
            container.lineBreakMode = .byClipping
            container.widthTracksTextView = true
        }

        tv.placeholder = placeholder
        tv.onSubmit = onSubmit
        tv.onUp = onUp
        tv.onDown = onDown
        tv.string = text

        // Self-focus, deferred + re-asserted: the open path may call
        // makeFirstResponder(nil) just before this mounts.
        for delay in [0.0, 0.08, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tv] in
                guard let tv, let w = tv.window,
                      w.firstResponder !== tv else { return }
                w.makeFirstResponder(tv)
            }
        }
        return tv
    }

    func updateNSView(_ tv: PrismCaretTextView, context: Context) {
        if tv.string != text { tv.string = text }
        tv.placeholder = placeholder
        tv.onSubmit = onSubmit
        tv.onUp = onUp
        tv.onDown = onDown
        tv.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: NeonCaretField
        init(_ parent: NeonCaretField) { self.parent = parent }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
            // Repaint so the placeholder appears/clears the moment the
            // field empties or gains its first character.
            tv.needsDisplay = true
        }
    }
}

/// Single-line `NSTextView` whose insertion point is a thick, grey,
/// prism-tinted bar with a big soft bloom. The caret is its own `CALayer`
/// (the system caret is suppressed) — drawing it via `drawInsertionPoint`
/// clipped both the thickness and the glow to the system's ~1pt caret rect.
/// As a layer it can be as thick and as bloomed as we like, and the bloom is
/// a real layer shadow (Gaussian) rather than a clipped CG shadow.
final class PrismCaretTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onUp: () -> Void = {}
    var onDown: () -> Void = {}
    var placeholder: String = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }

    private let caretHost = CALayer()      // geometry-flipped → top-left coords
    private let caretLayer = CALayer()
    private let prismLayer = CAGradientLayer()
    private var isFocused = false
    private static let caretWidth: CGFloat = 4

    /// Spectrum sampled top→bottom across the caret, kept low-alpha so the
    /// grey body dominates — a grey bar with a whisper of prism, not a
    /// rainbow.
    private static let prismColors: [CGColor] = [
        NSColor(srgbRed: 1.00, green: 0.32, blue: 0.38, alpha: 0.3),
        NSColor(srgbRed: 1.00, green: 0.72, blue: 0.28, alpha: 0.3),
        NSColor(srgbRed: 0.55, green: 0.86, blue: 0.46, alpha: 0.3),
        NSColor(srgbRed: 0.34, green: 0.70, blue: 1.00, alpha: 0.3),
        NSColor(srgbRed: 0.66, green: 0.46, blue: 1.00, alpha: 0.3),
    ].map { $0.cgColor }

    // Single-line behavior — Return/arrows leave the field.
    override func insertNewline(_ sender: Any?) { onSubmit() }
    override func insertLineBreak(_ sender: Any?) { onSubmit() }
    override func insertTab(_ sender: Any?) {}
    override func moveUp(_ sender: Any?) { onUp() }
    override func moveDown(_ sender: Any?) { onDown() }

    // The CALayer caret replaces the system one entirely.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    // MARK: - Caret layer

    private func setupCaretLayer() {
        guard caretHost.superlayer == nil, let host = layer else { return }
        // Flip the host's geometry so the caret is placed in plain top-left
        // view coordinates (y grows downward, same as the drawn text) —
        // the backing layer's own vertical convention is otherwise ambiguous.
        caretHost.isGeometryFlipped = true
        caretHost.zPosition = 1                   // ride above the drawn text
        caretLayer.cornerRadius = Self.caretWidth / 2
        caretLayer.masksToBounds = false        // don't clip the bloom
        caretLayer.shadowOffset = .zero
        // A wider radius washes the glow over the neighbouring glyph.
        caretLayer.shadowRadius = 8
        caretLayer.shadowOpacity = 1.0
        caretLayer.isHidden = true
        prismLayer.colors = Self.prismColors
        prismLayer.startPoint = CGPoint(x: 0.5, y: 0)
        prismLayer.endPoint = CGPoint(x: 0.5, y: 1)
        prismLayer.cornerRadius = Self.caretWidth / 2
        prismLayer.masksToBounds = true
        caretLayer.addSublayer(prismLayer)
        // Blur the bar itself so it reads as a soft glowing cursor, not a
        // hard rectangle (the bloom shadow stays separate).
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(1.6, forKey: "inputRadius")
            caretLayer.filters = [blur]
        }
        caretHost.addSublayer(caretLayer)
        host.addSublayer(caretHost)
        applyCaretColors()
    }

    private func applyCaretColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        caretLayer.backgroundColor =
            (isDark ? NSColor(white: 0.74, alpha: 1) : NSColor(white: 0.34, alpha: 1)).cgColor
        caretLayer.shadowColor =
            NSColor(srgbRed: 0.64, green: 0.82, blue: 1.0, alpha: 1).cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { setupCaretLayer(); updateCaret() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCaretColors()
    }

    /// Keep the single line vertically centred, then track the caret.
    override func layout() {
        super.layout()
        let lineH = layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 14)) ?? 0
        let inset = max(0, (bounds.height - lineH) / 2)
        if abs(textContainerInset.height - inset) > 0.5 {
            textContainerInset = NSSize(width: 0, height: inset)
        }
        updateCaret()
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true   // refresh placeholder
        updateCaret(); restartBlink()
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting flag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        updateCaret(); restartBlink()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { isFocused = true; setupCaretLayer(); updateCaret(); restartBlink() }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { isFocused = false; stopBlink(); caretLayer.isHidden = true }
        return ok
    }

    /// The caret's x in view coords, cached so `draw(_:)` can abut the
    /// placeholder to it — the caret layer and the drawn text don't share an
    /// origin, so the placeholder is anchored to this measured value.
    private var caretX: CGFloat = 0

    private func updateCaret() {
        setupCaretLayer()
        guard let lm = layoutManager else { return }
        let f = font ?? NSFont.systemFont(ofSize: 14)
        let sel = selectedRange()
        let show = isFocused && sel.length == 0
        caretLayer.isHidden = !show
        guard show else { return }
        caretX = caretXPosition(at: sel.location) + 1      // a touch right
        let inset = (bounds.height - lm.defaultLineHeight(for: f)) / 2
        let baseline = inset + f.ascender                  // from the top
        let textCenter = baseline - f.capHeight / 2        // glyph visual centre
        let height = f.capHeight + 7                        // a tall, present bar
        // The geometry-flipped host renders y-UP, so centre the caret on the
        // glyphs from the bottom; positive `caretRaise` moves it UP.
        let caretRaise: CGFloat = 3
        let centerY = bounds.height - textCenter + caretRaise
        let y = centerY - height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caretHost.frame = bounds
        caretLayer.frame = CGRect(x: caretX, y: y, width: Self.caretWidth, height: height)
        prismLayer.frame = caretLayer.bounds
        CATransaction.commit()
        needsDisplay = true   // keep the placeholder glued to the caret
    }

    /// Caret x in view coords. Uses the text input system's own insertion
    /// rect (robust against container insets/origins), falling back to a
    /// glyph measurement before the view joins a window.
    private func caretXPosition(at location: Int) -> CGFloat {
        let screen = firstRect(forCharacterRange: NSRange(location: location, length: 0),
                               actualRange: nil)
        if let win = window, screen != .zero {
            return max(0, convert(win.convertFromScreen(screen), from: nil).minX)
        }
        guard location > 0, let lm = layoutManager, let tc = textContainer else {
            return textContainerOrigin.x
        }
        lm.ensureLayout(for: tc)
        let gr = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: location),
                               actualCharacterRange: nil)
        return lm.boundingRect(forGlyphRange: gr, in: tc).maxX + textContainerOrigin.x
    }

    private func restartBlink() {
        guard isFocused else { return }
        caretLayer.removeAnimation(forKey: "blink")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.calculationMode = .discrete
        caretLayer.add(blink, forKey: "blink")
    }
    private func stopBlink() { caretLayer.removeAnimation(forKey: "blink") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(Theme.textSecondary),
        ]
        // Anchor the placeholder to the actual caret x so the caret sits
        // right against the text — "▌Search" — touching, never floating.
        placeholder.draw(at: NSPoint(x: caretX + Self.caretWidth,
                                     y: textContainerInset.height),
                         withAttributes: attrs)
    }
}
