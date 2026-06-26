import AppKit

/// Human-friendly run time for a command badge / notification.
/// < 1s → "420ms"; < 10s → "1.4s"; < 60s → "12s"; else "2m 03s".
func formatCommandDuration(_ ns: UInt64) -> String {
    let seconds = Double(ns) / 1_000_000_000
    if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
    if seconds < 10 { return String(format: "%.1fs", seconds) }
    if seconds < 60 { return "\(Int(seconds.rounded()))s" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%dm %02ds", m, s)
}

/// Returns a friendly short label for `cwd`. Replaces home dir with
/// `~`, preserves the `~/` (or `/`) anchor so the user can always tell
/// which root the path is under, and shows up to the last three path
/// segments — deeper paths are signalled with an ellipsis between the
/// anchor and the tail (e.g. `~/…/sibche/v5-infra/services`). The
/// 3-segment depth is a compromise between "just the basename"
/// (too little context) and the full path (overflows the pill on
/// narrow panes).
@MainActor
func friendlyDirLabel(for cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "—" }
    let home = NSHomeDirectory()
    if cwd == home { return "~" }
    if cwd == "/" { return "/" }

    var rest: String
    var anchor: String
    if cwd.hasPrefix(home + "/") {
        rest = String(cwd.dropFirst(home.count + 1))
        anchor = "~/"
    } else if cwd.hasPrefix("/") {
        rest = String(cwd.dropFirst())
        anchor = "/"
    } else {
        rest = cwd
        anchor = ""
    }

    let parts = rest.split(separator: "/").map(String.init)
    let maxTail = 3
    if parts.count <= maxTail {
        return anchor + parts.joined(separator: "/")
    }
    return anchor + "…/" + parts.suffix(maxTail).joined(separator: "/")
}

/// OSC 7 reports pwd as `file://hostname/percent-encoded/path`. Without
/// decoding, the title looks like `~%2FDocuments` or has replacement
/// glyphs (?). URL-parse → strip scheme → percent-decode → last
/// component. Falls through gracefully for plain-path inputs too.
@MainActor
func decodePwdForTitle(_ raw: String) -> String {
    let path = decodePwdToPath(raw)
    let base = (path as NSString).lastPathComponent
    return base.isEmpty ? path : base
}

/// Returns the full decoded absolute path from an OSC 7 pwd report.
/// Handles `file://`, `kitty-shell-cwd://` (what Ghostty's bundled zsh
/// integration emits), bare paths, and `user@host:path` strings (the
/// non-standard format many zsh prompt-title hooks emit through OSC 7).
@MainActor
private func decodePwdToPath(_ raw: String) -> String {
    decodePwd(raw).path
}

/// Returns both the decoded path AND the URL host (if any) from
/// an OSC 7 pwd report. The host lets us detect SSH state: when
/// the OSC 7 URL's host doesn't match our local hostname, we're
/// inside an ssh session.
@MainActor
func decodePwd(_ raw: String) -> (path: String, host: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed),
       url.scheme == "file" || url.scheme == "kitty-shell-cwd" {
        return (url.path, url.host)
    }
    if let colonIdx = trimmed.firstIndex(of: ":"),
       trimmed[trimmed.startIndex..<colonIdx].contains("@") {
        let path = String(trimmed[trimmed.index(after: colonIdx)...])
        return (expandTilde(path), nil)
    }
    return (expandTilde(trimmed.removingPercentEncoding ?? trimmed), nil)
}

/// Local hostname(s) for SSH-detection purposes. Both bare ("x0rz")
/// and dotted ("x0rz.local") forms are returned so an OSC title in
/// either form matches.
///
/// CRITICAL: this must use ONLY non-blocking, local sources. The old
/// implementation called `Host.current().names`, which performs a
/// synchronous reverse-DNS resolution. It was triggered lazily by the
/// first shell-prompt OSC title — right during the launch animation —
/// so on a network with slow/unreachable DNS the main thread blocked
/// for seconds: the intro froze, the OS flagged the app
/// non-responsive, then it "skipped" once DNS finally timed out.
/// `gethostname(2)` + `ProcessInfo.hostName` are pure local syscalls
/// (no network) and give us everything we actually need.
@MainActor
let localHostnames: Set<String> = {
    var names = Set<String>(["localhost"])

    func add(_ raw: String) {
        let lc = raw.lowercased()
        guard !lc.isEmpty else { return }
        names.insert(lc)
        // Also index the bare form before the first dot
        // (e.g. "x0rz" from "x0rz.local").
        if let dot = lc.firstIndex(of: ".") {
            names.insert(String(lc[lc.startIndex..<dot]))
        }
    }

    // Kernel hostname via gethostname(2) — a pure local syscall, no
    // network/DNS, microseconds. This is exactly the value a shell's
    // prompt `%m` / `hostname` reports, which is what appears in the
    // `user@host:path` OSC titles we match against. We deliberately do
    // NOT use `Host.current()` or `ProcessInfo.hostName` here — both
    // can perform blocking DNS resolution.
    var buf = [CChar](repeating: 0, count: 256)
    if gethostname(&buf, buf.count) == 0 {
        add(String(cString: buf))
    }

    return names
}()

