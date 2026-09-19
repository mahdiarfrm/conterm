import SwiftUI

// Orbit's panels exist in both interface styles. Each restyled member has a
// `drop…` form (Liquid Drop, beside the panel's logic) and a `classic…` form
// (`UI/Classic/Orbit/`); the members here keep the original names and pick by
// `Preferences.interfaceStyle`, so call sites and key paths are the same in
// either style.

extension OrbitOverlay {

    // MARK: OrbitAnsible

    var okGreen: Color { prefs.liquidDrop ? dropOkGreen : classicOkGreen }

    var failRed: Color { prefs.liquidDrop ? dropFailRed : classicFailRed }

    @ViewBuilder var ansibleSidebar: some View {
        if prefs.liquidDrop { dropAnsibleSidebar } else { classicAnsibleSidebar }
    }

    @ViewBuilder var ansibleHeader: some View {
        if prefs.liquidDrop { dropAnsibleHeader } else { classicAnsibleHeader }
    }

    @ViewBuilder func ansSection(_ t: String) -> some View {
        if prefs.liquidDrop { dropAnsSection(t) } else { classicAnsSection(t) }
    }

    @ViewBuilder var ansibleSetup: some View {
        if prefs.liquidDrop { dropAnsibleSetup } else { classicAnsibleSetup }
    }

    @ViewBuilder var ansibleLaunching: some View {
        if prefs.liquidDrop { dropAnsibleLaunching } else { classicAnsibleLaunching }
    }

    @ViewBuilder func ansibleProgressBody(_ run: AnsibleCenter.Run,
                                          done: Bool,
                                          live: Bool) -> some View {
        if prefs.liquidDrop {
            dropAnsibleProgressBody(run, done: done, live: live)
        } else {
            classicAnsibleProgressBody(run, done: done, live: live)
        }
    }

    // MARK: OrbitChrome

    @ViewBuilder var helpPanel: some View {
        if prefs.liquidDrop { dropHelpPanel } else { classicHelpPanel }
    }

    // MARK: OrbitComposer

    @ViewBuilder var historyPanel: some View {
        if prefs.liquidDrop { dropHistoryPanel } else { classicHistoryPanel }
    }

    @ViewBuilder func historyRow(_ a: OrbitScheduler.Action) -> some View {
        if prefs.liquidDrop { dropHistoryRow(a) } else { classicHistoryRow(a) }
    }

    // MARK: OrbitConnect

    @ViewBuilder var sessionsPanel: some View {
        if prefs.liquidDrop { dropSessionsPanel } else { classicSessionsPanel }
    }

    @ViewBuilder func sessionRow(_ row: SessionRow) -> some View {
        if prefs.liquidDrop { dropSessionRow(row) } else { classicSessionRow(row) }
    }

    // MARK: OrbitDanger

    @ViewBuilder var dangerGatePanel: some View {
        if prefs.liquidDrop { dropDangerGatePanel } else { classicDangerGatePanel }
    }

    // MARK: OrbitPanels

    @ViewBuilder var outputPanel: some View {
        if prefs.liquidDrop { dropOutputPanel } else { classicOutputPanel }
    }

    @ViewBuilder func logPanel(title: String,
                               subtitle: String,
                               icon: String,
                               busy: Bool,
                               text: String?) -> some View {
        if prefs.liquidDrop {
            dropLogPanel(title: title, subtitle: subtitle, icon: icon, busy: busy, text: text)
        } else {
            classicLogPanel(title: title, subtitle: subtitle, icon: icon, busy: busy, text: text)
        }
    }

    @ViewBuilder var hostOutputPanel: some View {
        if prefs.liquidDrop { dropHostOutputPanel } else { classicHostOutputPanel }
    }

    @ViewBuilder var shellDetailPanel: some View {
        if prefs.liquidDrop { dropShellDetailPanel } else { classicShellDetailPanel }
    }

    // MARK: OrbitRoutines

