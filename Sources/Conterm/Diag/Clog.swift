import Foundation

/// No-op in release builds. Callsites remain throughout the codebase
/// to preserve the diagnostic call shape; the function writes nothing
/// to disk and emits nothing to stderr. Restore the previous body
/// (see git history) if a future bug needs traceable logging.
@inlinable
func clog(_ s: String) {}
