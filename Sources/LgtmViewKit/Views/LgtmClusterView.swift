import Foundation
import SwiftUI
import KubeModel
import KubeClient
import KubeUI

/// The "what is true right now" face of the LGTM tab. Built entirely from
/// `LgtmClusterStore`, refreshed alongside the analyser report by
/// `LgtmStore.load()` — this view adds zero subprocess calls of its own, so
/// it paints immediately and keeps working when Mimir (the thing the
/// Metrics/Findings tabs depend on) is exactly the thing that's broken.
/// `report` supplies classification only (which
/// workload is which product/role); every number here is live Kubernetes
/// state, not the report's own (possibly minutes-stale) snapshot.
///
/// Two things this face can show that the metrics-history face (LgtmMetricsView)
/// cannot: a per-pod breakdown (the analyser only aggregates per component, so a
/// skewed set of replicas is invisible there) and a live per-product data-flow
/// graph (`LgtmGraphView`, fed with nodes built from live pod/deployment state
/// here — see `graphNodes(for:rows:report:)`).
///
/// This tab and Metrics are the ground-truth pair: the most accurate map of
/// what the cluster IS and what was measured, with no simplification and no
/// verdict. Every pod is shown individually, never folded into a single
/// average that could hide one hot replica among idle ones. Facts (not
/// ready, CrashLoopBackOff, OOMKilled, restart count, usage against the
/// configured limit) are welcome; thresholds and severity are not — that
/// judgment belongs to the Findings tab alone. `LgtmNodeLevel` on graph
/// nodes follows the same rule: only observed events, never a percentage
/// this file picked.
struct LgtmClusterView: View {
    let report: LgtmReport?
    @ObservedObject var store: LgtmClusterStore
    /// Set by `FindingCard.showPods()` (LgtmView.swift) when a Findings-tab
    /// finding's "Show pods" is tapped - the title of the component to
    /// scroll to once this tab is back on screen. Consumed once (and then
    /// cleared) by `consumeScrollTarget`, reusing the same scroll-to-card
    /// mechanism this view already has for graph-node taps (`handleGraphSelect`).
    @Binding var scrollToComponentTitle: String?
    /// The pod a tapped card wants inspected - drives `PodInspectSheet`. This
    /// is this app's replacement for the main app's `NavigationLink(value:
    /// AppRoute.pod(...))`, which pushed onto a nav stack this app doesn't
    /// have.
    @State private var inspecting: Pod?

    /// Restart counts below this are normal churn (a rollout, a one-off OOM
    /// that recovered). Above it, something is actively flapping and belongs
    /// in "Needs Attention" even while the pod currently reads Running/Ready.
    private static let highRestartThreshold = 5

    /// Names the LGTM Helm charts give their workloads, used only when `report`
    /// hasn't landed yet. Not shared with anything now - `ContentView.isLgtm`
    /// (the one other place this exact name list lived) was deleted along
    /// with the rest of KubeView's LGTM tab when this app split off, so there
    /// is nothing left to share it with.
    private static let knownProducts = ["mimir", "loki", "tempo", "grafana", "alloy", "pyroscope"]

