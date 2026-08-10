import Foundation
import Testing
@testable import Conterm

/// Node categorisation the mode's entry summary counts on: "2 need you" is a
/// count of *sessions*, so a new node kind landing in the wrong bucket would
/// quietly change what Orbit reports the moment you walk in.
struct OrbitGraphTests {
    private func node(_ kind: MapNode.Kind, _ status: MapNode.Status = .neutral) -> MapNode {
        MapNode(id: "n", kind: kind, label: "n", subtitle: nil, status: status, pane: nil)
    }

    @Test func sessionsArePanesAndBackgroundAgents() {
        #expect(node(.pane(UUID())).isSession)
        #expect(node(.agent(name: "nightly")).isSession)
    }

    @Test func infrastructureAndActivityAreNotSessions() {
        #expect(!node(.mac).isSession)
        #expect(!node(.host(target: "web1", active: true)).isSession)
        #expect(!node(.cluster(context: "prod", danger: true)).isSession)
        #expect(!node(.container(name: "nginx")).isSession)
        #expect(!node(.k8s(nodes: 3)).isSession)
        #expect(!node(.project(name: "conterm")).isSession)
        #expect(!node(.network(label: "10.0.0")).isSession)
        #expect(!node(.note(text: "todo")).isSession)
        // A sub-agent and a shell command are a session's *activity*, not
        // sessions themselves — counting them would double-report one agent.
        #expect(!node(.subagent(task: "search")).isSession)
        #expect(!node(.shellCmd(command: "ls")).isSession)
    }

    @Test func identityIgnoresTheLiveBackReference() {
        // `pane` is a weak back-reference, deliberately outside equality: a
        // republish must not be triggered by it alone.
        let id = UUID()
        let a = MapNode(id: "pane:\(id)", kind: .pane(id), label: "~/proj",
                        subtitle: nil, status: .working, pane: nil)
        var b = a
        b.status = .attention
        #expect(a != b)
        #expect(a == a)
    }
}

/// `kubectl` column output is whitespace-formatted, so the drill-down's parsing
/// is the part most likely to break quietly — a mis-parse shows an empty
/// cluster, which looks identical to a cluster with nothing in it.
struct KubeDrillParsingTests {
    @Test func parsesNodesAndTheirReadiness() {
        // `.spec.unschedulable` prints as <none> on a node taking work.
        let out = """
        kind-conterm-control-plane   Ready            <none>
        worker-01                    Ready            true
        worker-02                    MemoryPressure   <none>
        """
        let nodes = KubeDrill.parseNodes(out)
        #expect(nodes.count == 3)
        #expect(nodes[0].name == "kind-conterm-control-plane")
        #expect(nodes[0].ready)
        #expect(nodes[0].schedulable)
        // Cordoned is not the same as unhealthy: ready, but closed to new pods.
        #expect(nodes[1].ready)
        #expect(!nodes[1].schedulable)
        #expect(nodes[2].name == "worker-02")
        #expect(!nodes[2].ready)
        #expect(nodes[2].schedulable)
    }

    @Test func workloadKnowsWhatItCanBeAskedToDo() {
        let deploy = KubeDrill.Workload(kind: "Deployment", name: "web", replicas: 3)
        #expect(deploy.scalable)
        #expect(deploy.restartable)
        #expect(deploy.label == "Deployment/web")
        // A DaemonSet scales by node, so it has no replica count to set.
        let ds = KubeDrill.Workload(kind: "DaemonSet", name: "fluentd", replicas: nil)
        #expect(!ds.scalable)
        #expect(ds.restartable)
        // A pod standing on its own is neither.
        let bare = KubeDrill.Workload(kind: "Node", name: "n1", replicas: nil)
        #expect(!bare.scalable)
        #expect(!bare.restartable)
    }

    @Test func ignoresBlankLines() {
        #expect(KubeDrill.parseNodes("").isEmpty)
        #expect(KubeDrill.parseNodes("\n\n").isEmpty)
    }

    @Test func parsesPodsWithNamespaceAndPhase() {
        let out = """
        kube-system   coredns-abc123        Running
        default       web-7d9f             Pending
        """
        let pods = KubeDrill.parsePods(out)
        #expect(pods.count == 2)
        #expect(pods[0].namespace == "kube-system")
        #expect(pods[0].name == "coredns-abc123")
        #expect(pods[0].running)
        #expect(pods[1].namespace == "default")
        #expect(!pods[1].running)
    }

    @Test func skipsRowsMissingColumns() {
        // A truncated row must not become a pod with a nonsense name.
        #expect(KubeDrill.parsePods("kube-system   coredns-abc123").isEmpty)
    }

    @Test func parsesContainersWithReadinessAndRestarts() {
        // Tab-separated, from the jsonpath template — an image reference has
        // spaces in neither half, but a column split would still be the wrong
        // tool the day one does.
        let out = "app\ttrue\t0\tnginx:1.27\nsidecar\tfalse\t7\tenvoy:v1.31\n"
        let containers = KubeDrill.parseContainers(out)
        #expect(containers.count == 2)
        #expect(containers[0].name == "app")
        #expect(containers[0].ready)
        #expect(containers[0].restarts == 0)
        #expect(containers[0].image == "nginx:1.27")
        #expect(!containers[1].ready)
        #expect(containers[1].restarts == 7)
    }

    @Test func toleratesAPodStillWithoutStatuses() {
        // A pod that hasn't been scheduled has no containerStatuses at all.
        #expect(KubeDrill.parseContainers("").isEmpty)
        #expect(KubeDrill.parseContainers("app\ttrue").isEmpty)
    }
}
