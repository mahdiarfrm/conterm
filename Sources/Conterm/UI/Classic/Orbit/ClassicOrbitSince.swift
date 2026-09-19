import AppKit
import SwiftUI

/// Classic interface style. `OrbitOverlay`'s panels as they are drawn when
/// `Preferences.interfaceStyle` is `.classic`; the Liquid Drop counterparts
/// are the `drop…` members in `OrbitSince.swift`, and `OrbitPanelStyles.swift`
/// picks between them.
extension OrbitOverlay {

    /// Shown once per visit, under the header. It is news, not state: reading it
    /// is the point, so it goes away when you act on it or dismiss it, and never
    /// comes back for the same visit.
    @ViewBuilder
    var classicSincePanel: some View {
        if !since.isEmpty {
            let shown = Array(since.prefix(4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    OrbitText(text: "SINCE YOU LOOKED AWAY", size: 8, tracking: 1.2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    Spacer(minLength: 12)
                    Button { withAnimation(Theme.Spring.snappy) { since = [] } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                }
                .padding(.leading, 16).padding(.trailing, 8)
                .padding(.top, 12).padding(.bottom, 4)

                ForEach(shown) { c in
                    Button { openChange(c) } label: { sinceRow(c) }
                        .buttonStyle(.plain)
                }
                if since.count > shown.count {
                    Text("and \(since.count - shown.count) more")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .padding(.leading, 16).padding(.top, 3)
                }
            }
            .padding(.bottom, 12)
            .frame(width: 340, alignment: .leading)
            .modifier(PaletteBubble(cornerRadius: 18))
            // Inside the panel, not on the slot: an empty slot must take no
            // room at all, or the header carries a gap on every quiet entry.
            .padding(.top, 10)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    func classicSinceRow(_ c: OrbitChange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: c.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sinceTint(c.kind))
                .frame(width: 16)
            Text(c.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if let d = c.detail {
                Text(d)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    func classicSinceTint(_ kind: OrbitChange.Kind) -> Color {
        switch kind {
        case .needsYou:   return Theme.warning
        case .taskFailed: return Color(red: 0.95, green: 0.42, blue: 0.42)
        case .finished, .taskOk: return Color(red: 0.40, green: 0.86, blue: 0.56)
        case .hostNew, .hostGone: return Theme.textSecondary
        }
    }
}
