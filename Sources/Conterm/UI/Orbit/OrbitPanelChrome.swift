import SwiftUI

/// The one surface every panel floating over the Orbit map sits on, and the
/// furniture those panels share.
///
/// The surface is a calm `DropSurface`: working chrome, so no opening
/// flourish and little dispersion. Over the map there is usually no pane to
/// refract, so the drop settles as tinted glass with its rim optics and its
/// display link stops; a panel costs nothing while it is open and still.
enum OrbitPanel {
    /// Content inset from the panel edge; clears the bevel.
    static let inset: CGFloat = 22
    static let bevel: CGFloat = 14
    static let cornerRadius: CGFloat = 26
    /// The dim the centred modals lay over the map.
    static let modalDim: Double = 0.28
}

extension View {
    /// Seat this view on Orbit's panel surface. `dim` is the scene dim the
    /// caller lays under the panel (0 for side panels, which lay none), so
    /// anything seen through the glass matches what surrounds it.
    func orbitPanel(cornerRadius: CGFloat = OrbitPanel.cornerRadius,
                    bevel: CGFloat = OrbitPanel.bevel,
                    dim: Double = 0,
                    fadesEdges: Bool = false) -> some View {
        DropSurface(cornerRadius: cornerRadius, bevel: bevel, calm: true,
                    dispersion: 0.35, sceneDim: Float(dim), formDelay: 0.10,
                    fadesEdges: fadesEdges) { self }
    }
}

/// Title strip of an Orbit panel: a glyph, the subject, a line of context,
/// then the panel's own controls and the close button.
struct OrbitPanelHeader<Controls: View>: View {
    var glyph: String? = nil
    var glyphTint: Color = Theme.textSecondary
    let title: String
    var context: String? = nil
    var monoTitle = false
    let onClose: () -> Void
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: 9) {
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphTint)
            }
            Text(title)
                .font(monoTitle ? Drop.mono(12.5, .medium) : Drop.display(13.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let context {
                Text(context)
                    .font(Drop.display(11, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            controls
            DropIconButton(symbol: "xmark", help: "Close (esc)", action: onClose)
        }
        .padding(.horizontal, OrbitPanel.inset)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

extension OrbitPanelHeader where Controls == EmptyView {
    init(glyph: String? = nil, glyphTint: Color = Theme.textSecondary,
         title: String, context: String? = nil, monoTitle: Bool = false,
         onClose: @escaping () -> Void) {
        self.init(glyph: glyph, glyphTint: glyphTint, title: title, context: context,
                  monoTitle: monoTitle, onClose: onClose, controls: { EmptyView() })
    }
}

/// Selectable monospaced output in a recessed well — a task's output, a
/// container's log, a command's result.
struct OrbitOutputWell: View {
    let text: String
    var dimmed = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(Drop.mono(11.5))
                .foregroundStyle(dimmed ? Theme.textSecondary : Theme.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .scrollIndicators(.never)
        .background(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
            .fill(Theme.selectionFill.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 0.5))
        .padding(.horizontal, OrbitPanel.inset)
        .padding(.bottom, OrbitPanel.inset)
    }
}

/// A text input on a panel: a plain field in a recessed capsule.
struct OrbitFieldBed: ViewModifier {
    var cornerRadius: CGFloat? = nil
    /// Tighter padding for fields packed several to a row.
    var compact = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? 100, style: .continuous)
        content
            .padding(.horizontal, compact ? 9 : 13)
            .padding(.vertical, compact ? 6 : 8)
            .background(shape.fill(Theme.selectionFill))
            .overlay(shape.strokeBorder(Theme.stroke, lineWidth: 0.5))
    }
}

extension View {
    func orbitFieldBed(cornerRadius: CGFloat? = nil, compact: Bool = false) -> some View {
        modifier(OrbitFieldBed(cornerRadius: cornerRadius, compact: compact))
    }
}
