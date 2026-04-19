import SwiftUI

struct NamespacesView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @EnvironmentObject var stars: StarStore
    @State private var mode: ViewMode = .cards

    var filtered: [NamespaceSummary] {
        NamespaceSort.sorted(
            store.namespaceSummaries.searchFiltered(search) { [$0.name] },
            stars: stars
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "namespaces") {
                HStack(spacing: 8) {
                    if !store.metricsAvailable {
                        Label("metrics unavailable", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                    }
                    ViewModeToggle(mode: $mode)
                }
            }
            switch mode {
            case .cards: cards
            case .table: table
            }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(filtered) { ns in
                    NamespaceCard(ns: ns, metricsAvailable: store.metricsAvailable)
                }
            }
            .padding(12)
        }
    }

    private var table: some View {
        Table(filtered) {
            TableColumn("Namespace") { Text($0.name).font(.system(.body, design: .monospaced)) }
                .width(min: 140, ideal: 220)
            TableColumn("Pods") { Text("\($0.runningCount)/\($0.podCount)") }.width(min: 50, ideal: 70)
            TableColumn("Failing") { ns in
                Text("\(ns.failingCount)")
                    .foregroundStyle(ns.failingCount > 0 ? .red : .secondary)
            }.width(min: 50, ideal: 70)
            TableColumn("CPU used") { Text(ResourceParser.formatMillicores($0.cpuUsedMillicores)) }
                .width(min: 70, ideal: 90)
            TableColumn("CPU req") { Text(ResourceParser.formatMillicores($0.cpuRequestedMillicores)) }
                .width(min: 70, ideal: 90)
            TableColumn("Mem used") { Text(ResourceParser.formatBytes($0.memoryUsedBytes)) }
                .width(min: 80, ideal: 100)
            TableColumn("Mem req") { Text(ResourceParser.formatBytes($0.memoryRequestedBytes)) }
                .width(min: 80, ideal: 100)
            TableColumn("Ingresses") { Text("\($0.ingressCount)") }.width(min: 60, ideal: 80)
            TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
        }
    }
}