    var body: some View {
        Group {
            if store.isFirstLoad {
                LoadingPlaceholder(label: "LGTM stack")
            } else {
                // Built once per render and threaded through both the aggregate
                // usage in buildRows() and the per-pod bars in each component
                // card, so neither has to rescan store.podMetrics on its own.
                let metricsByPodKey = metricsByPodKey()
                let rows = buildRows(metricsByPodKey: metricsByPodKey)
                if rows.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                if report == nil {
                                    Label("Classification still running - grouping by name until kubectl-lgtm finishes",
                                          systemImage: "hourglass")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                summarySection(rows)
                                let trouble = troublePods(rows)
                                if !trouble.isEmpty {
                                    troubleSection(trouble)
                                }
                                ForEach(productOrder(rows), id: \.self) { product in
                                    let productRows = rows.filter { $0.product == product }
                                    // The flow graph needs real classification (product/role,
                                    // request/limit ceilings) to mean anything - it stays off
                                    // until `report` lands, same as the "still running" banner
                                    // above already communicates.
                                    if let report {
                                        graphSection(product: product, rows: productRows, report: report,
                                                     proxy: proxy, podMetricsByID: metricsByPodKey)
                                    }
                                    productSection(product: product, rows: productRows,
                                                   podMetricsByID: metricsByPodKey)
                                }
                                nodePlacementSection(rows)
                            }
                            .padding()
                        }
                        .onAppear { consumeScrollTarget(rows: rows, proxy: proxy) }
                        .onChange(of: scrollToComponentTitle) { _, _ in
                            consumeScrollTarget(rows: rows, proxy: proxy)
                        }
                    }
                }
            }
        }
        .sheet(item: $inspecting) { pod in
            PodInspectSheet(pod: pod, context: store.context)
        }
    }

    /// Consumes a pending "Show pods" request from a Findings-tab finding
    /// (`FindingCard.showPods()` in LgtmView.swift) by scrolling that
    /// component's card into view - the same thing `handleGraphSelect` does
    /// for a graph-node tap. `onAppear` covers "switched to this tab because
    /// of the tap" (the common case, since the switch itself constructs a
    /// fresh `LgtmClusterView`); `onChange` is a defensive second path in
    /// case SwiftUI ever reuses this view's identity across the tab switch.
    private func consumeScrollTarget(rows: [LgtmClusterComponentRow], proxy: ScrollViewProxy) {
        guard let title = scrollToComponentTitle else { return }
        scrollToComponentTitle = nil
        handleGraphSelect(title, rows: rows, proxy: proxy)
    }

    /// Join key for both the per-component aggregate usage in `buildRows()`
    /// and the per-pod bars on each pod card.
    private func metricsByPodKey() -> [String: PodMetrics] {
        Dictionary(store.podMetrics.map { ("\($0.namespace)/\($0.name)", $0) }, uniquingKeysWith: { _, last in last })
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No LGTM workloads found").font(.headline)
            Text("Expected Deployments/StatefulSets/DaemonSets with mimir/loki/tempo/grafana/alloy/pyroscope in the name.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Row construction

    /// One card per classified (or, pre-classification, heuristically grouped)
    /// workload, joined to its live pods. `report != nil` always wins even if
    /// it classified zero components — that's a real answer from kubectl-lgtm
    /// (e.g. a namespace-scoped run that found nothing), not a reason to guess.
    private func buildRows(metricsByPodKey: [String: PodMetrics]) -> [LgtmClusterComponentRow] {
        func usage(for pods: [Pod]) -> (cpu: Double, mem: Double) {
            pods.reduce(into: (0.0, 0.0)) { acc, pod in
                guard let m = metricsByPodKey[pod.id] else { return }
                acc.0 += m.cpuMillicores
                acc.1 += m.memoryBytes
            }
        }

        if let report {
            let deploymentsByKey = Dictionary(uniqueKeysWithValues: store.deployments.map { ("\($0.namespace)/\($0.name)", $0) })
            let statefulSetsByKey = Dictionary(uniqueKeysWithValues: store.statefulSets.map { ("\($0.namespace)/\($0.name)", $0) })
            let daemonSetsByKey = Dictionary(uniqueKeysWithValues: store.daemonSets.map { ("\($0.namespace)/\($0.name)", $0) })

            return report.components.map { component in
                let pods = store.pods.filter { LgtmClusterJoin.matches(pod: $0, component: component) }
                let key = "\(component.namespace)/\(component.name)"
                // Prefer live ready/desired over the report's — kubectl-lgtm's
                // classification pass can be minutes old (it's a 180s-timeout
                // subprocess), while these numbers come from the same 5s poll
                // as everything else on this tab.
                let live: (ready: Int, desired: Int)?
                switch component.kind {
                case "Deployment":  live = deploymentsByKey[key].map { ($0.ready, $0.desired) }
                case "StatefulSet": live = statefulSetsByKey[key].map { ($0.ready, $0.desired) }
                case "DaemonSet":   live = daemonSetsByKey[key].map { ($0.ready, $0.desired) }
                default:            live = nil
                }
                let u = usage(for: pods)
                return LgtmClusterComponentRow(
                    id: component.id, title: component.title, product: component.product, role: component.role,
                    namespace: component.namespace, kind: component.kind, stateful: component.stateful,
                    desired: live?.desired ?? component.replicas, ready: live?.ready ?? component.readyReplicas,
                    cpuRequestMillis: component.cpuRequestMillis, cpuLimitMillis: component.cpuLimitMillis,
                    memRequestBytes: component.memRequestBytes, memLimitBytes: component.memLimitBytes,
                    pods: pods, cpuUsedMillicoresTotal: u.cpu, memUsedBytesTotal: u.mem)
            }
        }

        // No classification yet: group directly off workload names already in
        // LgtmClusterStore. ponytail: the "role" shown here is just the workload's
        // full name (we have no real ingester/distributor/... label without
        // kubectl-lgtm) - it's replaced automatically the moment `report` lands.
        var rows: [LgtmClusterComponentRow] = []
        func product(for name: String) -> String? { Self.knownProducts.first { name.contains($0) } }
        func perPodRequests(_ pods: [Pod]) -> (cpuReq: Int, cpuLim: Int, memReq: Int, memLim: Int) {
            guard let sample = pods.first else { return (0, 0, 0, 0) }
            var cpuReq = 0.0, cpuLim = 0.0, memReq = 0.0, memLim = 0.0
            for c in sample.spec?.containers ?? [] {
                cpuReq += ResourceParser.cpuToMillicores(c.resources?.requests?["cpu"] ?? "0")
                cpuLim += ResourceParser.cpuToMillicores(c.resources?.limits?["cpu"] ?? "0")
                memReq += ResourceParser.memoryToBytes(c.resources?.requests?["memory"] ?? "0")
                memLim += ResourceParser.memoryToBytes(c.resources?.limits?["memory"] ?? "0")
            }
            return (Int(cpuReq), Int(cpuLim), Int(memReq), Int(memLim))
        }

        for d in store.deployments {
            guard let p = product(for: d.name) else { continue }
            let pods = store.pods.filter { $0.namespace == d.namespace && $0.name.hasPrefix(d.name + "-") }
            let req = perPodRequests(pods)
            let u = usage(for: pods)
            rows.append(LgtmClusterComponentRow(
                id: "\(d.namespace)/\(d.name)", title: "\(d.namespace)/\(d.name)", product: p, role: d.name, namespace: d.namespace,
                kind: "Deployment", stateful: false, desired: d.desired, ready: d.ready,
                cpuRequestMillis: req.cpuReq, cpuLimitMillis: req.cpuLim,
                memRequestBytes: req.memReq, memLimitBytes: req.memLim,
                pods: pods, cpuUsedMillicoresTotal: u.cpu, memUsedBytesTotal: u.mem))
        }
        for s in store.statefulSets {
            guard let p = product(for: s.name) else { continue }
            let pods = store.pods.filter { $0.namespace == s.namespace && $0.name.hasPrefix(s.name + "-") }
            let req = perPodRequests(pods)
            let u = usage(for: pods)
            rows.append(LgtmClusterComponentRow(
                id: "\(s.namespace)/\(s.name)", title: "\(s.namespace)/\(s.name)", product: p, role: s.name, namespace: s.namespace,
                kind: "StatefulSet", stateful: true, desired: s.desired, ready: s.ready,
                cpuRequestMillis: req.cpuReq, cpuLimitMillis: req.cpuLim,
                memRequestBytes: req.memReq, memLimitBytes: req.memLim,
                pods: pods, cpuUsedMillicoresTotal: u.cpu, memUsedBytesTotal: u.mem))
        }
        for ds in store.daemonSets {
            guard let p = product(for: ds.name) else { continue }
            let pods = store.pods.filter { $0.namespace == ds.namespace && $0.name.hasPrefix(ds.name + "-") }
            let req = perPodRequests(pods)
            let u = usage(for: pods)
            rows.append(LgtmClusterComponentRow(
                id: "\(ds.namespace)/\(ds.name)", title: "\(ds.namespace)/\(ds.name)", product: p, role: ds.name, namespace: ds.namespace,
                kind: "DaemonSet", stateful: false, desired: ds.desired, ready: ds.ready,
                cpuRequestMillis: req.cpuReq, cpuLimitMillis: req.cpuLim,
                memRequestBytes: req.memReq, memLimitBytes: req.memLim,
                pods: pods, cpuUsedMillicoresTotal: u.cpu, memUsedBytesTotal: u.mem))
        }
        return rows
    }

    private func uniquePods(_ rows: [LgtmClusterComponentRow]) -> [Pod] {
        var seen = Set<String>()
        var out: [Pod] = []
        for pod in rows.flatMap(\.pods) where seen.insert(pod.id).inserted {
            out.append(pod)
        }
        return out
    }

    private func troublePods(_ rows: [LgtmClusterComponentRow]) -> [Pod] {
        uniquePods(rows)
            .filter { !LgtmClusterJoin.troubleReasons($0, highRestartThreshold: Self.highRestartThreshold).isEmpty }
            .sorted { $0.name < $1.name }
    }

    private func productOrder(_ rows: [LgtmClusterComponentRow]) -> [String] {
        let present = Set(rows.map(\.product))
        let known = Self.knownProducts.filter { present.contains($0) }
        let extra = present.subtracting(Self.knownProducts).sorted()
        return known + extra
    }

    // MARK: - Sections

    private func summarySection(_ rows: [LgtmClusterComponentRow]) -> some View {
        let pods = uniquePods(rows)
        let products = Set(rows.map(\.product))
        let notReady = pods.filter { $0.healthState != .ok }.count
        let restarting = pods.filter { $0.restarts > 0 }.count
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                StatCard(label: "Products", value: "\(products.count)",
                         icon: "shippingbox.and.arrow.backward", color: .indigo)
                StatCard(label: "Components", value: "\(rows.count)",
                         icon: "square.grid.2x2", color: .blue)
                StatCard(label: "Pods", value: "\(pods.count)", icon: "shippingbox", color: .cyan)
                StatCard(label: "Not Ready", value: "\(notReady)",
                         icon: "exclamationmark.triangle.fill", color: notReady > 0 ? .red : .secondary)
                StatCard(label: "Restarting", value: "\(restarting)",
                         icon: "arrow.clockwise", color: restarting > 0 ? .orange : .secondary)
            }
            if !store.metricsAvailable {
                Text("metrics-server unavailable - live CPU/Mem hidden, requests and limits still shown")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func troubleSection(_ pods: [Pod]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Needs Attention", trailing: "\(pods.count) pods")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(pods) { pod in
                    let reasons = LgtmClusterJoin.troubleReasons(pod, highRestartThreshold: Self.highRestartThreshold)
                    Button {
                        inspecting = pod
                    } label: {
                        UnhealthyCard(item: UnhealthyItem(kind: "Pod", namespace: pod.namespace,
                                                           name: pod.name, reason: reasons.joined(separator: ", ")))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func productSection(product: String, rows: [LgtmClusterComponentRow],
                                 podMetricsByID: [String: PodMetrics]) -> some View {
        let sorted = rows.sorted { $0.role < $1.role }
        let totalPods = sorted.reduce(0) { $0 + $1.pods.count }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: product.capitalized, trailing: "\(sorted.count) components - \(totalPods) pods")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                ForEach(sorted) { row in
                    LgtmClusterComponentCard(row: row, metricsAvailable: store.metricsAvailable,
                                              podMetricsByID: podMetricsByID, context: store.context,
                                              inspecting: $inspecting)
                        .id(row.id)  // scroll target for graph-node taps, see handleGraphSelect
                }
            }
        }
    }

    // MARK: - Data-flow graph

    private func graphSection(product: String, rows: [LgtmClusterComponentRow], report: LgtmReport,
                               proxy: ScrollViewProxy, podMetricsByID: [String: PodMetrics]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "\(product.capitalized) - Data Flow", trailing: nil)
            LgtmGraphView(product: product,
                          nodes: graphNodes(for: product, rows: rows, report: report, podMetricsByID: podMetricsByID),
                          edges: LgtmTopology.edges(for: product)) { id in
                handleGraphSelect(id, rows: rows, proxy: proxy)
            }
        }
    }

    /// A node id is a graph pick - scrolls that component's card into view.
    /// Every pod is always visible below it already (see
    /// `LgtmClusterComponentCard`), so there's nothing to expand.
    private func handleGraphSelect(_ id: String, rows: [LgtmClusterComponentRow], proxy: ScrollViewProxy) {
        guard let row = rows.first(where: { $0.title == id }) else { return }
        withAnimation { proxy.scrollTo(row.id, anchor: .top) }
    }

    /// Builds the node set for one product's flow graph from live state:
    /// every role the topology expects (from the edge endpoints - the
    /// topology exposes no other way to enumerate a product's roles), unioned
    /// with every component this cluster actually has classified under that
    /// product, so a real workload the topology doesn't know about still
    /// renders (as a standalone-lane node) instead of silently disappearing.
    private func graphNodes(for product: String, rows: [LgtmClusterComponentRow], report: LgtmReport,
                             podMetricsByID: [String: PodMetrics]) -> [LgtmGraphNode] {
        let rowsByComponentID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let actual = Dictionary(uniqueKeysWithValues: report.components.filter { $0.product == product }
            .map { ($0.title, $0) })
        let expected = Set(LgtmTopology.edges(for: product).flatMap { [$0.from, $0.to] })

        return expected.union(actual.keys).sorted().map { title in
            guard let component = actual[title] else {
                // The topology expects this role but the cluster has no such
                // workload - a gap in the data path, worth showing as-is.
                let role = title.split(separator: "/", maxSplits: 1).last.map(String.init) ?? title
                return LgtmGraphNode(id: title, label: role.capitalized, detail: "not present",
                                      lane: LgtmTopology.lane(product: product, role: role),
                                      level: .unknown, saturation: nil, present: false)
            }
            let row = rowsByComponentID[component.id]
            let pods = row?.pods ?? []
            // Live ready/desired over the report's, same preference buildRows()
            // already applies for the cards - the report can be a couple
            // seconds stale next to this poll.
            let ready = row?.ready ?? component.readyReplicas
            let desired = row?.desired ?? component.replicas
            // Ceiling is limit-else-request, same convention as the card's own
            // `ceilingCpu`/`ceilingMem` - live-verified against the real
            // cluster this was built against: mimir/ingester and
            // mimir/store-gateway both ship with cpuLimitMillis=0 (CPU is
            // requested, never limited, the usual Kubernetes pattern for a
            // compressible resource), so a strict "only a real limit counts"
            // reading would leave CPU saturation permanently nil on exactly
            // the components where the live imbalance actually is.
            let cpuCeiling = component.cpuLimitMillis > 0 ? Double(component.cpuLimitMillis) : Double(component.cpuRequestMillis)
            let memCeiling = component.memLimitBytes > 0 ? Double(component.memLimitBytes) : Double(component.memRequestBytes)
            // Per replica, not per component total: `saturation` (typical)
            // and `peakReplicaSaturation` (busiest) both come from the same
            // set of individual pod ratios, computed straight from live
            // `store.podMetrics` - never from `LgtmUsage`'s history fields,
            // which are metrics-store-backed and would defeat the one thing
            // this tab guarantees (it keeps working when Mimir is down).
            // Pods with no metrics reading yet are simply absent from the
            // set rather than counted as 0 - see `replicaSaturation`.
            let perPodSaturation: [Double] = store.metricsAvailable
                ? pods.compactMap { pod -> Double? in
                    guard let m = podMetricsByID["\(pod.namespace)/\(pod.name)"] else { return nil }
                    return LgtmClusterJoin.replicaSaturation(cpu: m.cpuMillicores, mem: m.memoryBytes,
                                                              cpuCeiling: cpuCeiling, memCeiling: memCeiling)
                  }
                : []
            let satPair = LgtmClusterJoin.typicalAndPeakSaturation(perPodSaturation)
            return LgtmGraphNode(
                id: title, label: component.role.capitalized,
                detail: LgtmClusterJoin.graphDetail(pods: pods, ready: ready, desired: desired),
                lane: LgtmTopology.lane(product: product, role: component.role),
                level: LgtmClusterJoin.graphLevel(pods: pods, ready: ready, desired: desired),
                saturation: satPair?.typical, peakReplicaSaturation: satPair?.peak, present: true)
        }
    }

    private func nodePlacementSection(_ rows: [LgtmClusterComponentRow]) -> some View {
        let placement = nodePlacement(rows)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Node Placement", trailing: "\(placement.count) nodes")
            VStack(spacing: 6) {
                ForEach(placement) { LgtmClusterNodePlacementRow(row: $0) }
                if placement.isEmpty {
                    Text("No scheduled pods").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func nodePlacement(_ rows: [LgtmClusterComponentRow]) -> [LgtmClusterNodePlacement] {
        var byNode: [String: [String: Int]] = [:]
        for row in rows {
            for pod in row.pods {
                let node = pod.spec?.nodeName ?? "(unscheduled)"
                byNode[node, default: [:]][row.product, default: 0] += 1
            }
        }
        return byNode.map { node, counts in
            LgtmClusterNodePlacement(node: node, podCount: counts.values.reduce(0, +),
                                      productCounts: counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
        }
        .sorted { $0.podCount > $1.podCount }
    }
}

// MARK: - Data

/// One workload, live-joined to its pods. Either built from a real
/// `LgtmComponent` (role/kind/resources from the report; ready/desired
/// preferring live data) or from a bare name match before classification
/// lands - see `LgtmClusterView.buildRows()`.
private struct LgtmClusterComponentRow: Identifiable {
    let id: String
    /// `LgtmComponent.title` (or, pre-classification, a stand-in of the same
    /// shape) - the join key back from a graph node id to this row.
    let title: String
    let product: String
    let role: String
    let namespace: String
    let kind: String
    let stateful: Bool
    let desired: Int
    let ready: Int
    let cpuRequestMillis: Int
    let cpuLimitMillis: Int
    let memRequestBytes: Int
    let memLimitBytes: Int
    let pods: [Pod]
    let cpuUsedMillicoresTotal: Double
    let memUsedBytesTotal: Double
}

private struct LgtmClusterNodePlacement: Identifiable {
    let node: String
    let podCount: Int
    let productCounts: [(product: String, count: Int)]
    var id: String { node }
}

// MARK: - Pure join / health logic (kept free of SwiftUI + LgtmClusterStore so `selfCheck` can exercise it directly)

enum LgtmClusterJoin {
    /// True if `pod` belongs to `component`. Namespace is checked first - a
    /// `podPattern` alone could false-positive across namespaces that reuse
    /// role names like "distributor" - then the regex, falling back to a
    /// name-prefix match for a report produced before `podPattern` existed
    /// (or for the pre-classification fallback grouping, which never sets one).
    static func matches(pod: Pod, component: LgtmComponent) -> Bool {
        guard pod.namespace == component.namespace else { return false }
        if let pattern = component.podPattern, !pattern.isEmpty,
           let re = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(pod.name.startIndex..., in: pod.name)
            return re.firstMatch(in: pod.name, range: range) != nil
        }
        return pod.name == component.name || pod.name.hasPrefix(component.name + "-")
    }

    /// Reasons this pod belongs in "Needs Attention", independent of which
    /// product/role it's classified under. Empty means healthy. `lastState`
    /// is what's modelled for OOMKilled - there's no "why did it last
    /// restart" beyond that in `K8sModels.swift` today.
    static func troubleReasons(_ pod: Pod, highRestartThreshold: Int) -> [String] {
        var reasons: [String] = []
        if let r = pod.failureReason { reasons.append(r) }          // CrashLoopBackOff, ImagePullBackOff, Evicted, ...
        if pod.phase == "Pending" { reasons.append("Pending") }
        if pod.restarts >= highRestartThreshold { reasons.append("\(pod.restarts) restarts") }
        if podIsOOMKilled(pod) { reasons.append("OOMKilled") }
        return reasons
    }

    /// `lastState` is what's modelled for OOMKilled - there's no "why did it
    /// last restart" beyond that in `K8sModels.swift` today.
    static func podIsOOMKilled(_ pod: Pod) -> Bool {
        (pod.status?.containerStatuses ?? []).contains { $0.lastState?.terminated?.reason == "OOMKilled" }
    }

    // MARK: - Flow-graph node derivation (pure - see LgtmClusterView.graphNodes)

    /// `.unknown` when `desired == 0` - nothing scheduled under this role, so
    /// there's no basis to judge it. Otherwise `.critical` for anything down
    /// (fewer pods than desired, zero ready, a failing container state, or an
    /// OOMKill), `.warn` for a component that's up but not fully healthy
    /// (under-replicated or churning restarts), `.ok` otherwise.
    static func graphLevel(pods: [Pod], ready: Int, desired: Int) -> LgtmNodeLevel {
        guard desired > 0 else { return .unknown }
        if pods.isEmpty || ready == 0 { return .critical }  // desired>0 but nothing is running at all
        if pods.contains(where: { $0.isFailing }) { return .critical }
        if pods.contains(where: { podIsOOMKilled($0) }) { return .critical }
        if ready < desired { return .warn }
        if pods.contains(where: { $0.restarts > 0 }) { return .warn }
        return .ok
    }

    /// "3/3 ready" or, with something wrong, "2/3 ready, 1 crashlooping".
    static func graphDetail(pods: [Pod], ready: Int, desired: Int) -> String {
        var parts = ["\(ready)/\(desired) ready"]
        let crashlooping = pods.filter { $0.failureReason == "CrashLoopBackOff" }.count
        if crashlooping > 0 { parts.append("\(crashlooping) crashlooping") }
        let oomed = pods.filter { podIsOOMKilled($0) }.count
        if oomed > 0 { parts.append("\(oomed) OOMKilled") }
        return parts.joined(separator: ", ")
    }

    /// One replica's own saturation: the max of its CPU-vs-ceiling and
    /// Mem-vs-ceiling ratio - "whichever is higher" is the point, a pod
    /// pinned on memory but idle on CPU (or vice versa) must still read as
    /// saturated. `nil` only when there's no ceiling at all to measure either
    /// resource against - never a divide that could produce NaN. Not
    /// clamped - see `typicalAndPeakSaturation`: this tab reports raw
    /// measured ratios all the way to the renderer, which owns clamping for
    /// its own geometry.
    static func replicaSaturation(cpu: Double, mem: Double, cpuCeiling: Double, memCeiling: Double) -> Double? {
        let cpuRatio = cpuCeiling > 0 ? cpu / cpuCeiling : nil
        let memRatio = memCeiling > 0 ? mem / memCeiling : nil
        switch (cpuRatio, memRatio) {
        case let (c?, m?): return max(c, m)
        case let (c?, nil): return c
        case let (nil, m?): return m
        case (nil, nil):    return nil
        }
    }

    /// The graph's two saturation numbers for a component: `typical` (the
    /// median replica) and `peak` (the single busiest one). Median over mean:
    /// with the 2-3 replicas typical of this stack a mean is barely more than
    /// the midpoint between two numbers, while a median actually resists one
    /// hot or one idle outlier dragging "typical" toward it - exactly what a
    /// mean would do with this few samples.
    ///
    /// Neither value is clamped here - this tab's whole principle is
    /// reporting what was measured, not what it rounds down to. The renderer
    /// clamps for its own bar geometry and reports the raw figure in text;
    /// clamping here first would have been the bug that made a replica
    /// measured at 198% of its ceiling display as "100%". Live-verified on
    /// mimir/store-gateway (two pods, no CPU limit, a 250m request-only
    /// ceiling) at 494m/361m - 198%/144% of that ceiling, both already over
    /// 100% *before* being compared to each other: clamping first would make
    /// them numerically identical and silently swallow the exact "one copy is
    /// doing all the work" signal this field exists to show. `peak` comes
    /// back `nil` whenever it wouldn't add information - no data, one
    /// replica, or every replica equally loaded (peak == median): a tick
    /// sitting exactly on the fill would read as a rendering bug, not "no
    /// imbalance".
    static func typicalAndPeakSaturation(_ values: [Double]) -> (typical: Double, peak: Double?)? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        let peak = sorted[n - 1]
        return (median, peak > median ? peak : nil)
    }

    /// Min/max usage-vs-ceiling ratio across a component's pods that have a
    /// live metrics reading - "these three are at 40/45/95%". A measured
    /// spread, not a judgment: it reports how far apart the busiest and
    /// quietest pod are, it does not say whether that's fine - that call
    /// belongs to the Findings tab. `nil` when there's no ceiling to measure
    /// against or fewer than two pods have data (a spread needs two points).
    /// Not clamped to 100% - an overshoot past the ceiling is itself a fact.
    static func spreadPercent(usedValues: [Double], ceiling: Double) -> (min: Double, max: Double)? {
        guard ceiling > 0, usedValues.count >= 2 else { return nil }
        let percentages = usedValues.map { $0 / ceiling }
        guard let lo = percentages.min(), let hi = percentages.max() else { return nil }
        return (lo, hi)
    }
}

// MARK: - Card views

private struct LgtmClusterComponentCard: View {
    let row: LgtmClusterComponentRow
    let metricsAvailable: Bool
    /// Keyed by "namespace/name" - the per-pod bars below, and the spread facts.
    let podMetricsByID: [String: PodMetrics]
    let context: String
    /// Threaded from `LgtmClusterView` - tapping a pod card sets this instead
    /// of pushing a nav-stack route, since this app has no nav stack to push.
    @Binding var inspecting: Pod?

    private var readyColor: Color {
        row.desired == 0 ? .secondary : (row.ready == row.desired ? .green : .orange)
    }
    private var ceilingCpu: Double { row.cpuLimitMillis > 0 ? Double(row.cpuLimitMillis) : Double(row.cpuRequestMillis) }
    private var ceilingMem: Double { row.memLimitBytes > 0 ? Double(row.memLimitBytes) : Double(row.memRequestBytes) }
    /// Which configured value the ceiling above actually is - shown alongside
    /// every bar/spread so "94% of what" is never left ambiguous. Several LGTM
    /// components (mimir/ingester, mimir/store-gateway on the cluster this was
    /// built against) ship with no CPU limit at all, request-only.
    private var cpuCeilingKind: String { row.cpuLimitMillis > 0 ? "limit" : (row.cpuRequestMillis > 0 ? "request" : "") }
    private var memCeilingKind: String { row.memLimitBytes > 0 ? "limit" : (row.memRequestBytes > 0 ? "request" : "") }

    private func usedValues(_ pick: (PodMetrics) -> Double) -> [Double] {
        guard metricsAvailable else { return [] }
        return row.pods.compactMap { podMetricsByID["\($0.namespace)/\($0.name)"].map(pick) }
    }
    private var cpuSpread: (min: Double, max: Double)? {
        LgtmClusterJoin.spreadPercent(usedValues: usedValues { $0.cpuMillicores }, ceiling: ceilingCpu)
    }
    private var memSpread: (min: Double, max: Double)? {
        LgtmClusterJoin.spreadPercent(usedValues: usedValues { $0.memoryBytes }, ceiling: ceilingMem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(readyColor).frame(width: 7, height: 7)
                if row.stateful {
                    Image(systemName: "cylinder.split.1x2").font(.caption2).foregroundStyle(.mint)
                        .help("Stateful")
                }
                Text(row.role)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(row.kind).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                // Pod count and ready/desired are independent facts and can
                // legitimately disagree mid-rollout (old + new ReplicaSet pods
                // both live at once) - both are shown as measured, not reconciled.
                mini("Ready", "\(row.ready)/\(row.desired)", tint: readyColor)
                mini("Pods", "\(row.pods.count)")
                mini("Namespace", row.namespace)
            }
            reqLimitLine
            if let cpuSpread { spreadLine(label: "CPU", spread: cpuSpread, kind: cpuCeilingKind) }
            if let memSpread { spreadLine(label: "Mem", spread: memSpread, kind: memCeilingKind) }
            if row.pods.isEmpty {
                Text("No matching pods found").font(.caption2).foregroundStyle(.secondary)
            } else {
                // Every pod, always visible - no disclosure, no averaging.
                // Component grouping (this card) is the only aggregation; who
                // is actually carrying the load is the point of this tab.
                Text("\(row.pods.count) pod\(row.pods.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], spacing: 8) {
                    ForEach(row.pods.sorted { $0.name < $1.name }) { pod in
                        Button {
                            inspecting = pod
                        } label: {
                            ResourceCard(ref: .pod(pod.namespace, pod.name), navigable: true, context: context) {
                                LgtmPodUsageCardBody(
                                    pod: pod,
                                    metrics: metricsAvailable ? podMetricsByID["\(pod.namespace)/\(pod.name)"] : nil,
                                    ceilingCpu: ceilingCpu, ceilingMem: ceilingMem,
                                    cpuCeilingKind: cpuCeilingKind, memCeilingKind: memCeilingKind)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var reqLimitLine: some View {
        HStack(spacing: 14) {
            resourcePair(label: "req", cpu: row.cpuRequestMillis, mem: row.memRequestBytes)
            resourcePair(label: "limit", cpu: row.cpuLimitMillis, mem: row.memLimitBytes)
        }
    }

    private func resourcePair(label: String, cpu: Int, mem: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(ResourceParser.formatMillicores(Double(cpu))).font(.caption.monospacedDigit())
            Text("/").font(.caption2).foregroundStyle(.secondary)
            Text(ResourceParser.formatBytes(Double(mem))).font(.caption.monospacedDigit())
        }
    }

    /// "CPU per pod (vs limit): 40% - 95%" - the busiest-vs-quietest signal,
    /// stated plainly. One neutral colour throughout; the numbers are the fact.
    private func spreadLine(label: String, spread: (min: Double, max: Double), kind: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label) per pod\(kind.isEmpty ? "" : " (vs \(kind))"):")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(pct(spread.min)) - \(pct(spread.max))")
                .font(.caption.monospacedDigit())
        }
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func mini(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(tint ?? .primary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// The pod card body shown for every pod in a component - always, never
/// behind a disclosure. `PodCardBody` (`NamespaceDetailView.swift`,
/// `KubeViewKit` - a module this app cannot depend on) plus a live CPU/Mem
/// bar against the *component's* ceiling, which it lacks. This is the
/// number a component-level average would hide: three ingesters at
/// 40/45/95% average to a comfortable-looking 60%, and per-pod is the only
/// place the 95% one is visible - metrics history in LgtmMetricsView is
/// aggregated per component by the Go analyser, never per-pod, so live
/// metrics-server data (already in `LgtmClusterStore`) is the only source for this.
private struct LgtmPodUsageCardBody: View {
    let pod: Pod
    /// nil when metrics-server has no reading for this pod yet (just started)
    /// or metrics are unavailable cluster-wide - shown as "No metrics yet"
    /// rather than a bar at 0%, which would read as "idle" instead of "unknown".
    let metrics: PodMetrics?
    let ceilingCpu: Double
    let ceilingMem: Double
    let cpuCeilingKind: String
    let memCeilingKind: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ResourceTitle(ref: .pod(pod.namespace, pod.name), name: pod.name)
                Spacer()
                if pod.isLinkerdMeshed {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.pink).help("Linkerd meshed")
                }
                StatusBadge(text: pod.isFailing ? (pod.failureReason ?? pod.phase) : pod.phase,
                            color: pod.isFailing ? .red : PodCard.phaseColor(pod.phase))
            }
            HStack(spacing: 12) {
                mini("Ready", pod.readyRatio)
                mini("Restarts", "\(pod.restarts)", tint: pod.restarts > 0 ? .orange : nil)
            }
            if let metrics {
                if ceilingCpu > 0 {
                    LgtmFactBar(label: "CPU vs \(cpuCeilingKind)", used: metrics.cpuMillicores, total: ceilingCpu,
                                format: { ResourceParser.formatMillicores($0) })
                }
                if ceilingMem > 0 {
                    LgtmFactBar(label: "Mem vs \(memCeilingKind)", used: metrics.memoryBytes, total: ceilingMem,
                                format: { ResourceParser.formatBytes($0) })
                }
            } else if ceilingCpu > 0 || ceilingMem > 0 {
                Text("No metrics yet").font(.caption2).foregroundStyle(.secondary)
            }
            if let node = pod.spec?.nodeName {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.caption2).foregroundStyle(.secondary)
                    Text(node).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func mini(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(tint ?? .primary)
        }
    }
}

/// A usage-vs-ceiling bar for this tab only - deliberately not `UsageBar`
/// (`OverviewView.swift`, `KubeViewKit` - a module this app cannot depend on,
/// and shared app-wide there): that component grades its fill red/orange/green
/// past fixed percentage thresholds, which is exactly the interpretation this
/// tab must not make (Cluster/Metrics show what IS; only Findings judges it).
/// One neutral colour - the printed percentage is the fact, not the colour.
private struct LgtmFactBar: View {
    let label: String
    let used: Double
    let total: Double
    let format: (Double) -> String

    private var percent: Double { total > 0 ? used / total : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(format(used)) / \(format(total)) (\(Int((percent * 100).rounded()))%)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        // Clamped to the bar's own width only - an overshoot
                        // past the ceiling still reads correctly in the
                        // printed percentage above, it just can't paint past
                        // the rectangle it's filling.
                        .frame(width: geo.size.width * min(max(percent, 0), 1))
                }
            }
            .frame(height: 6)
        }
        .frame(minWidth: 140)
    }
}

private struct LgtmClusterNodePlacementRow: View {
    let row: LgtmClusterNodePlacement
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            Text(row.node)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(row.productCounts, id: \.product) { pc in
                    Text("\(pc.product.capitalized) x\(pc.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            Spacer()
            Text("\(row.podCount) pods").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Self-check

#if DEBUG
/// One runnable check over the pure logic in `LgtmClusterJoin` - the part of
/// this file with no SwiftUI/ClusterStore dependency, so it can be exercised
/// directly the way `ClusterStore.swift` and `LgtmService.swift` do theirs.
/// Not wired into a call site: this file may only add
/// `Views/LgtmClusterView.swift`, and every other file (including
/// `LgtmView.swift`, whose `init` would be the natural place) is out of lane.
/// Call `LgtmClusterViewSelfCheck.run()` from there (or app startup) to run it.
enum LgtmClusterViewSelfCheck {
    static func run() {
        let reportJSON = """
        {"version":"dev","generatedAt":"2026-08-20T15:38:21.796952Z","context":"c",
         "scope":"ns/observability","source":"mimir-nginx","windowSecs":1209600,
         "components":[
           {"name":"mimir-distributor","namespace":"observability","kind":"Deployment",
            "product":"mimir","role":"distributor","zone":"","title":"mimir/distributor",
            "podPattern":"^mimir-distributor-[a-z0-9-]+$",
            "replicas":3,"readyReplicas":3,"stateful":false,
            "cpuRequestMillis":500,"cpuLimitMillis":1000,
            "memRequestBytes":1073741824,"memLimitBytes":2147483648,
            "usage":{"memP99Bytes":1,"memMaxBytes":2,"cpuP99Millis":3,"throttleRatio":0,
                     "oomContainers":0,"restarts":0,"coverageSecs":1209600,"series":[]},
            "note":"","severity":"","findings":[]},
           {"name":"mimir-ingester","namespace":"observability","kind":"StatefulSet",
            "product":"mimir","role":"ingester","zone":"","title":"mimir/ingester",
            "podPattern":null,
            "replicas":1,"readyReplicas":1,"stateful":true,
            "cpuRequestMillis":500,"cpuLimitMillis":1000,
            "memRequestBytes":1073741824,"memLimitBytes":2147483648,
            "usage":{"memP99Bytes":1,"memMaxBytes":2,"cpuP99Millis":3,"throttleRatio":0,
                     "oomContainers":0,"restarts":0,"coverageSecs":1209600,"series":[]},
            "note":"","severity":"","findings":[]}
         ]}
        """
        guard let report = try? LgtmService.decode(Data(reportJSON.utf8)) else {
            assertionFailure("LgtmClusterViewSelfCheck: report fixture failed to decode - the --json contract moved")
            return
        }

        let matchedByRegex = testPod(namespace: "observability", name: "mimir-distributor-7d8f9-abcde")
        let wrongNamespace = testPod(namespace: "other", name: "mimir-distributor-7d8f9-abcde")
        let unrelated = testPod(namespace: "observability", name: "loki-distributor-abc")
        let matchedByPrefix = testPod(namespace: "observability", name: "mimir-ingester-0")

        assert(LgtmClusterJoin.matches(pod: matchedByRegex, component: report.components[0]))
        assert(!LgtmClusterJoin.matches(pod: wrongNamespace, component: report.components[0]))
        assert(!LgtmClusterJoin.matches(pod: unrelated, component: report.components[0]))
        assert(LgtmClusterJoin.matches(pod: matchedByPrefix, component: report.components[1]))  // no podPattern -> prefix fallback

        let crashing = testPod(namespace: "observability", name: "mimir-distributor-x", waitingReason: "CrashLoopBackOff")
        assert(LgtmClusterJoin.troubleReasons(crashing, highRestartThreshold: 5).contains("CrashLoopBackOff"))

        let flapping = testPod(namespace: "observability", name: "mimir-distributor-y", restartCount: 9)
        assert(LgtmClusterJoin.troubleReasons(flapping, highRestartThreshold: 5).contains("9 restarts"))

        let healthy = testPod(namespace: "observability", name: "mimir-distributor-z")
        assert(LgtmClusterJoin.troubleReasons(healthy, highRestartThreshold: 5).isEmpty)

        let oomed = testPod(namespace: "observability", name: "mimir-ingester-2", oomKilled: true)
        assert(LgtmClusterJoin.podIsOOMKilled(oomed))
        assert(LgtmClusterJoin.troubleReasons(oomed, highRestartThreshold: 5).contains("OOMKilled"))

        // graphLevel: unknown/critical/warn/ok, exercised in the order a real
        // rollout would move through them.
        assert(LgtmClusterJoin.graphLevel(pods: [], ready: 0, desired: 0) == .unknown)         // nothing scheduled under this role
        assert(LgtmClusterJoin.graphLevel(pods: [], ready: 0, desired: 3) == .critical)         // desired>0, zero pods = fully down
        assert(LgtmClusterJoin.graphLevel(pods: [healthy, healthy], ready: 2, desired: 3) == .warn)      // under-replicated
        assert(LgtmClusterJoin.graphLevel(pods: [crashing, healthy, healthy], ready: 2, desired: 3) == .critical) // a failing pod outranks "2/3 ready"
        assert(LgtmClusterJoin.graphLevel(pods: [oomed, healthy, healthy], ready: 3, desired: 3) == .critical)    // fully ready but one OOMKilled
        assert(LgtmClusterJoin.graphLevel(pods: [flapping, healthy, healthy], ready: 3, desired: 3) == .warn)     // fully ready, still churning restarts
        assert(LgtmClusterJoin.graphLevel(pods: [healthy, healthy, healthy], ready: 3, desired: 3) == .ok)

        // graphDetail
        assert(LgtmClusterJoin.graphDetail(pods: [healthy, healthy, healthy], ready: 3, desired: 3) == "3/3 ready")
        assert(LgtmClusterJoin.graphDetail(pods: [crashing, healthy], ready: 1, desired: 2) == "1/2 ready, 1 crashlooping")
        assert(LgtmClusterJoin.graphDetail(pods: [oomed], ready: 0, desired: 1) == "0/1 ready, 1 OOMKilled")

        // replicaSaturation: one pod's own max(cpu, mem) ratio against its ceiling.
        assert(LgtmClusterJoin.replicaSaturation(cpu: 900, mem: 200, cpuCeiling: 1000, memCeiling: 2000)
            .map { approx($0, 0.9) } == true)   // cpu wins
        assert(LgtmClusterJoin.replicaSaturation(cpu: 100, mem: 1900, cpuCeiling: 1000, memCeiling: 2000)
            .map { approx($0, 0.95) } == true)  // mem wins
        assert(LgtmClusterJoin.replicaSaturation(cpu: 100, mem: 100, cpuCeiling: 0, memCeiling: 0) == nil) // no ceiling on either
        // Deliberately not clamped here - a replica already over its ceiling
        // must still compare honestly against its siblings.
        assert(LgtmClusterJoin.replicaSaturation(cpu: 5000, mem: 0, cpuCeiling: 1000, memCeiling: 0)
            .map { approx($0, 5.0) } == true)

        // typicalAndPeakSaturation: median vs peak, and the nil cases that
        // matter - no data, one replica, and every replica equally loaded.
        assert(LgtmClusterJoin.typicalAndPeakSaturation([]) == nil)
        if let r = LgtmClusterJoin.typicalAndPeakSaturation([0.5]) {
            assert(approx(r.typical, 0.5) && r.peak == nil)   // one replica: nothing to compare against
        } else { assertionFailure("typicalAndPeakSaturation: expected a result, got nil") }
        if let r = LgtmClusterJoin.typicalAndPeakSaturation([0.5, 0.5, 0.5]) {
            assert(approx(r.typical, 0.5) && r.peak == nil)   // every replica equally loaded
        } else { assertionFailure("typicalAndPeakSaturation: expected a result, got nil") }
        if let r = LgtmClusterJoin.typicalAndPeakSaturation([0.4, 0.45, 0.95]) {  // odd count: median is the middle value
            assert(approx(r.typical, 0.45))
            assert(r.peak.map { approx($0, 0.95) } == true)
        } else { assertionFailure("typicalAndPeakSaturation: expected a result, got nil") }
        if let r = LgtmClusterJoin.typicalAndPeakSaturation([0.3, 0.9]) {  // even count: median is the midpoint
            assert(approx(r.typical, 0.6))
            assert(r.peak.map { approx($0, 0.9) } == true)
        } else { assertionFailure("typicalAndPeakSaturation: expected a result, got nil") }
        // mimir/store-gateway, live-verified: 494m/361m against a 250m
        // request-only ceiling (no CPU limit) - 1.976/1.444, both already
        // over 100% before comparing. Neither value is clamped: `typical`
        // reports the true median (171%, not rounded down to "100%"), and
        // `peak` (197.6%) stays genuinely distinct from it rather than both
        // collapsing to the same clamped 1.0 and hiding the imbalance.
        if let r = LgtmClusterJoin.typicalAndPeakSaturation([1.444, 1.976]) {
            assert(approx(r.typical, 1.71))
            assert(r.peak.map { approx($0, 1.976) } == true)
        } else { assertionFailure("typicalAndPeakSaturation: expected a result, got nil") }

        // spreadPercent: the "these three are at 40/45/95%" imbalance signal -
        // reports the raw spread, never a verdict on it.
        if let s = LgtmClusterJoin.spreadPercent(usedValues: [400, 450, 950], ceiling: 1000) {
            assert(approx(s.min, 0.4) && approx(s.max, 0.95))
        } else {
            assertionFailure("spreadPercent: expected a min/max, got nil")
        }
        assert(LgtmClusterJoin.spreadPercent(usedValues: [500], ceiling: 1000) == nil)   // one pod, nothing to spread
        assert(LgtmClusterJoin.spreadPercent(usedValues: [500, 600], ceiling: 0) == nil) // no ceiling to measure against
        // Not clamped: a pod past its ceiling is a fact this reports, not hides.
        if let s = LgtmClusterJoin.spreadPercent(usedValues: [500, 1500], ceiling: 1000) {
            assert(approx(s.min, 0.5) && approx(s.max, 1.5))
        } else {
            assertionFailure("spreadPercent: expected a min/max, got nil")
        }
    }

    private static func approx(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 0.0001
    }

    private static func testPod(namespace: String, name: String, phase: String = "Running",
                                 waitingReason: String? = nil, restartCount: Int = 0, oomKilled: Bool = false) -> Pod {
        let statusJSON: String
        if let waitingReason {
            statusJSON = """
            {"phase":"\(phase)","containerStatuses":[{"name":"c","ready":false,"restartCount":\(restartCount),
              "state":{"waiting":{"reason":"\(waitingReason)"}}}]}
            """
        } else if oomKilled {
            statusJSON = """
            {"phase":"\(phase)","containerStatuses":[{"name":"c","ready":true,"restartCount":\(restartCount),
              "lastState":{"terminated":{"reason":"OOMKilled"}}}]}
            """
        } else {
            statusJSON = """
            {"phase":"\(phase)","containerStatuses":[{"name":"c","ready":true,"restartCount":\(restartCount)}]}
            """
        }
        let json = """
        {"metadata":{"name":"\(name)","namespace":"\(namespace)"},
         "status":\(statusJSON),
         "spec":{"containers":[{"name":"c","image":"x"}]}}
        """
        // swiftlint:disable:next force_try - fixture literal, a decode failure here is a test bug worth crashing on
        return try! JSONDecoder().decode(Pod.self, from: Data(json.utf8))
    }
}
#endif
