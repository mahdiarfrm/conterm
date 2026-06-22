import AppKit
import Foundation

/// Opt-in diagnostic log. Disabled by default; the Settings → Config →
/// "Diagnostic logging" toggle flips the `conterm.diagnosticLogging`
/// default. While enabled, `clog` appends timestamped lines to
/// `~/Library/Logs/Conterm/conterm.log` on a private serial queue;
/// while disabled it returns after a single UserDefaults read, so call
/// sites can stay in place at negligible cost.
enum DiagnosticLog {
    /// UserDefaults key mirrored by `Preferences.diagnosticLogging`.
    static let defaultsKey = "conterm.diagnosticLogging"

    static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Conterm", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("conterm.log") }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    // `handle` and `formatter` are touched only inside `queue`, whose
    // serialization provides the synchronization the compiler can't see.
    private static let queue = DispatchQueue(label: "com.conterm.diaglog")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        guard isEnabled else { return }
        let now = Date()
        queue.async {
            if handle == nil { handle = openHandle() }
            guard let data = (formatter.string(from: now) + " " + message + "\n")
                .data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
        }
    }

    private static func openHandle() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        try? h.seekToEnd()
        return h
    }

    /// Open the log folder in Finder, selecting the file when it exists.
    /// Creates the folder first so the affordance always lands somewhere.
    static func reveal() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }
}

func clog(_ s: String) { DiagnosticLog.write(s) }
