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

enum ConnectionFault: Equatable {
    case unreachable
    case notLoggedIn
    case forbidden
    case tls
    case kubectlMissing
    case other

    /// Fits inside a cluster pill — anything longer wraps or truncates.
    var short: String {
        switch self {
        case .unreachable:    return "unreachable"
        case .notLoggedIn:    return "not logged in"
        case .forbidden:      return "no access"
        case .tls:            return "TLS error"
        case .kubectlMissing: return "no kubectl"
        case .other:          return "error"
        }
    }

    var icon: String {
        switch self {
        case .unreachable:    return "wifi.slash"
        case .notLoggedIn:    return "lock.fill"
        case .forbidden:      return "hand.raised.fill"
        case .tls:            return "lock.trianglebadge.exclamationmark"
        case .kubectlMissing: return "questionmark.circle"
        case .other:          return "exclamationmark.triangle.fill"
        }
    }

    /// Red is for "your cluster is broken". A cluster we simply can't talk to is
    /// orange — the workloads may well be fine, we just can't see them.
    var color: Color {
        switch self {
        case .forbidden, .notLoggedIn: return .orange
        default:                       return .red
        }
    }
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
    @Published var lastError: String?

    /// The namespace the UI is scoped to, or nil for all namespaces. Per
    /// context — each cluster remembers its own — and deliberately *not*
    /// `kubectl config set-context --namespace`: that rewrites the user's
    /// kubeconfig and follows them into every terminal, the same trap
    /// `use-context` is.
    @Published var namespaceFilter: String? {
        didSet { UserDefaults.standard.set(namespaceFilter, forKey: Self.filterKey(context)) }
    }
    @Published var lastRefresh: Date?
    /// When the cheap reachability probe last ran. Separate from `lastRefresh`,
    /// which only moves when resources are actually fetched.
    @Published private(set) var lastProbe: Date?

    /// True only until the first refresh resolves either way. A failed first
    /// refresh leaves `lastRefresh` nil forever, so the error has to clear this
    /// too — otherwise every list would spin indefinitely instead of surfacing
    /// `lastError`.
    var isFirstLoad: Bool { lastRefresh == nil && lastError == nil }

    /// What the store is doing right now, surfaced by `LoadingPlaceholder` once
    /// it has been running long enough to be worth mentioning.
    @Published private(set) var activity: String?
    @Published private(set) var activitySince: Date?

    /// Why the cluster isn't answering, when it isn't. Typed rather than derived
    /// from `lastError` text at each call site, so the pill, the menu bar and
    /// the banner all agree.
    @Published private(set) var fault: ConnectionFault?

