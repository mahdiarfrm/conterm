import SwiftUI

/// Presents a small working panel (find bar, notifications, rename) on a
/// `DropSurface`. Same phases as `BriefingPresenter` — mount closed, open,
/// reveal, and on dismissal hide, collapse, unmount — but paced for chrome
/// that is opened many times a minute, and with an optional scrim: at
/// `dim == 0` nothing is laid over the scene, so the terminal under the
/// panel stays fully interactive.
///
/// The panel is mounted from the first frame, so a text field inside it can
/// take focus before the drop has formed and no keystroke is lost. While
/// the collapse plays the panel is disabled, which also makes a field give
/// up first responder instead of holding it for a view that is leaving.
struct DropPanelPresenter<Item: Equatable, Panel: View>: View {
    let item: Item?
    var alignment: Alignment = .top
    var insets = EdgeInsets()
    /// Scene dim under the panel; the panel's `DropSurface.sceneDim` should
    /// match it.
    var dim: Double = 0
    let onDismiss: () -> Void
    @ViewBuilder let panel: (Item) -> Panel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Item?
    @State private var open = false
    @State private var revealed = false
    /// Bumped on every open/close so a deferred step can't act on a later one.
    @State private var generation = 0

    var body: some View {
        Group {
            if let shown {
                ZStack(alignment: alignment) {
                    if dim > 0 {
                        Color.black.opacity(dim)
                            .ignoresSafeArea()
                            .onTapGesture(perform: onDismiss)
                            .opacity(open ? 1 : 0)
                            .animation(.easeOut(duration: 0.18), value: open)
                    }
                    panel(shown)
                        .environment(\.liquidDropOpen, open)
                        .environment(\.liquidRevealed, revealed)
                        .disabled(item == nil)
                        .padding(insets)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            }
        }
        .onAppear { if let item { present(item) } }
        .onChange(of: item) { _, new in
            if let new { present(new) } else { dismiss() }
        }
    }

    private func present(_ new: Item) {
        generation += 1
        let gen = generation
        let wasMounted = shown != nil
        shown = new
        guard !(wasMounted && open) else { return }
        revealed = false
        // Mount closed for one frame so the drop has a state to grow from.
        DispatchQueue.main.async {
            if gen == generation { open = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.04 : 0.10)) {
            if gen == generation { revealed = true }
        }
    }

    private func dismiss() {
        generation += 1
        let gen = generation
        revealed = false
        open = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            if gen == generation { shown = nil }
        }
    }
}
