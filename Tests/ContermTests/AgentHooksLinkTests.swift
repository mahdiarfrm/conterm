import Foundation
import Testing
@testable import Conterm

/// Settings files kept in a dotfiles checkout are symlinks; hook writes
/// land in the link's target so the link survives.
struct AgentHooksLinkTests {

    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-link-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func plainFileAndMissingPathAreTheirOwnTarget() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = "\(dir)/settings.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: file))
        #expect(AgentHooks.linkTarget(of: file) == file)
        #expect(AgentHooks.linkTarget(of: "\(dir)/absent.json") == "\(dir)/absent.json")
    }

    @Test func absoluteRelativeAndChainedLinksResolveToTheFile() throws {
        let fm = FileManager.default
        let dir = try scratch()
        defer { try? fm.removeItem(atPath: dir) }
        try fm.createDirectory(atPath: "\(dir)/dotfiles", withIntermediateDirectories: true)
        let real = "\(dir)/dotfiles/settings.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: real))

        try fm.createSymbolicLink(atPath: "\(dir)/abs.json", withDestinationPath: real)
        try fm.createSymbolicLink(atPath: "\(dir)/rel.json", withDestinationPath: "dotfiles/settings.json")
        try fm.createSymbolicLink(atPath: "\(dir)/chain.json", withDestinationPath: "rel.json")

        #expect(AgentHooks.linkTarget(of: "\(dir)/abs.json") == real)
        #expect(AgentHooks.linkTarget(of: "\(dir)/rel.json") == real)
        #expect(AgentHooks.linkTarget(of: "\(dir)/chain.json") == real)
    }

    @Test func atomicWriteThroughTheTargetKeepsTheLink() throws {
        let fm = FileManager.default
        let dir = try scratch()
        defer { try? fm.removeItem(atPath: dir) }
        let real = "\(dir)/real.json"
        let link = "\(dir)/settings.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: real))
        try fm.createSymbolicLink(atPath: link, withDestinationPath: real)

        try Data(#"{"hooks":{}}"#.utf8).write(
            to: URL(fileURLWithPath: AgentHooks.linkTarget(of: link)), options: .atomic)

        #expect((try? fm.destinationOfSymbolicLink(atPath: link)) == real)
        #expect(try String(contentsOfFile: real, encoding: .utf8) == #"{"hooks":{}}"#)
    }

    @Test func aLinkLoopStopsAtTheHopLimit() throws {
        let fm = FileManager.default
        let dir = try scratch()
        defer { try? fm.removeItem(atPath: dir) }
        try fm.createSymbolicLink(atPath: "\(dir)/a", withDestinationPath: "b")
        try fm.createSymbolicLink(atPath: "\(dir)/b", withDestinationPath: "a")
        let target = AgentHooks.linkTarget(of: "\(dir)/a")
        #expect(target == "\(dir)/a" || target == "\(dir)/b")
    }
}