    var isConnected: Bool { fault == nil && lastRefresh != nil }

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
        // Property observers don't fire during init, so reading the saved
        // filter here can't immediately rewrite what it just read.
        self.namespaceFilter = UserDefaults.standard.string(forKey: Self.filterKey(context))
        #if DEBUG
        Self.selfCheck()
        #endif
    }

    static func filterKey(_ context: String) -> String { "kubeview.namespaceFilter.\(context)" }

    /// Options for the namespace picker: this cluster's namespaces, plus the
    /// current selection when the cluster doesn't have it — a filter restored
    /// from a previous launch, or one whose namespace was deleted, has to stay
    /// listed rather than silently reading as "All Namespaces".
    static func pickerOptions(_ names: [String], selected: String?) -> [String] {
        let sorted = names.sorted()
        guard let selected, !sorted.contains(selected) else { return sorted }
        return [selected] + sorted
    }

    #if DEBUG
    static func selfCheck() {
        struct Item { let namespace: String }
        let items = [Item(namespace: "a"), Item(namespace: "b"), Item(namespace: "a")]
        assert(items.inNamespace(nil, \.namespace).count == 3)      // nil = all namespaces
        assert(items.inNamespace("a", \.namespace).count == 2)
        assert(items.inNamespace("gone", \.namespace).isEmpty)
        // Cluster-scoped kinds never route through the filter — they have no
        // namespace to match against in the first place.
        assert(ResourceRef.node("ip-10-0-0-1").namespace == nil)
        assert(ResourceRef.pod("kube-system", "coredns").namespace == "kube-system")
        assert(pickerOptions(["b", "a"], selected: nil) == ["a", "b"])
        assert(pickerOptions(["b", "a"], selected: "a") == ["a", "b"])
        assert(pickerOptions(["b", "a"], selected: "gone") == ["gone", "a", "b"])
    }
    #endif

    /// How hard this store is working. Tabs drive it: the focused tab's cluster
    /// runs `.live`, every other open tab's cluster runs `.background`, and a
    /// cluster nobody has a tab on is `.idle`.
    ///
    /// The point is that traffic is flat in the number of tabs. Only one cluster
    /// ever fans out into the ~18 parallel resource fetches; the rest cost one
    /// `kubectl get --raw /version` a minute, which is enough to answer "is it
    /// up, and are my credentials still good?" and nothing more.
    enum Cadence: Equatable { case idle, background, live }

    @Published private(set) var cadence: Cadence = .idle

    /// True once *any* data has been fetched. Distinct from `isConnected`: a
    /// background tab can be perfectly reachable while holding nothing to show.
    var hasData: Bool { lastRefresh != nil }

    private static let liveInterval: UInt64 = 5_000_000_000
    /// Deliberately slow. This runs for every open-but-unfocused tab, so it is
    /// the cost of *having* tabs — it has to stay negligible.
    private static let probeInterval: UInt64 = 60_000_000_000

    func goLive() {
        guard cadence != .live else { return }
        cancelTasks()
        cadence = .live
        LogStore.record(.debug, "cadence → live", context: context)
        fastTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.liveInterval)
            }
        }
    }

    /// Probe-only. Existing data is left on screen — it just stops being
    /// refreshed, which is why views show a "paused" marker rather than
    /// pretending the numbers are current.
    func goBackground() {
        guard cadence != .background else { return }
        cancelTasks()
        cadence = .background
        LogStore.record(.debug, "cadence → background", context: context)
        fastTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probe()
                try? await Task.sleep(nanoseconds: Self.probeInterval)
            }
        }
    }

    func stop() {
        cancelTasks()
        cadence = .idle
    }

    private func cancelTasks() {
        fastTask?.cancel()
        slowTask?.cancel()
        fastTask = nil
        slowTask = nil
    }

    /// The cheap tier: one call, no resource lists, no fan-out. It runs the
    /// kubeconfig's exec credential plugin, so a single request separates
    /// "cluster is down" from "your token expired" — which is exactly the
    /// distinction a tab's status dot has to make.
    ///
    /// ponytail: `/version` rather than `/readyz`. Both are one call, but
    /// `/readyz` is restricted on some clusters and would report a permissions
    /// problem as unreachability. `/version` is what `preflight()` has always
    /// used here against real EKS clusters.
    func probe() async {
        do {
            _ = try await kubectl.run(["get", "--raw", "/version"], timeout: 5)
            fault = nil
            lastError = nil
            lastProbe = Date()
        } catch {
            let raw = error.localizedDescription
            setFault(raw)
            lastProbe = Date()
            LogStore.record(.debug, "probe failed", context: context, detail: raw)
        }
    }

    private func setActivity(_ text: String?) {
        activity = text
        activitySince = text == nil ? nil : Date()
    }

    /// One cheap call that exercises DNS, TCP, TLS and auth before we fan out
    /// into ~18 parallel fetches. Without it an unreachable or logged-out
    /// cluster costs a full watchdog timeout (~22s) *and* spawns 18 doomed
    /// kubectl processes; with it we fail in ~7s with a message that names the
    /// actual problem. Skipped once the cluster is known healthy, so the steady
    /// state doesn't pay for an extra process every 5s.
    private func preflight() async -> Bool {
        guard lastRefresh == nil || lastError != nil else { return true }
        setActivity("Contacting cluster")
        do {
            _ = try await kubectl.run(["get", "--raw", "/version"], timeout: 5)
            return true
        } catch {
            let raw = error.localizedDescription
            setFault(raw)
            LogStore.record(.error, "preflight failed", context: context, detail: raw)
            setActivity(nil)
            return false
        }
    }

    /// Order matters. TLS and auth failures are reported *through* a connection
    /// error ("Unable to connect to the server: x509: …"), so the specific
    /// causes have to be tested before the generic connectivity patterns.
    ///
    /// Patterns are kubectl's real output, captured per failure mode — it never
    /// says "timed out" for any of them:
    ///   black-holed  → "Unable to connect to the server: context deadline exceeded"
    ///   refused      → "The connection to the server host:port was refused"
    ///   bad DNS      → "…dial tcp: lookup host: no such host"
    ///   no creds     → "Please enter Username: error: EOF"
    static func classify(_ raw: String, context: String) -> (ConnectionFault, String) {
        let lower = raw.lowercased()
        func any(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }

        if any(["unauthorized", "401"]) {
            return (.notLoggedIn, "Not authenticated to \(context) — your credentials expired or need a re-login")
        }
        if any(["please enter username", "error: eof",
                "no configuration has been provided", "unable to load", "credentials"]) {
            return (.notLoggedIn, "Not logged in to \(context) — no usable credentials in your kubeconfig")
        }
        if any(["forbidden", "403"]) {
            return (.forbidden, "Access denied on \(context) — this account lacks permission")
        }
        if any(["x509", "certificate", "tls:"]) {
            return (.tls, "TLS problem talking to \(context) — \(raw)")
        }
        if any(["context deadline exceeded", "unable to connect to the server",
                "was refused", "connection refused", "no such host", "dial tcp",
                "i/o timeout", "client.timeout", "timed out", "no route to host"]) {
            return (.unreachable, "Can't reach \(context) — cluster unreachable (VPN or network down?)")
        }
        if lower.contains("kubectl") && any(["not found", "not executable"]) {
            return (.kubectlMissing, "kubectl not found on PATH")
        }
        return (.other, raw)
    }

    private func setFault(_ raw: String) {
        let (fault, message) = Self.classify(raw, context: context)
        self.fault = fault
        self.lastError = message
    }

    func refresh() async {
        let isSlowCycle = (refreshCounter % slowCycleRatio == 0)
        let cycle = refreshCounter
        let started = Date()
        refreshCounter &+= 1
        LogStore.record(.debug, "refresh cycle \(cycle) start\(isSlowCycle ? " (slow)" : "")",
                        context: context)
        guard await preflight() else { return }
        setActivity("Loading cluster resources")
        defer { setActivity(nil) }
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
            self.fault = nil
            self.lastRefresh = Date()
            LogStore.record(.debug,
                            "refresh cycle \(cycle) ok in \(Int(Date().timeIntervalSince(started) * 1000))ms — \(pods.count) pods, \(namespaces.count) namespaces",
                            context: context)
        } catch {
            let raw = error.localizedDescription
            setFault(raw)
            LogStore.record(.error,
                            "refresh cycle \(cycle) failed after \(Int(Date().timeIntervalSince(started) * 1000))ms",
                            context: context, detail: raw)
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

/// The namespace filter, applied the same way `searchFiltered` applies the
/// search box: chained by each list view over the collection it renders.
/// A nil filter means all namespaces. Cluster-scoped kinds (nodes, storage
/// classes, the namespace list itself) have no namespace and never call this.
///
/// ponytail: applied per list view rather than centrally in `refresh()`. The
/// cluster-wide surfaces stay cluster-wide on purpose — Overview's stats and
/// namespace grid, the Namespaces list, and Linkerd's mesh coverage are all
/// answers about the whole cluster, and scoping them to one namespace would
/// make them lie.
extension Collection {
    func inNamespace(_ namespace: String?, _ key: KeyPath<Element, String>) -> [Element] {
        guard let namespace else { return Array(self) }
        return filter { $0[keyPath: key] == namespace }
    }
}
