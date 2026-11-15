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

        // MARK: - Shortening titles on a crowded bar

        private static let crowd: [(title: String, index: Int, fitted: Bool)] = [
            ("vi", 1, true), ("Terminal 2", 2, true),
            ("deploy — prod-us-east-1", 3, true), ("Terminal 4", 4, false),
        ]

        private func dealt(_ cap: CGFloat) -> [CGFloat] {
            Self.crowd.map {
                TabPill.idealWidth(title: $0.title, index: $0.index, fitted: $0.fitted,
                                   titleCap: max(cap, TabPill.shortestTitleWidth($0.title,
                                                                                fitted: $0.fitted)))
            }
        }

        @Test func crowdedBarCutsLongTitlesToOneLength() throws {
            let ideals = Self.crowd.map {
                TabPill.idealWidth(title: $0.title, index: $0.index, fitted: $0.fitted)
            }
            let available = ideals.reduce(0, +) - 60
            let cap = try #require(TabBar.titleCap(for: Self.crowd, available: available))
            let widths = dealt(cap)
            #expect(widths.reduce(0, +) <= available)
            // Within a few points of filling the bar: the rest is rounding.
            #expect(available - widths.reduce(0, +) < 4)
            #expect(widths[0] == ideals[0], "a short title stays whole")
            #expect(widths[2] < ideals[2], "the longest title is cut")
        }

        @Test func crowdedBarStopsAtSixCharacters() throws {
            let floors = Self.crowd.map {
                TabPill.minimumWidth(title: $0.title, index: $0.index, fitted: $0.fitted)
            }
            let cap = try #require(TabBar.titleCap(for: Self.crowd,
                                                   available: floors.reduce(0, +)))
            #expect(dealt(cap) == floors)
            #expect(TabBar.titleCap(for: Self.crowd, available: floors.reduce(0, +) - 1) == nil)
        }

        @Test func shortTitlesHaveNoShorterForm() {
            #expect(TabPill.shortestTitleWidth("KFXGEN", fitted: true)
                    == TabPill.titleWidth("KFXGEN", fitted: true))
            #expect(TabPill.shortestTitleWidth("Terminal 10", fitted: true)
                    == TabPill.titleWidth("Termin…", fitted: true) + 1)
        }

        // MARK: - Number-only pills fill the bar

        @Test func numberPillsSplitTheBarEvenly() {
            let share = TabBar.miniShare(available: 1000, count: 11)
            #expect(share == 90)
            #expect(share * 11 <= 1000, "shares never overrun the bar")
            #expect(TabBar.miniShare(available: 0, count: 11) == 0)
            #expect(TabBar.miniShare(available: 500, count: 0) == 0)
        }

        /// Proposed no width, a number-only pill comes out at its minimum:
        /// everything but the title slot, which gives way entirely.
        @Test(arguments: [0.85, 1.0, 1.25])
        func numberPillMinimumMatchesLayout(scale: Double) {
            withScale(scale) {
                for index in [3, 11] {
                    let prefs = Preferences()
                    let state = AppState(prefs: prefs, ghostty: nil, notesStore: NotesStore(),
                                         showLaunchOverlay: false)
                    let pill = TabPill(tab: Tab(indexLabel: "Terminal 12"), index: index,
                                       isSelected: false,
                                       onSelect: {}, onClose: {}, onBeginRename: {},
                                       mini: true)
                        .environmentObject(prefs)
                        .environmentObject(state)
                        .environmentObject(TabGroupStore())
                    let laid = NSHostingController(rootView: pill)
                        .sizeThatFits(in: CGSize(width: 0, height: 200)).width
                    let formula = TabPill.miniWidth(index: index)
                    #expect(formula >= laid && formula - laid <= 2,
                            "#\(index) @\(scale): formula \(formula), layout \(laid)")
                }
            }
        }

        @Test func stretchedNumberPillShowsTitleOnlyWhenThreeCharactersFit() {
            let base = TabPill.miniWidth(index: 4)
            #expect(base > 0)
            #expect(TabPill.miniTitleWidth("Terminal 4")
                    == TabPill.textWidth("Ter…", size: Theme.ui(11), weight: .regular) + 1)
            #expect(TabPill.miniTitleWidth("vi")
                    == TabPill.textWidth("vi", size: Theme.ui(11), weight: .regular) + 1)
        }
    }
}
