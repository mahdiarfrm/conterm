import AppKit
import Foundation

/// Enumerates monospaced font families installed on the system. Used by
/// Settings → Appearance → Font to populate the family picker.
@MainActor
final class FontCatalog: ObservableObject {
    @Published private(set) var families: [String] = []
    @Published var currentFamily: String?
    @Published var currentSize: Double

    /// Hard floor / ceiling keep the live preview readable. Most users
    /// land between 11 and 16.
    static let minSize: Double = 8
    static let maxSize: Double = 32

    @Published private(set) var isLoading = false
    private var didStartLoad = false

    /// Cheap init — just two config reads. Enumerating every installed
    /// font family (and probing each for the monospace trait) is slow
    /// enough to stutter the launch animation, so it's deferred to
    /// `ensureLoaded()` and run off the main thread.
    init() {
        currentFamily = UserConfigStore.read(key: "font-family")
        currentSize = UserConfigStore.read(key: "font-size")
            .flatMap(Double.init) ?? 13
    }

    /// One-time background font enumeration. No-ops after first call.
    func ensureLoaded() {
        guard !didStartLoad else { return }
        didStartLoad = true
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let list = Self.enumerateMonospaceFamilies()
            await MainActor.run {
                self.families = list
                self.isLoading = false
            }
        }
    }

    nonisolated private static func enumerateMonospaceFamilies() -> [String] {
        let fm = NSFontManager.shared
        var hits: [String] = []
        for family in fm.availableFontFamilies {
            if let font = NSFont(name: family, size: 12),
               (font.fontDescriptor.symbolicTraits.contains(.monoSpace)
                    || family.lowercased().contains("mono")
                    || family.lowercased().contains("code")) {
                hits.append(family)
            }
        }
        let preferred = [
            "JetBrains Mono", "JetBrains Mono NL", "Fira Code",
            "Cascadia Code", "SF Mono", "Menlo", "Monaco", "Hack",
        ]
        let preferredSet = Set(preferred)
        let top = preferred.filter { hits.contains($0) }
        let rest = hits
            .filter { !preferredSet.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return top + rest
    }

    func apply(family: String?) {
        currentFamily = family
        UserConfigStore.write(key: "font-family",
                               value: family.map(UserConfigStore.quote) ?? "")
        Ghostty.App.shared?.reloadConfig()
    }

    func apply(size: Double) {
        let clamped = min(Self.maxSize, max(Self.minSize, size.rounded()))
        currentSize = clamped
        UserConfigStore.write(key: "font-size", value: String(Int(clamped)))
        Ghostty.App.shared?.reloadConfig()
    }
}
