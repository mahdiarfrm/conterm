import Foundation

/// Opt-in diagnostic logger. Off by default so a shipped app leaves
/// no debug files behind. Set `CONTERM_LOG=1` in the launching
/// environment to write each call to stderr and `/tmp/conterm.log`.
private let loggingEnabled: Bool =
    ProcessInfo.processInfo.environment["CONTERM_LOG"] == "1"

private let logHandle: FileHandle? = {
    guard loggingEnabled else { return nil }
    let path = "/tmp/conterm.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func clog(_ s: String) {
    guard loggingEnabled else { return }
    let line = s.hasSuffix("\n") ? s : s + "\n"
    if let data = line.data(using: .utf8) {
        logHandle?.write(data)
        FileHandle.standardError.write(data)
    }
}
