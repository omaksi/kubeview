import SwiftUI
import KubeModel
import KubeClient
import KubeUI

enum NamespaceSort {
    /// Starred first, then by pod count descending (empty namespaces last),
    /// then alphabetical within each bucket.
    @MainActor
    static func sorted(_ items: [NamespaceSummary], stars: StarStore) -> [NamespaceSummary] {
        items.sorted { a, b in
            let sa = stars.isStarred(a.name), sb = stars.isStarred(b.name)
            if sa != sb { return sa }
            let ea = a.podCount == 0, eb = b.podCount == 0
            if ea != eb { return !ea }
            return a.name < b.name
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState

    var body: some View {
        if search.isActive {
            GlobalSearchResultsView()
        } else if store.isFirstLoad {
            LoadingPlaceholder(label: "cluster", activity: store.activity, activitySince: store.activitySince)
        } else {
            dashboard
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statCards
                if !store.unhealthyAll.isEmpty {
                    unhealthySection
                }
                nodesSection
                namespacesSection
            }
            .padding()
        }
    }

    private var unhealthySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Unhealthy", trailing: "\(store.unhealthyAll.count) items")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(store.unhealthyAll) { item in UnhealthyCard(item: item) }
            }
        }
    }

    private var statCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            StatCard(label: "Context", value: store.context,
                     icon: "point.3.connected.trianglepath.dotted", color: .blue)
            StatCard(label: "Kubernetes", value: store.serverVersion ?? "—",
                     icon: "shippingbox.and.arrow.backward", color: .indigo)
            StatCard(label: "Nodes Ready", value: "\(store.nodesReady)/\(store.nodes.count)",
                     icon: "server.rack", color: store.nodesReady == store.nodes.count ? .green : .orange)
            StatCard(label: "Namespaces", value: "\(store.namespaces.count)",
                     icon: "square.stack.3d.up", color: .blue)
            StatCard(label: "Pods Running", value: "\(store.podsRunning)",
                     icon: "shippingbox", color: .green)
            StatCard(label: "Pods Failing", value: "\(store.podsFailing)",
                     icon: "exclamationmark.triangle.fill",
                     color: store.podsFailing > 0 ? .red : .secondary)
            StatCard(label: "Ingresses", value: "\(store.ingresses.count)",
                     icon: "network", color: .purple)
        }
    }

    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Nodes", trailing: store.metricsAvailable ? nil : "metrics-server unavailable")

            if store.metricsAvailable {
                clusterTotals
            }

            VStack(spacing: 6) {
                ForEach(store.nodeUsage) { node in
                    NodeUsageRow(node: node, showMetrics: store.metricsAvailable)
                }
                if store.nodeUsage.isEmpty {
                    Text("No nodes").foregroundStyle(.secondary).font(.caption)
                }
            }
        }
    }

    private var clusterTotals: some View {
        HStack(spacing: 16) {
            UsageBar(label: "Cluster CPU",
                     used: store.clusterCpuUsedMillicores,
                     total: store.clusterCpuCapacityMillicores,
                     format: { ResourceParser.formatMillicores($0) })
            UsageBar(label: "Cluster Memory",
                     used: store.clusterMemoryUsedBytes,
                     total: store.clusterMemoryCapacityBytes,
                     format: { ResourceParser.formatBytes($0) })
        }
    }

    @EnvironmentObject var stars: StarStore

    private var namespacesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Namespaces", trailing: "\(store.namespaces.count) total")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(NamespaceSort.sorted(store.namespaceSummaries, stars: stars)) { ns in
                    NamespaceCard(ns: ns, metricsAvailable: store.metricsAvailable)
                }
            }
        }
    }
}

struct NodeUsageRow: View {
    let node: NodeUsage
    let showMetrics: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(node.ready ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(node.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)

            if showMetrics {
                UsageBar(label: "CPU",
                         used: node.cpuUsedMillicores,
                         total: node.cpuCapacityMillicores,
                         format: { ResourceParser.formatMillicores($0) })
                UsageBar(label: "Mem",
                         used: node.memoryUsedBytes,
                         total: node.memoryCapacityBytes,
                         format: { ResourceParser.formatBytes($0) })
            } else {
                Text("CPU cap: \(ResourceParser.formatMillicores(node.cpuCapacityMillicores))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Mem cap: \(ResourceParser.formatBytes(node.memoryCapacityBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct UsageBar: View {
    let label: String
    let used: Double
    let total: Double
    let format: (Double) -> String

    var percent: Double { total > 0 ? min(used / total, 1.0) : 0 }
    var color: Color {
        if percent > 0.85 { return .red }
        if percent > 0.65 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(format(used)) / \(format(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * percent)
                }
            }
            .frame(height: 6)
        }
        .frame(minWidth: 140)
    }
}

struct NamespaceCard: View {
    let ns: NamespaceSummary
    let metricsAvailable: Bool
    @EnvironmentObject var emojis: EmojiStore
    @EnvironmentObject var stars: StarStore
    @EnvironmentObject var store: ClusterStore

    private var isEmpty: Bool { ns.podCount == 0 }

    var body: some View {
        NavigationLink(value: AppRoute.namespace(NamespaceRoute(name: ns.name))) {
            ResourceCard(ref: .namespace(ns.name), navigable: true, dimmed: isEmpty, context: store.context) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ResourceTitle(ref: .namespace(ns.name), name: ns.name,
                                      font: .system(.headline, design: .monospaced))
                        Spacer()
                        if ns.unhealthyCount > 0 {
                            Label("\(ns.unhealthyCount)", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(ns.failingCount > 0 ? .red : .orange)
                                .font(.caption)
                        }
                        Button {
                            stars.toggle(ns.name)
                        } label: {
                            Image(systemName: stars.isStarred(ns.name) ? "star.fill" : "star")
                                .font(.caption)
                                .foregroundStyle(stars.isStarred(ns.name) ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(stars.isStarred(ns.name) ? "Unstar" : "Star this namespace")
                    }
                    if !ns.unhealthyWorkloads.isEmpty || ns.failingCount > 0 {
                        unhealthyList
                    }
                    HStack(spacing: 12) {
                        counter("Pods", "\(ns.runningCount)/\(ns.podCount)")
                        counter("Ingresses", "\(ns.ingressCount)")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        resourceLine(label: "CPU",
                                     used: metricsAvailable ? ResourceParser.formatMillicores(ns.cpuUsedMillicores) : "—",
                                     req: ResourceParser.formatMillicores(ns.cpuRequestedMillicores))
                        resourceLine(label: "Mem",
                                     used: metricsAvailable ? ResourceParser.formatBytes(ns.memoryUsedBytes) : "—",
                                     req: ResourceParser.formatBytes(ns.memoryRequestedBytes))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var unhealthyList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ns.unhealthyWorkloads.prefix(3)) { w in
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                    Text("\(w.kind)/\(w.name)")
                        .font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(w.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if ns.unhealthyWorkloads.count > 3 {
                Text("+\(ns.unhealthyWorkloads.count - 3) more")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func counter(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func resourceLine(label: String, used: String, req: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Text("used \(used)").font(.caption.monospacedDigit())
            Spacer()
            Text("req \(req)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
