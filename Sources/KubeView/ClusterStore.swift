import Foundation
import SwiftUI

struct NamespaceSummary: Identifiable, Hashable {
    let name: String
    let age: String
    let podCount: Int
    let runningCount: Int
    let failingCount: Int
    let unhealthyWorkloads: [UnhealthyItem]
    let cpuRequestedMillicores: Double
    let memoryRequestedBytes: Double
    let cpuUsedMillicores: Double
    let memoryUsedBytes: Double
    let ingressCount: Int
    var id: String { name }
    var isHealthy: Bool { failingCount == 0 && unhealthyWorkloads.isEmpty }
    var unhealthyCount: Int { failingCount + unhealthyWorkloads.count }
}

struct UnhealthyItem: Hashable, Identifiable {
    let kind: String
    let namespace: String
    let name: String
    let reason: String
    var id: String { "\(kind)/\(namespace)/\(name)" }
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
    let context: String
    @Published var pods: [Pod] = []
    @Published var nodes: [Node] = []
    @Published var namespaces: [Namespace] = []
    @Published var ingresses: [Ingress] = []
    @Published var services: [Service] = []
    @Published var secrets: [Secret] = []
    @Published var pvcs: [PVC] = []
    @Published var storageClasses: [StorageClass] = []
    @Published var networkPolicies: [NetworkPolicy] = []
    @Published var serviceAccounts: [ServiceAccount] = []
    @Published var deployments: [Deployment] = []
    @Published var statefulSets: [StatefulSet] = []
    @Published var replicaSets: [ReplicaSet] = []
    @Published var jobs: [KubeJob] = []
    @Published var cronJobs: [CronJob] = []
    @Published var daemonSets: [DaemonSet] = []
    @Published var configMaps: [ConfigMap] = []
    @Published var hpas: [HPA] = []
    @Published var nodeMetrics: [NodeMetrics] = []
    @Published var podMetrics: [PodMetrics] = []
    @Published var metricsAvailable: Bool = true
    @Published var serverVersion: String?
    @Published var loading = false
    @Published var lastError: String?
    @Published var lastRefresh: Date?

    // Precomputed derived state — updated in `refresh()`. Views read these
    // without recomputing per frame.
    @Published private(set) var namespaceSummaries: [NamespaceSummary] = []
    @Published private(set) var nodeUsage: [NodeUsage] = []
    @Published private(set) var unhealthyPods: [UnhealthyItem] = []
    @Published private(set) var unhealthyWorkloads: [UnhealthyItem] = []

    private let kubectl: KubectlService
    private var fastTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    private var refreshCounter = 0

    /// Resources fetched only every N fast cycles — typically large payloads
    /// (secrets data, configmap data, service-account secrets).
    private let slowCycleRatio = 6  // → ~30s with 5s fast cadence

    init(context: String) {
        self.context = context
        self.kubectl = KubectlService(context: context)
    }

    func start() {
        stop()
        fastTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        fastTask?.cancel()
        slowTask?.cancel()
        fastTask = nil
        slowTask = nil
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        let isSlowCycle = (refreshCounter % slowCycleRatio == 0)
        refreshCounter &+= 1
        if serverVersion == nil {
            serverVersion = (try? await kubectl.serverVersion()) ?? nil
        }
        do {
            async let ps = kubectl.pods()
            async let ns = kubectl.nodes()
            async let nss = kubectl.namespaces()
            async let igs = kubectl.ingresses()
            async let svcs = kubectl.services()
            async let pvcsF = kubectl.pvcs()
            async let scs = kubectl.storageClasses()
            async let npols = kubectl.networkPolicies()
            async let sas = kubectl.serviceAccounts()
            async let deps = kubectl.deployments()
            async let sts = kubectl.statefulSets()
            async let rs = kubectl.replicaSets()
            async let jbs = kubectl.jobs()
            async let cjs = kubectl.cronJobs()
            async let ds = kubectl.daemonSets()
            async let hps = kubectl.hpas()
            async let nm = kubectl.nodeMetrics()
            async let pm = kubectl.podMetrics()

            self.pods = try await ps
            self.nodes = try await ns
            self.namespaces = try await nss
            self.ingresses = (try? await igs) ?? []
            self.services = try await svcs
            self.pvcs = (try? await pvcsF) ?? []
            self.storageClasses = (try? await scs) ?? []
            self.networkPolicies = (try? await npols) ?? []
            self.serviceAccounts = (try? await sas) ?? []
            self.deployments = (try? await deps) ?? []
            self.statefulSets = (try? await sts) ?? []
            self.replicaSets = (try? await rs) ?? []
            self.jobs = (try? await jbs) ?? []
            self.cronJobs = (try? await cjs) ?? []
            self.daemonSets = (try? await ds) ?? []
            self.hpas = (try? await hps) ?? []

            if isSlowCycle {
                self.secrets = (try? await kubectl.secrets()) ?? []
                self.configMaps = (try? await kubectl.configMaps()) ?? []
            }
            let nMetrics = await nm
            let pMetrics = await pm
            self.nodeMetrics = nMetrics ?? []
            self.podMetrics = pMetrics ?? []
            self.metricsAvailable = (nMetrics != nil) || (pMetrics != nil)

            let uw = computeUnhealthyWorkloads()
            self.unhealthyWorkloads = uw
            self.unhealthyPods = computeUnhealthyPods()
            self.nodeUsage = computeNodeUsage()
            self.namespaceSummaries = computeNamespaceSummaries(unhealthyWorkloads: uw)

            self.lastError = nil
            self.lastRefresh = Date()
        } catch {
            self.lastError = error.localizedDescription
        }
    }