    @ViewBuilder var routinesPanel: some View {
        if prefs.liquidDrop { dropRoutinesPanel } else { classicRoutinesPanel }
    }

    @ViewBuilder var routineList: some View {
        if prefs.liquidDrop { dropRoutineList } else { classicRoutineList }
    }

    @ViewBuilder func routineRow(_ r: Routine) -> some View {
        if prefs.liquidDrop { dropRoutineRow(r) } else { classicRoutineRow(r) }
    }

    @ViewBuilder var routineEditor: some View {
        if prefs.liquidDrop { dropRoutineEditor } else { classicRoutineEditor }
    }

    @ViewBuilder func routineHistoryList(_ id: UUID) -> some View {
        if prefs.liquidDrop { dropRoutineHistoryList(id) } else { classicRoutineHistoryList(id) }
    }

    @ViewBuilder func routineSectionLabel(_ text: String) -> some View {
        if prefs.liquidDrop {
            dropRoutineSectionLabel(text)
        } else {
            classicRoutineSectionLabel(text)
        }
    }

    @ViewBuilder var routineLauncher: some View {
        if prefs.liquidDrop { dropRoutineLauncher } else { classicRoutineLauncher }
    }

    @ViewBuilder func stepEditor(_ step: Binding<FlowStep>,
                                 index: Int,
                                 remove: @escaping (UUID) -> Void) -> some View {
        if prefs.liquidDrop {
            dropStepEditor(step, index: index, remove: remove)
        } else {
            classicStepEditor(step, index: index, remove: remove)
        }
    }

    @ViewBuilder var hostPicker: some View {
        if prefs.liquidDrop { dropHostPicker } else { classicHostPicker }
    }

    // MARK: OrbitSince

    @ViewBuilder var sincePanel: some View {
        if prefs.liquidDrop { dropSincePanel } else { classicSincePanel }
    }

    @ViewBuilder func sinceRow(_ c: OrbitChange) -> some View {
        if prefs.liquidDrop { dropSinceRow(c) } else { classicSinceRow(c) }
    }

    func sinceTint(_ kind: OrbitChange.Kind) -> Color {
        prefs.liquidDrop ? dropSinceTint(kind) : classicSinceTint(kind)
    }

    // MARK: OrbitSteer

    @ViewBuilder var guestPanel: some View {
        if prefs.liquidDrop { dropGuestPanel } else { classicGuestPanel }
    }

    @ViewBuilder var steerPanel: some View {
        if prefs.liquidDrop { dropSteerPanel } else { classicSteerPanel }
    }

    @ViewBuilder func steerSectionLabel(_ text: String) -> some View {
        if prefs.liquidDrop { dropSteerSectionLabel(text) } else { classicSteerSectionLabel(text) }
    }

    @ViewBuilder func steerStatusPill(_ phase: AgentStatus.Phase) -> some View {
        if prefs.liquidDrop { dropSteerStatusPill(phase) } else { classicSteerStatusPill(phase) }
    }

    @ViewBuilder func steerFeedSection(for pane: Pane) -> some View {
        if prefs.liquidDrop {
            dropSteerFeedSection(for: pane)
        } else {
            classicSteerFeedSection(for: pane)
        }
    }
}

extension OrbitSearchPanel {

    // MARK: OrbitSearchPanel

    @ViewBuilder var body: some View {
        if prefs.liquidDrop { dropBody } else { classicBody }
    }

    @ViewBuilder var bar: some View {
        if prefs.liquidDrop { dropBar } else { classicBar }
    }

    @ViewBuilder var list: some View {
        if prefs.liquidDrop { dropList } else { classicList }
    }

    @ViewBuilder func row(_ hit: OrbitOverlay.SearchItem, active: Bool) -> some View {
        if prefs.liquidDrop {
            dropRow(hit, active: active)
        } else {
            classicRow(hit, active: active)
        }
    }
}
