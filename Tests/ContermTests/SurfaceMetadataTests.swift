import Testing
import Foundation
@testable import Conterm

/// The pure OSC-title / pwd parsing helpers that feed pane title bars
/// and SSH detection.
@MainActor
@Suite struct SurfaceMetadataTests {

    private var home: String { NSHomeDirectory() }

    // MARK: - Command duration formatting

    @Test func commandDurationFormatting() {
        #expect(formatCommandDuration(420_000_000) == "420ms")
        #expect(formatCommandDuration(1_400_000_000) == "1.4s")
        #expect(formatCommandDuration(12_000_000_000) == "12s")
        #expect(formatCommandDuration(123_000_000_000) == "2m 03s")
    }

    // MARK: - OSC 7 pwd decoding

    @Test func decodePwdFileURL() {
        let (path, host) = decodePwd("file://mac.local/Users/x/Documents")
        #expect(path == "/Users/x/Documents")
        #expect(host == "mac.local")
    }

    @Test func decodePwdKittyShellCwdURL() {
        let (path, host) = decodePwd("kitty-shell-cwd://box/tmp")
        #expect(path == "/tmp")
        #expect(host == "box")
    }

    @Test func decodePwdUserAtHostPathExpandsTilde() {
        let (path, host) = decodePwd("user@box:~/proj")
        #expect(path == home + "/proj")
        #expect(host == nil)
    }

    @Test func decodePwdBarePathPercentDecodes() {
        let (path, _) = decodePwd("/plain%20dir")
        #expect(path == "/plain dir")
    }

    @Test func decodePwdForTitleReturnsLastComponent() {
        #expect(decodePwdForTitle("file://h/Users/x/Documents") == "Documents")
    }

    // MARK: - SSH target extraction

    @Test func sshTargetPlainHost() {
        #expect(extractSshTarget(from: "ssh example.com") == "example.com")
    }

    @Test func sshTargetStripsUser() {
        #expect(extractSshTarget(from: "ssh user@example.com") == "example.com")
    }

    @Test func sshTargetSkipsFlagsWithArguments() {
        #expect(extractSshTarget(from: "ssh -i ~/.ssh/key -p 2222 host") == "host")
    }

    @Test func sshTargetMosh() {
        #expect(extractSshTarget(from: "mosh box") == "box")
    }

    @Test func sshTargetRejectsNonSshCommands() {
        #expect(extractSshTarget(from: "vim notes") == nil)
        #expect(extractSshTarget(from: "ssh") == nil)
        #expect(extractSshTarget(from: "") == nil)
    }

    // MARK: - Title → cwd extraction

    @Test func cwdFromTitleTilde() {
        #expect(extractCwdFromTitle("~") == home)
        #expect(extractCwdFromTitle("~/foo") == home + "/foo")
    }

    @Test func cwdFromTitleAbsolutePath() {
        #expect(extractCwdFromTitle("/abs/path") == "/abs/path")
    }

    @Test func cwdFromTitleUserAtHost() {
        #expect(extractCwdFromTitle("user@box:~/x") == home + "/x")
    }

    @Test func cwdFromTitleRejectsTruncatedAndEmpty() {
        #expect(extractCwdFromTitle("…/a/b/c") == nil)
        #expect(extractCwdFromTitle("") == nil)
        #expect(extractCwdFromTitle("make build") == nil)
    }

    // MARK: - Path plausibility

    @Test func plausibleAbsolutePath() {
        #expect(isPlausibleAbsolutePath("/ok/path"))
        #expect(!isPlausibleAbsolutePath("relative/path"))
        #expect(!isPlausibleAbsolutePath("/bad\u{07}path"))
        #expect(!isPlausibleAbsolutePath("/" + String(repeating: "a", count: 5000)))
    }

    // MARK: - Local prompt detection

    @Test func localPromptTitleMatchesLocalhost() {
        #expect(isLocalPromptTitle("user@localhost:/tmp"))
        #expect(!isLocalPromptTitle("user@definitely-not-this-machine.example:/tmp"))
        #expect(!isLocalPromptTitle("no colon or at sign"))
    }

    // MARK: - Friendly directory label

    @Test func friendlyDirLabels() {
        #expect(friendlyDirLabel(for: nil) == "—")
        #expect(friendlyDirLabel(for: home) == "~")
        #expect(friendlyDirLabel(for: "/") == "/")
        #expect(friendlyDirLabel(for: home + "/a/b") == "~/a/b")
        #expect(friendlyDirLabel(for: home + "/a/b/c/d") == "~/…/b/c/d")
        #expect(friendlyDirLabel(for: "/usr/local/bin") == "/usr/local/bin")
    }
}