    // MARK: - Derived

    var podsRunning: Int { pods.filter { $0.phase == "Running" }.count }
    var podsFailing: Int { unhealthyPods.count }
    var nodesReady: Int { nodes.filter { $0.readyCondition == "Ready" }.count }

    var unhealthyAll: [UnhealthyItem] { unhealthyPods + unhealthyWorkloads }

    private func computeUnhealthyPods() -> [UnhealthyItem] {
        pods.compactMap { p in
            guard let r = p.failureReason else { return nil }
            return UnhealthyItem(kind: "Pod", namespace: p.namespace, name: p.name, reason: r)
        }
    }

    private func computeUnhealthyWorkloads() -> [UnhealthyItem] {
        var out: [UnhealthyItem] = []
        for d in deployments where !d.isHealthy {
            out.append(UnhealthyItem(kind: "Deployment", namespace: d.namespace, name: d.name,
                                     reason: d.unhealthyReason ?? "degraded"))
        }
        for s in statefulSets where !s.isHealthy {
            out.append(UnhealthyItem(kind: "StatefulSet", namespace: s.namespace, name: s.name,
                                     reason: s.unhealthyReason ?? "degraded"))
        }
        for r in replicaSets where !r.isHealthy && r.desired > 0 {
            out.append(UnhealthyItem(kind: "ReplicaSet", namespace: r.namespace, name: r.name,
                                     reason: r.unhealthyReason ?? "degraded"))
        }
        for j in jobs where !j.isHealthy {
            out.append(UnhealthyItem(kind: "Job", namespace: j.namespace, name: j.name,
                                     reason: j.unhealthyReason ?? "failed"))
        }
        for d in daemonSets where !d.isHealthy {
            out.append(UnhealthyItem(kind: "DaemonSet", namespace: d.namespace, name: d.name,
                                     reason: d.unhealthyReason ?? "degraded"))
        }
        return out
    }

    private func computeNamespaceSummaries(unhealthyWorkloads: [UnhealthyItem]) -> [NamespaceSummary] {
        let podsByNs = Dictionary(grouping: pods, by: { $0.namespace })
        let ingByNs = Dictionary(grouping: ingresses, by: { $0.namespace })
        let metricsByNs = Dictionary(grouping: podMetrics, by: { $0.namespace })
        let unhealthyByNs = Dictionary(grouping: unhealthyWorkloads, by: { $0.namespace })

        return namespaces.map { ns -> NamespaceSummary in
            let nsPods = podsByNs[ns.name] ?? []
            let failing = nsPods.filter { $0.isFailing }.count
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
                unhealthyWorkloads: unhealthyByNs[ns.name] ?? [],
                cpuRequestedMillicores: cpuReq,
                memoryRequestedBytes: memReq,
                cpuUsedMillicores: cpuUsed,
                memoryUsedBytes: memUsed,
                ingressCount: (ingByNs[ns.name] ?? []).count
            )
        }
        .sorted { $0.name < $1.name }
    }

    private func computeNodeUsage() -> [NodeUsage] {
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
