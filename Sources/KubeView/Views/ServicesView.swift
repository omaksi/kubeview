import SwiftUI

struct ServicesView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [Service] {
        store.services.searchFiltered(search) { [$0.name, $0.namespace, $0.type] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "services") { ViewModeToggle(mode: $mode) }
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
                    ResourceCard(ref: .service(svc.namespace, svc.name)) {
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
