import AppKit
import Foundation

/// Real distribution marks, fetched once and kept.
///
/// The art is Simple Icons — CC0, and one monochrome path per brand, which is
/// exactly the shape a template image wants: the mark takes whatever colour the
/// card gives it, so a fleet of hosts reads as one surface rather than twenty
/// competing logos.
///
/// A mark is fetched at most once ever. It lands under Application Support, and
/// every later launch reads it from disk — so this is one small request the
/// first time you meet a distribution, and nothing after that.
@MainActor
final class DistroArt: ObservableObject {
    static let shared = DistroArt()

    /// Bumped when a mark becomes available, so views showing the fallback
    /// redraw with the real thing.
    @Published private(set) var revision = 0

    private var loaded: [Distro: NSImage] = [:]
    /// Distributions already looked for this launch, hit or miss — an absent
    /// mark must not re-ask the network (or the disk) on every card.
    private var attempted: Set<Distro> = []

    private init() {}

    /// The mark, if it is already in hand. Pure: fetching is `ensure`'s job, so
    /// a view body can call this on every frame without starting anything.
    func mark(for distro: Distro) -> NSImage? { loaded[distro] }

    /// Make sure this distribution's mark is on disk and in memory. Cheap and
    /// idempotent — call it whenever a host reports what it runs.
    func ensure(_ distro: Distro) {
        guard loaded[distro] == nil, !attempted.contains(distro) else { return }
        attempted.insert(distro)
        guard let slug = distro.iconSlug else { return }

        if let img = Self.image(atCachedPathFor: slug) {
            adopt(img, for: distro)
            return
        }
        fetch(distro, slug: slug, from: Self.sources(slug))
    }

    /// Walk the mirrors until one answers. A single CDN is a single point of
    /// failure on a restricted network, and a mark that never arrives looks
    /// exactly like a feature that was never built.
    private func fetch(_ distro: Distro, slug: String, from sources: [URL]) {
        guard let url = sources.first else {
            // Every mirror refused. Forget the attempt so the next sweep — the
            // next probe, or the next time Orbit opens — tries again instead of
            // giving up for the rest of the session.
            attempted.remove(distro)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let rest = Array(sources.dropFirst())
            guard let data, Self.looksLikeIcon(data, response) else {
                Task { @MainActor in self.fetch(distro, slug: slug, from: rest) }
                return
            }
            Task { @MainActor in
                guard let img = Self.decode(data) else {
                    self.fetch(distro, slug: slug, from: rest)
                    return
                }
                Self.writeCache(data, slug: slug)
                self.adopt(img, for: distro)
            }
        }.resume()
    }

    /// Fetch the marks for every distribution already known from a past launch.
    /// Covers the machine that met a host while offline: the distribution was
    /// recorded, the art wasn't, and nothing would ask for it again until that
    /// same host happened to be probed.
    func ensureKnown() {
        for distro in HostDistroStore.all.values { ensure(distro) }
    }

    private func adopt(_ image: NSImage, for distro: Distro) {
        image.isTemplate = true          // the card owns the colour
        loaded[distro] = image
        revision &+= 1
    }

    // MARK: - Source and cache

    /// Where a mark can come from, in order of preference. Version-pinned where
    /// the host allows it: both npm mirrors keep every published version, so a
    /// mark can't quietly change shape under a cache written months ago.
    private static func sources(_ slug: String) -> [URL] {
        [
            "https://cdn.jsdelivr.net/npm/simple-icons@15/icons/\(slug).svg",
            "https://unpkg.com/simple-icons@15/icons/\(slug).svg",
            "https://raw.githubusercontent.com/simple-icons/simple-icons/master/icons/\(slug).svg",
        ].compactMap(URL.init(string:))
    }

    private static var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Conterm/distro-marks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(_ slug: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(slug).svg")
    }

    private static func image(atCachedPathFor slug: String) -> NSImage? {
        guard let url = cacheURL(slug), let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private static func writeCache(_ data: Data, slug: String) {
        guard let url = cacheURL(slug) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func decode(_ data: Data) -> NSImage? {
        // NSImage reads SVG directly; a file that isn't one comes back nil
        // rather than as an empty mark.
        guard let img = NSImage(data: data), img.size.width > 0 else { return nil }
        return img
    }

    /// A CDN answers a missing icon with an HTML page and a 200 often enough
    /// that the status code alone isn't a check. The body has to look like an
    /// icon before it is allowed near the cache.
    nonisolated private static func looksLikeIcon(_ data: Data, _ response: URLResponse?) -> Bool {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return false }
        guard data.count > 32, data.count < 128 * 1024 else { return false }
        let head = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("<svg") || head.hasPrefix("<?xml")
    }
}

extension Distro {
    /// The Simple Icons slug for this distribution, where one exists. `nil`
    /// keeps the drawn mark or the tinted glyph — Amazon Linux has no icon in
    /// the set, and macOS already has a better one in `apple.logo`, which ships
    /// with the system and needs no fetching.
    var iconSlug: String? {
        switch self {
        case .ubuntu:   return "ubuntu"
        case .debian:   return "debian"
        case .fedora:   return "fedora"
        case .rhel:     return "redhat"
        case .centos:   return "centos"
        case .rocky:    return "rockylinux"
        case .alma:     return "almalinux"
        case .arch:     return "archlinux"
        case .alpine:   return "alpinelinux"
        case .suse:     return "opensuse"
        case .nixos:    return "nixos"
        case .gentoo:   return "gentoo"
        case .manjaro:  return "manjaro"
        case .raspbian: return "raspberrypi"
        case .kali:     return "kalilinux"
        case .mint:     return "linuxmint"
        case .proxmox:  return "proxmox"
        case .openwrt:  return "openwrt"
        case .freebsd:  return "freebsd"
        case .amazon, .macos: return nil
        }
    }
}
