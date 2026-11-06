import AppKit
import SwiftUI
import Testing
@testable import Conterm

extension UIScaleSuites {
    /// `TabPill.idealWidth` is what TabBar deals each pill and what the pill
    /// compares its width against before showing its number. It's written
    /// from the pill's layout constants, so these tests lay a real pill out
    /// and check the formula against SwiftUI's own measure, at each end of
    /// the UI scale range. Under `UIScaleSuites` because the scale is process-wide.
    @MainActor
    @Suite struct TabPillWidthTests {

        private static let titles = ["vi", "shell", "Terminal 12", "deploy — prod-us-east-1"]

        private func withScale(_ scale: Double, _ body: () -> Void) {
            let ud = InstanceState.defaults
            let old = ud.object(forKey: "conterm.uiScale")
            ud.set(scale, forKey: "conterm.uiScale")
            Theme.reloadUIScale()
            defer {
                if let old { ud.set(old, forKey: "conterm.uiScale") }
                else { ud.removeObject(forKey: "conterm.uiScale") }
                Theme.reloadUIScale()
            }
            body()
        }

        private func laidOutWidth(title: String, index: Int,
                                  selected: Bool, fitted: Bool) -> CGFloat {
            let prefs = Preferences()
            let state = AppState(prefs: prefs, ghostty: nil, notesStore: NotesStore(),
                                 showLaunchOverlay: false)
            let pill = TabPill(tab: Tab(indexLabel: title), index: index,
                               isSelected: selected,
                               onSelect: {}, onClose: {}, onBeginRename: {},
                               fitted: fitted)
                .environmentObject(prefs)
                .environmentObject(state)
                .environmentObject(TabGroupStore())
            return NSHostingView(rootView: pill).fittingSize.width
        }

        @Test(arguments: [0.85, 1.0, 1.25])
        func fittedWidthMatchesLayout(scale: Double) {
            withScale(scale) {
                for title in Self.titles {
                    let ideal = TabPill.idealWidth(title: title, index: 3, fitted: true)
                    let laid = laidOutWidth(title: title, index: 3, selected: false, fitted: true)
                    // The text measure is rounded up, so the formula may run
                    // up to a point over, never under.
                    #expect(ideal >= laid && ideal - laid <= 1,
                            "\(title) @\(scale): formula \(ideal), layout \(laid)")
                }
            }
        }

        @Test(arguments: [0.85, 1.0, 1.25])
        func fullWidthMatchesLayout(scale: Double) {
            withScale(scale) {
                for title in Self.titles {
                    for index in [3, 11] {   // with and without the ⌘N badge
                        let ideal = TabPill.idealWidth(title: title, index: index, fitted: false)
                        let laid = laidOutWidth(title: title, index: index,
                                                selected: true, fitted: false)
                        #expect(ideal >= laid && ideal - laid <= 1,
                                "\(title) #\(index) @\(scale): formula \(ideal), layout \(laid)")
                    }
                }
            }
        }
    }
}
