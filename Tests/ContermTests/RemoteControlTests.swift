import Foundation
import Testing
@testable import Conterm

/// The inbox's two guards: how old a command may be before it is ignored,
/// and reading a date whichever way the phone encoded it.
@MainActor
struct RemoteControlTests {

    private func command(sentAt: Date?) -> RemoteControl.Command {
        RemoteControl.Command(id: "c1", action: .refresh, sentAt: sentAt)
    }

    @Test func aFreshCommandRuns() {
        #expect(RemoteControl.fresh(command(sentAt: Date())))
    }

    /// The case the startup drain cannot reach: the Mac stays running with
    /// the lid shut, and the command lands hours before it wakes.
    @Test func anOldCommandIsDropped() {
        let old = Date().addingTimeInterval(-RemoteControl.commandTTL - 5)
        #expect(!RemoteControl.fresh(command(sentAt: old)))
    }

    /// Clock skew between two machines cuts both ways, so a command stamped
    /// in the future is no more trustworthy than an ancient one.
    @Test func aFutureCommandIsDropped() {
        let ahead = Date().addingTimeInterval(RemoteControl.commandTTL + 5)
        #expect(!RemoteControl.fresh(command(sentAt: ahead)))
    }

    /// A phone older than the field sends no stamp. Refusing those would
    /// break a paired phone the moment the Mac updated first.
    @Test func anUnstampedCommandIsAccepted() {
        #expect(RemoteControl.fresh(command(sentAt: nil)))
    }

    /// Each side picks its own encoder, and a mismatch fails the whole
    /// decode — dropping every command, not just the timestamp.
    @Test func bothDateEncodingsDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = RemoteControl.lenientDates
        let when = Date(timeIntervalSinceReferenceDate: 780_000_000)

        let iso = ISO8601DateFormatter().string(from: when)
        let fromText = try decoder.decode(
            RemoteControl.Command.self,
            from: Data(#"{"id":"a","action":"refresh","sentAt":"\#(iso)"}"#.utf8))
        #expect(abs(try #require(fromText.sentAt).timeIntervalSince(when)) < 1)

        // `.deferredToDate` is the JSONEncoder default: seconds since the
        // reference date, as a bare number.
        let fromNumber = try decoder.decode(
            RemoteControl.Command.self,
            from: Data(#"{"id":"b","action":"refresh","sentAt":780000000}"#.utf8))
        #expect(abs(try #require(fromNumber.sentAt).timeIntervalSince(when)) < 1)
    }

    @Test func aCommandWithNoDateStillDecodes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = RemoteControl.lenientDates
        let c = try decoder.decode(
            RemoteControl.Command.self,
            from: Data(#"{"id":"c","action":"focusPane","paneID":"p"}"#.utf8))
        #expect(c.sentAt == nil)
        #expect(c.action == .focusPane)
    }
}
