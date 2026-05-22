import Foundation

/// Writes diagnostic lines to /tmp/conterm.log AND stderr. Used by both
/// the libghostty bridge and the SwiftUI layer because Swift.print and
/// NSLog get eaten by NSApplication's runloop and reaching the file
/// directly is the only reliable channel.
private let logHandle: FileHandle? = {
    let path = "/tmp/conterm.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func clog(_ s: String) {
    let line = s.hasSuffix("\n") ? s : s + "\n"
    if let data = line.data(using: .utf8) {
        logHandle?.write(data)
        FileHandle.standardError.write(data)
    }
}
