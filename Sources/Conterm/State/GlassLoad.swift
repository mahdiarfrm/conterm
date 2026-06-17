import Foundation
import SwiftUI

/// Tracks whether any visible pane is *actively streaming* (repainting
/// fast). The live Liquid Glass backdrop composites continuously on the
/// GPU; while a pane streams that's the one window where it shows up as
/// real heat, so Battery saving drops the backdrop to a solid fill for the
/// duration of the burst (plus a short tail) and brings the glass back when
/// the terminal goes calm.
///
/// Panes report their own streaming state by id; the shared `streaming`
/// flag is the OR across all of them. The backdrop observes this as an
/// `@EnvironmentObject` and re-renders when it flips.
@MainActor
final class GlassLoad: ObservableObject {
    static let shared = GlassLoad()

    /// True while at least one visible pane is streaming.
    @Published private(set) var streaming = false

    private var hot = Set<ObjectIdentifier>()

    func set(_ on: Bool, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if on { hot.insert(id) } else { hot.remove(id) }
        let now = !hot.isEmpty
        if now != streaming { streaming = now }
    }
}