/// `~` / `~/foo` → `<HOME>` / `<HOME>/foo`. Bare paths pass through.
@MainActor
private func expandTilde(_ p: String) -> String {
    if p == "~" { return NSHomeDirectory() }
    if p.hasPrefix("~/") { return NSHomeDirectory() + String(p.dropFirst(1)) }
    return p
}

/// If the title looks like a command line that starts with `ssh`
/// (or `mosh`, also a remote-shell tool), extract the target host
/// argument. Aliases from `~/.ssh/config` come through as the user
/// typed them — we don't try to resolve them, since the alias is
/// usually the more meaningful label anyway.
///
/// Returns nil for anything that isn't an ssh/mosh command line.
@MainActor
func extractSshTarget(from title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = parts.first,
          first == "ssh" || first == "mosh" || first == "ssh-copy-id" else {
        return nil
    }
    // Walk past flags. Some ssh flags take an argument (e.g. `-i key`,
    // `-p port`, `-o opt`); we consume both flag and value.
    let flagsWithArg: Set<Character> = ["i", "p", "o", "F", "L", "R", "D", "l", "J", "W", "b", "B", "c", "E", "I", "m", "O", "Q", "S", "w"]
    var i = 1
    while i < parts.count {
        let p = parts[i]
        if p.hasPrefix("-") {
            // `-X` may take an arg; `-Xvalue` is bundled (no arg
            // needed); `--foo=bar` always has the arg inline.
            if p.count == 2, let ch = p.last, flagsWithArg.contains(ch), i + 1 < parts.count {
                i += 2
                continue
            }
            i += 1
            continue
        }
        // First non-flag word is the host (possibly `user@host`).
        if let atIdx = p.firstIndex(of: "@") {
            return String(p[p.index(after: atIdx)...])
        }
        return p
    }
    return nil
}

/// Is this title in the local `user@<localhostname>:path` form? We
/// use this to know when an ssh session has ended (and clear the
/// pane's `remoteHost`).
@MainActor
func isLocalPromptTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let atIdx = trimmed.firstIndex(of: "@"),
          let colonIdx = trimmed[atIdx...].firstIndex(of: ":") else { return false }
    let host = trimmed[trimmed.index(after: atIdx)..<colonIdx].lowercased()
    return localHostnames.contains(host)
}

/// Extract a usable absolute path from a title string. Accepts:
/// - `user@host:path` (omz_termsupport format)
/// - `~` and `~/foo` (ghostty integration format for ≤3-deep paths)
/// - bare `/foo` (already absolute)
/// Returns nil for the truncated `…/last/3/parts` form (we can't
/// recover the full path from that), or for command strings emitted
/// during preexec.
@MainActor
func extractCwdFromTitle(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    // omz format: `user@host:path`
    if Ghostty.SurfaceController.looksLikeUserAtHostPath(trimmed) {
        return decodePwdToPath(trimmed)
    }
    // Already an absolute path or tilde-shortened path.
    if trimmed == "~" || trimmed.hasPrefix("~/") {
        return expandTilde(trimmed)
    }
    if trimmed.hasPrefix("/") {
        return trimmed
    }
    return nil
}

/// String-based filter — does the decoded value plausibly look like an
/// absolute filesystem path? We do NOT use `FileManager.fileExists`
/// because that triggers macOS TCC ("would like to access Documents")
/// permission dialogs whenever the shell cd's into a protected dir.
/// The garbage emits we want to reject contain control characters and
/// don't start with "/", so a simple syntactic check is sufficient.
@MainActor
func isPlausibleAbsolutePath(_ p: String) -> Bool {
    guard p.hasPrefix("/") else { return false }
    guard p.count >= 1, p.count < 4096 else { return false }
    // No ASCII control characters (covers \x00-\x1F + \x7F). These are
    // the signature of corrupted OSC payloads — clean filesystem paths
    // on macOS never contain them in practice.
    for scalar in p.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
    }
    return true
}
