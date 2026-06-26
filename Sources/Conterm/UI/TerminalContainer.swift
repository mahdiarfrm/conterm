import AppKit
import SwiftUI

/// SwiftUI seam for a tab's pane tree. The tree itself is laid out by AppKit
/// (`PaneTreeView`); this view just hosts it.
struct TerminalContainer: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var notifications: NotificationStore
    var isActive: Bool

    var body: some View {
        // The pane tree is owned by AppKit (PaneTreeView): a surviving pane is
        // only reframed across splits/closes, never reparented, so libghostty's
        // IOSurface stays attached. No .id-rebuild / host-reuse workaround.
        if let app = state.ghostty {
            PaneTreeHost(tree: tab.paneTree, app: app, state: state,
                         notifications: notifications, prefs: prefs)
        } else {
            Text("libghostty failed to initialize")
                .foregroundStyle(Theme.warning)
        }
    }
}
