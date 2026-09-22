import AppKit

/// A question or notice for the person at the Mac, asked the way the
/// interface style asks: on a drop in a window in Liquid Drop
/// (`DropAlertOverlay`), with the system alert in Classic. The system alert
/// also stands in when no window is on screen to hold it, or the one it
/// would use is already asking something.
struct DropAlert: Identifiable, Equatable {
    enum Tone: Equatable { case neutral, warn, bad }

    let id = UUID()
    /// What the question is about, set above the title.
    var topic: String
    var title: String
    var message: String
    /// Set large on its own line: a code to compare against another screen.
    var code: String? = nil
    /// Supporting text after the message (and the code).
    var detail: String? = nil
    var tone: Tone = .neutral
    /// Button titles in `NSAlert` order. The last answers Esc and a click
    /// outside; the first is filled.
    var buttons: [String] = ["OK"]
    /// Whether Return answers the first button. Off for a yes that must be
    /// a deliberate click, since the alert can arrive mid-typing.
    var returnAnswers = true

    var cancelIndex: Int { buttons.count - 1 }

    /// Ask, and hand back the index of the button chosen.
    @MainActor
    func ask(_ answer: @escaping (Int) -> Void = { _ in }) {
        let app = NSApp.delegate as? AppDelegate
        guard app?.prefs?.liquidDrop == true, let host = app?.alertHost() else {
            answer(runSystemAlert())
            return
        }
        host.window.makeKeyAndOrderFront(nil)
        host.state.ask(self, answer: answer)
    }

    @MainActor
    func ask() async -> Int {
        await withCheckedContinuation { done in
            ask { done.resume(returning: $0) }
        }
    }

    @MainActor
    private func runSystemAlert() -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = [message, code, detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        alert.alertStyle = tone == .neutral ? .informational : .warning
        for title in buttons { alert.addButton(withTitle: title) }
        if !returnAnswers { alert.buttons.first?.keyEquivalent = "" }
        let index = alert.runModal().rawValue
            - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return buttons.indices.contains(index) ? index : cancelIndex
    }
}
