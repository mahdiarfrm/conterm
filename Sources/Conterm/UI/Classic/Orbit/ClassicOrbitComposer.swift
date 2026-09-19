import AppKit
import Combine
import SwiftUI

/// Classic interface style. `OrbitOverlay`'s panels as they are drawn when
/// `Preferences.interfaceStyle` is `.classic`; the Liquid Drop counterparts
/// are the `drop…` members in `OrbitComposer.swift`, and `OrbitPanelStyles.swift`
/// picks between them.
extension OrbitOverlay {

    /// Every finished action, newest first — the persisted flight recorder,
    /// beyond the deck's recent time window. Click a row to open its output.
    @ViewBuilder
    var classicHistoryPanel: some View {
        if showHistory {
            let items = scheduler.actions.filter { $0.isTerminal }
                .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text("History").font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if !items.isEmpty {
                            Button { scheduler.clearFinished() } label: {
                                Text("Clear").font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary)
                            }.buttonStyle(.plain)
                        }
                        Button { withAnimation(Theme.Spring.snappy) { showHistory = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 22, height: 22).background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    Divider().opacity(0.3)
                    if items.isEmpty {
                        Text("No finished tasks yet.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(items) { a in
                                    Button { withAnimation(Theme.Spring.snappy) { modal = .output(a.id) } } label: {
                                        historyRow(a)
                                    }.buttonStyle(.plain)
                                    Divider().opacity(0.16).padding(.leading, 42)
                                }
                            }
                        }
                    }
                }
                .frame(width: 330)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
                Spacer()
            }
            .padding(.leading, 16).padding(.top, 58).padding(.bottom, deckClearance + 4)
        }
    }

    func classicHistoryRow(_ a: OrbitScheduler.Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.kind == .ansible ? "play.fill"
                            : a.kind == .copy ? "doc.on.doc" : "chevron.right.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(actionColor(a.status))
                .frame(width: 22, height: 22).background(Circle().fill(actionColor(a.status).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.label).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let f = a.finishedAt {
                        Text(relTime(f)).font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(a.targets.joined(separator: ", ")).font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let note = a.resultNote {
                    Text(note).font(.system(size: 10, design: .monospaced)).foregroundStyle(actionColor(a.status))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
    }
}
