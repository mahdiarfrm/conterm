import Testing
@testable import Conterm

/// The welcome's rules: which config answers fit what's on disk, how the
/// widget picks merge into the enabled list, and how a run moves.
@MainActor
struct WelcomeFlowTests {
    private typealias Found = WelcomeFlow.Found

    private func flow(_ found: Found = Found(ghosttyConfig: "/g/config")) -> WelcomeFlow {
        var picks = WelcomeFlow.Picks()
        picks.sounds = false
        return WelcomeFlow(picks: picks, found: found, isRerun: false)
    }

    // MARK: - Config answers

    @Test func ghosttyConfigOffersLinkCopyAndFresh() {
        let found = Found(ghosttyConfig: "/g/config")
        #expect(WelcomeFlow.configOptions(for: found) == [.link, .copy, .fresh])
        #expect(WelcomeFlow.defaultConfig(for: found) == .link)
    }

    @Test func ownContermConfigIsNeverReplaced() {
        let found = Found(ghosttyConfig: "/g/config", customConterm: true)
        #expect(WelcomeFlow.configOptions(for: found) == [.keep, .link])
        #expect(WelcomeFlow.defaultConfig(for: found) == .keep)
    }

    @Test func alreadyLinkedOnlyKeeps() {
        let found = Found(ghosttyConfig: "/g/config", customConterm: true, linked: true)
        #expect(WelcomeFlow.configOptions(for: found) == [.keep])
    }

    @Test func noGhosttyConfigLeavesFreshOnly() {
        #expect(WelcomeFlow.configOptions(for: Found()) == [.fresh])
        #expect(WelcomeFlow.defaultConfig(for: Found()) == .fresh)
    }

    @Test func aStepWithOneAnswerIsLeftOut() {
        #expect(!flow(Found()).steps.contains(.config))
        #expect(flow().steps == WelcomeFlow.Step.allCases)
    }

    // MARK: - Widgets

    @Test func widgetsOutsideTheOfferKeepTheirPlace() {
        let merged = WelcomeFlow.mergedWidgets(
            current: ["notes", "clock", "github"],
            picked: ["battery"])
        // clock is offered and unpicked, so it goes; notes and github stay
        // where they were; battery joins at the end.
        #expect(merged == ["notes", "github", "battery"])
    }

    @Test func newlyPickedWidgetsFollowCatalogOrder() {
        let merged = WelcomeFlow.mergedWidgets(current: [], picked: ["clock", "systemStats"])
        #expect(merged == ["systemStats", "clock"])
    }

    // MARK: - Moving through a run

    @Test func returnWaitsForTheHero() {
        let run = flow()
        run.primary()
        #expect(run.step == .hero)
        run.heroSettled = true
        run.primary()
        #expect(run.step == .config)
    }

    @Test func backStopsAtTheFirstStep() {
        let run = flow()
        run.heroSettled = true
        run.primary()
        #expect(!run.canGoBack)
        run.back()
        #expect(run.step == .config)
        run.primary()
        #expect(run.canGoBack)
        run.back()
        #expect(run.step == .config)
        #expect(run.direction == -1)
    }

    @Test func jumpsOnlyGoBack() {
        let run = flow()
        run.heroSettled = true
        run.primary(); run.primary(); run.primary()
        #expect(run.step == .layout)
        run.jump(to: .finish)
        #expect(run.step == .layout)
        run.jump(to: .config)
        #expect(run.step == .config)
        run.jump(to: .hero)
        #expect(run.step == .config)
    }

    @Test func lastStepFinishesOnce() {
        let run = flow()
        run.heroSettled = true
        for _ in run.steps.dropFirst() { run.primary() }
        #expect(run.isLast)
        run.primary()
        #expect(run.phase == .finishing)
        run.back()
        run.skip()
        #expect(run.phase == .finishing)
    }

    @Test func completeCallsTheOwnerOnce() {
        let run = flow()
        var calls = 0
        run.onDone = { calls += 1 }
        run.skip()
        run.complete()
        run.complete()
        #expect(calls == 1)
    }

    // MARK: - Ghostty summary

    @Test func summaryReadsTheLastValueOfEachKey() {
        let summary = SetupAssistant.ghosttySummary(parsing: """
        # theme = Commented
        theme = Nord
        font-family = "JetBrains Mono"
        font-size = 13
        theme = "Tokyo Night"
        background-opacity = 0.8
        """)
        #expect(summary.theme == "Tokyo Night")
        #expect(summary.fontFamily == "JetBrains Mono")
        #expect(summary.fontSize == "13")
    }
}
