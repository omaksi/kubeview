import SwiftUI

struct NodesView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var mode: ViewMode = .cards

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !store.metricsAvailable {
                    Label("metrics-server unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                ViewModeToggle(mode: $mode)
                Text("\(store.nodes.count)").foregroundStyle(.secondary).font(.caption)
            }
            .padding(8).background(.bar)

            switch mode {
            case .cards: cards
            case .table: table
            }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                ForEach(store.nodes) { node in
                    ResourceCard(ref: .node(node.name)) {
                        NodeCardBody(node: node,
                                     usage: store.nodeUsage.first { $0.name == node.name },
                                     showMetrics: store.metricsAvailable)
                    }
                }
            }
            .padding(12)
        }
    }

    private var table: some View {
        Table(store.nodes) {
            TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
            TableColumn("Status") { node in
                Text(node.readyCondition)
                    .foregroundStyle(node.readyCondition == "Ready" ? .green : .red)
            }.width(min: 70, ideal: 90)
            TableColumn("Kubelet") { Text($0.kubeletVersion).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 100)
            TableColumn("OS") { Text($0.os).foregroundStyle(.secondary) }
            TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
        }
    }
}

struct NodeCardBody: View {
    let node: Node
    let usage: NodeUsage?
    let showMetrics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ResourceTitle(ref: .node(node.name), name: node.name)
                Spacer()
                StatusBadge(text: node.readyCondition,
                            color: node.readyCondition == "Ready" ? .green : .red)
            }
            HStack(spacing: 12) {
                label(icon: "gearshape.2", text: node.kubeletVersion)
                label(icon: "laptopcomputer", text: node.os)
                Spacer()
                Text(node.age).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            if showMetrics, let u = usage {
                UsageBar(label: "CPU",
                         used: u.cpuUsedMillicores,
                         total: u.cpuCapacityMillicores,
                         format: { ResourceParser.formatMillicores($0) })
                UsageBar(label: "Memory",
                         used: u.memoryUsedBytes,
                         total: u.memoryCapacityBytes,
                         format: { ResourceParser.formatBytes($0) })
            } else {
                HStack(spacing: 12) {
                    stat(label: "CPU cap", value: ResourceParser.formatMillicores(node.cpuCapacityMillicores))
                    stat(label: "Mem cap", value: ResourceParser.formatBytes(node.memoryCapacityBytes))
                }
            }
        }
    }

    private func label(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}
