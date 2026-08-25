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

    /// Nodes shown before the list collapses. The overview is a summary and
    /// NodesView holds the full list, so a cluster with dozens of nodes must
    /// not push the namespace grid off the screen.
    private static let collapsedNodeCount = 12
    @State private var showAllNodes = false

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

    /// Not-ready nodes are never collapsed away. Hiding a broken node behind a
    /// "show more" is the one thing this panel must not do, so the cap only
    /// ever trims healthy ones.
    private var visibleNodes: [NodeUsage] {
        if showAllNodes { return store.nodeUsage }
        let unready = store.nodeUsage.filter { !$0.ready }
        let ready = store.nodeUsage.filter(\.ready)
        return unready + ready.prefix(max(0, Self.collapsedNodeCount - unready.count))
    }

    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Nodes",
                          trailing: store.metricsAvailable
                              ? "\(store.nodesReady)/\(store.nodes.count) ready"
                              : "metrics-server unavailable")

            if store.metricsAvailable {
                clusterTotals
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                ForEach(visibleNodes) { node in
                    NodeUsageRow(node: node, showMetrics: store.metricsAvailable)
                }
            }
            if store.nodeUsage.isEmpty {
                Text("No nodes").foregroundStyle(.secondary).font(.caption)
            }
            if store.nodeUsage.count > Self.collapsedNodeCount {
                Button(showAllNodes ? "Show fewer" : "Show all \(store.nodeUsage.count) nodes") {
                    withAnimation(.easeInOut(duration: 0.15)) { showAllNodes.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
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

/// Deliberately compact: the overview shows every node at once, so each gets a
/// name line and two thin bars rather than `UsageBar`'s label + "used / total"
/// pair, which is what made this section taller than everything below it.
/// NodesView is where the full per-node detail lives.
struct NodeUsageRow: View {
    let node: NodeUsage
    let showMetrics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(node.ready ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(node.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.name)
                Spacer(minLength: 0)
            }

            if showMetrics {
                MiniUsageBar(label: "CPU", percent: node.cpuPercent / 100)
                MiniUsageBar(label: "MEM", percent: node.memoryPercent / 100)
            } else {
                Text("\(ResourceParser.formatMillicores(node.cpuCapacityMillicores)) · \(ResourceParser.formatBytes(node.memoryCapacityBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// `UsageBar` at a glance: same 65%/85% grading, but the percentage replaces
/// the "used / total" line so a node fits a grid cell instead of a full row.
///
/// Only `frame(width:)` clamps - the label prints the raw ratio, so a node over
/// its capacity reads as such instead of pinning at 100%.
struct MiniUsageBar: View {
    let label: String
    let percent: Double

    private var clamped: Double { min(max(percent, 0), 1) }
    private var color: Color {
        if percent > 0.85 { return .red }
        if percent > 0.65 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 5)
            Text("\(Int((percent * 100).rounded()))%")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
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
