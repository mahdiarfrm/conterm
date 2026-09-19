import AppKit
import Combine
import SwiftUI

/// Classic interface style. `OrbitOverlay`'s panels as they are drawn when
/// `Preferences.interfaceStyle` is `.classic`; the Liquid Drop counterparts
/// are the `drop…` members in `OrbitConnect.swift`, and `OrbitPanelStyles.swift`
/// picks between them.
extension OrbitOverlay {

    /// Every session Conterm has open, whether or not it's on this board. The
    /// map only shows what a view includes, so panes accumulate out of sight —
    /// this is where you see the whole set, find where each one is used, and
    /// close the ones you're done with.
    @ViewBuilder
    var classicSessionsPanel: some View {
        if showSessions {
            let rows = allSessions()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("Sessions").font(OrbitFont.face(17)).tracking(-0.4)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(rows.count)").font(OrbitFont.face(11))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        Spacer()
                        Button { withAnimation(Theme.Spring.snappy) { showSessions = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 24, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

                    if rows.isEmpty {
                        Text("No sessions open")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(rows, id: \.pane.id) { row in sessionRow(row) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                // Its own frame, so scrolling the list scrolls the list rather
                // than panning the map underneath it.
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { sessionsFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in sessionsFrame = f }
                })
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
                .padding(.trailing, 18).padding(.top, 58)
                .padding(.bottom, deckClearance)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    func classicSessionRow(_ row: SessionRow) -> some View {
        let live = row.pane.agent.phase != .idle
        return HStack(spacing: 10) {
            Circle()
                .fill(live ? (row.pane.agent.phase == .attention ? Theme.warning : Theme.accent)
                           : Theme.textSecondary.opacity(0.35))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.tag).font(OrbitFont.face(8.5)).tracking(0.5)
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Text(friendlyDirLabel(for: row.pane.cwd))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(row.where_)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { openInWindow(row.pane) } label: {
                Image(systemName: "macwindow").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open its terminal in a window")
            // The same close the session's own bar performs: this list spans
            // every window, and closing through *this* window's state can only
            // reach its own tabs.
            Button { closeSession(row.pane) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Close this session")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            if let n = model.nodes.first(where: { $0.id == "pane:\(row.pane.id.uuidString)" }) {
                withAnimation(Theme.Spring.snappy) { barNode = n }
            }
        }
    }
}
