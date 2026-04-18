import SwiftUI

struct ServicesView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var filter: String = ""
    @State private var mode: ViewMode = .cards

    var filtered: [Service] {
        guard !filter.isEmpty else { return store.services }
        let q = filter.lowercased()
        return store.services.filter {
            $0.name.lowercased().contains(q) ||
            $0.namespace.lowercased().contains(q) ||
            $0.type.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(text: $filter,
                      placeholder: "Filter services",
                      count: filtered.count,
                      trailing: AnyView(ViewModeToggle(mode: $mode)))
            switch mode {
            case .cards: cards
            case .table: table
            }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                ForEach(filtered) { svc in
                    ResourceCard(ref: .service(svc.namespace, svc.name),
                                 namespaceForTint: svc.namespace) {
                        VStack(alignment: .leading, spacing: 6) {
                            ServiceCardBody(service: svc)
                            Text(svc.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var table: some View {
        Table(filtered) {
            TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                .width(min: 100, ideal: 140)
            TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                .width(min: 120, ideal: 200)
            TableColumn("Type") { Text($0.type) }.width(min: 80, ideal: 110)
            TableColumn("Cluster IP") { Text($0.clusterIP).foregroundStyle(.secondary) }
                .width(min: 100, ideal: 140)
            TableColumn("Ports") { Text($0.ports.map(\.display).joined(separator: ", ")) }
                .width(min: 140, ideal: 220)
            TableColumn("External") { Text($0.externalIPs.joined(separator: ", ")).foregroundStyle(.secondary) }
            TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
        }
    }
}
