import Foundation

/// Helm releases for the Cluster Overview card: one lazy
/// `helm list -A` per card open (60 s cache per context), pinned with
/// `--kube-context` so the list always matches the card's title. No
/// helm CLI on the machine → the band simply never renders.
@MainActor
final class HelmReleases: ObservableObject {
    static let shared = HelmReleases()

    nonisolated static let helmPath = locateWidgetTool("helm")

    struct Release: Identifiable, Equatable {
        var id: String { "\(namespace)/\(name)" }
        let name: String
        let namespace: String
        let revision: String
        let status: String
        let chart: String
    }

    @Published private(set) var releases: [Release] = []
    @Published private(set) var loading = false
    private var context: String?
    private var fetchedAt: Date?

    private init() {}

    func refresh(context: String, force: Bool = false) {
        guard let helm = Self.helmPath, !loading else { return }
        if !force, context == self.context, let at = fetchedAt,
           Date().timeIntervalSince(at) < 60 {
            return
        }
        if context != self.context {
            releases = []
            fetchedAt = nil
        }
        self.context = context
        loading = true
        let env = ["KUBECONFIG": KubeContextWatch.configPaths()
            .joined(separator: ":")]
        Task.detached(priority: .userInitiated) {
            let out = runWidgetTool(helm,
                ["list", "-A", "--max", "30",
                 "--kube-context", context, "-o", "json"], env: env)
            let parsed = out.flatMap(Self.parse) ?? []
            await MainActor.run {
                self.loading = false
                guard self.context == context else { return }
                self.fetchedAt = Date()
                if self.releases != parsed { self.releases = parsed }
            }
        }
    }

    /// `helm list -o json`: array of objects with name / namespace /
    /// revision / status / chart. Revision is a string in current
    /// helm; tolerate a number anyway.
    nonisolated static func parse(_ out: String) -> [Release]? {
        guard let data = out.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data))
                as? [[String: Any]] else { return nil }
        return arr.compactMap { obj in
            guard let name = obj["name"] as? String, !name.isEmpty
            else { return nil }
            let revision = (obj["revision"] as? String)
                ?? (obj["revision"] as? Int).map(String.init) ?? ""
            return Release(name: name,
                           namespace: (obj["namespace"] as? String) ?? "",
                           revision: revision,
                           status: (obj["status"] as? String) ?? "",
                           chart: (obj["chart"] as? String) ?? "")
        }
    }
}
