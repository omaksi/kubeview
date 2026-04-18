import Foundation
import SwiftUI

struct NamespaceSummary: Identifiable, Hashable {
    let name: String
    let age: String
    let podCount: Int
    let runningCount: Int
    let failingCount: Int
    let cpuRequestedMillicores: Double
    let memoryRequestedBytes: Double
    let cpuUsedMillicores: Double
    let memoryUsedBytes: Double
    let ingressCount: Int
    var id: String { name }
}

struct NodeUsage: Identifiable, Hashable {
    let name: String
    let ready: Bool
    let cpuUsedMillicores: Double
    let cpuCapacityMillicores: Double
    let memoryUsedBytes: Double
    let memoryCapacityBytes: Double
    var id: String { name }
    var cpuPercent: Double { cpuCapacityMillicores > 0 ? (cpuUsedMillicores / cpuCapacityMillicores) * 100 : 0 }
    var memoryPercent: Double { memoryCapacityBytes > 0 ? (memoryUsedBytes / memoryCapacityBytes) * 100 : 0 }
}

@MainActor
final class ClusterStore: ObservableObject {
    @Published var contexts: [KubeContext] = []
    @Published var currentContext: String = ""
    @Published var pods: [Pod] = []
    @Published var nodes: [Node] = []
    @Published var namespaces: [Namespace] = []
    @Published var ingresses: [Ingress] = []
    @Published var services: [Service] = []
    @Published var nodeMetrics: [NodeMetrics] = []
    @Published var podMetrics: [PodMetrics] = []
    @Published var metricsAvailable: Bool = true
    @Published var loading = false
    @Published var lastError: String?
    @Published var lastRefresh: Date?

    private let kubectl = KubectlService()
    private var refreshTask: Task<Void, Never>?

    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            async let ctx = kubectl.currentContext()
            async let ctxs = kubectl.contexts()
            async let ps = kubectl.pods()
            async let ns = kubectl.nodes()
            async let nss = kubectl.namespaces()
            async let igs = kubectl.ingresses()
            async let svcs = kubectl.services()
            async let nm = kubectl.nodeMetrics()
            async let pm = kubectl.podMetrics()

            let (c, cs, p, n, nses, ings, sv, nMetrics, pMetrics) =
                try await (ctx, ctxs, ps, ns, nss, igs, svcs, nm, pm)

            self.currentContext = c
            self.contexts = cs
            self.pods = p
            self.nodes = n
            self.namespaces = nses
            self.ingresses = ings
            self.services = sv
            self.nodeMetrics = nMetrics ?? []
            self.podMetrics = pMetrics ?? []
            self.metricsAvailable = (nMetrics != nil) || (pMetrics != nil)
            self.lastError = nil
            self.lastRefresh = Date()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func switchContext(_ name: String) async {
        do {
            try await kubectl.switchContext(name)
            await refresh()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Derived

    var podsRunning: Int { pods.filter { $0.phase == "Running" }.count }
    var podsFailing: Int { pods.filter { ["Failed", "CrashLoopBackOff", "Error"].contains($0.phase) }.count }
    var nodesReady: Int { nodes.filter { $0.readyCondition == "Ready" }.count }

    var namespaceSummaries: [NamespaceSummary] {
        let podsByNs = Dictionary(grouping: pods, by: { $0.namespace })
        let ingByNs = Dictionary(grouping: ingresses, by: { $0.namespace })
        let metricsByNs = Dictionary(grouping: podMetrics, by: { $0.namespace })

        return namespaces.map { ns -> NamespaceSummary in
            let nsPods = podsByNs[ns.name] ?? []
            let failing = nsPods.filter { ["Failed", "CrashLoopBackOff", "Error"].contains($0.phase) }.count
            let running = nsPods.filter { $0.phase == "Running" }.count

            let cpuReq = nsPods.reduce(0.0) { acc, pod in
                acc + (pod.spec?.containers ?? []).reduce(0.0) {
                    $0 + ResourceParser.cpuToMillicores($1.resources?.requests?["cpu"] ?? "0")
                }
            }
            let memReq = nsPods.reduce(0.0) { acc, pod in
                acc + (pod.spec?.containers ?? []).reduce(0.0) {
                    $0 + ResourceParser.memoryToBytes($1.resources?.requests?["memory"] ?? "0")
                }
            }

            let nsMetrics = metricsByNs[ns.name] ?? []
            let cpuUsed = nsMetrics.reduce(0.0) { $0 + $1.cpuMillicores }
            let memUsed = nsMetrics.reduce(0.0) { $0 + $1.memoryBytes }

            return NamespaceSummary(
                name: ns.name,
                age: ns.age,
                podCount: nsPods.count,
                runningCount: running,
                failingCount: failing,
                cpuRequestedMillicores: cpuReq,
                memoryRequestedBytes: memReq,
                cpuUsedMillicores: cpuUsed,
                memoryUsedBytes: memUsed,
                ingressCount: (ingByNs[ns.name] ?? []).count
            )
        }
        .sorted { $0.name < $1.name }
    }

    var nodeUsage: [NodeUsage] {
        let metricsByName = Dictionary(uniqueKeysWithValues: nodeMetrics.map { ($0.name, $0) })
        return nodes.map { node in
            let m = metricsByName[node.name]
            return NodeUsage(
                name: node.name,
                ready: node.readyCondition == "Ready",
                cpuUsedMillicores: m.map { ResourceParser.cpuToMillicores($0.cpu) } ?? 0,
                cpuCapacityMillicores: node.cpuCapacityMillicores,
                memoryUsedBytes: m.map { ResourceParser.memoryToBytes($0.memory) } ?? 0,
                memoryCapacityBytes: node.memoryCapacityBytes
            )
        }
    }

    var clusterCpuCapacityMillicores: Double { nodes.reduce(0) { $0 + $1.cpuCapacityMillicores } }
    var clusterMemoryCapacityBytes: Double { nodes.reduce(0) { $0 + $1.memoryCapacityBytes } }
    var clusterCpuUsedMillicores: Double { nodeMetrics.reduce(0) { $0 + ResourceParser.cpuToMillicores($1.cpu) } }
    var clusterMemoryUsedBytes: Double { nodeMetrics.reduce(0) { $0 + ResourceParser.memoryToBytes($1.memory) } }
}
