import SwiftUI

struct IngressRow: Identifiable, Hashable {
    let id: String
    let namespace: String
    let name: String
    let className: String
    let host: String
    let path: String
    let pathType: String
    let service: String
    let port: String
    let tls: Bool
    let external: String
}

struct IngressesView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var filter: String = ""
    @State private var mode: ViewMode = .cards

    var filteredIngresses: [Ingress] {
        guard !filter.isEmpty else { return store.ingresses }
        let q = filter.lowercased()
        return store.ingresses.filter { ing in
            ing.name.lowercased().contains(q) ||
            ing.namespace.lowercased().contains(q) ||
            ing.hosts.contains(where: { $0.lowercased().contains(q) }) ||
            ing.paths.contains(where: { $0.serviceName.lowercased().contains(q) })
        }
    }

    var rows: [IngressRow] {
        filteredIngresses.flatMap { ing -> [IngressRow] in
            let paths = ing.paths.isEmpty
                ? [IngressPathSummary(host: "*", path: "/", pathType: "-", serviceName: "-", servicePort: "-")]
                : ing.paths
            return paths.enumerated().map { idx, p in
                IngressRow(
                    id: "\(ing.id)#\(idx)",
                    namespace: ing.namespace,
                    name: ing.name,
                    className: ing.className,
                    host: p.host,
                    path: p.path,
                    pathType: p.pathType,
                    service: p.serviceName,
                    port: p.servicePort,
                    tls: ing.tlsHosts.contains(p.host),
                    external: ing.externalAddresses.joined(separator: ", ")
                )
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(text: $filter,
                      placeholder: "Filter by host, name, service",
                      count: mode == .cards ? filteredIngresses.count : rows.count,
                      trailing: AnyView(ViewModeToggle(mode: $mode)))
            switch mode {
            case .cards: cards
            case .table: table
            }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                ForEach(filteredIngresses) { ing in
                    ResourceCard(ref: .ingress(ing.namespace, ing.name),
                                 namespaceForTint: ing.namespace) {
                        VStack(alignment: .leading, spacing: 6) {
                            IngressCardBody(ingress: ing)
                            Text(ing.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var table: some View {
        Table(rows) {
            TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                .width(min: 100, ideal: 140)
            TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                .width(min: 120, ideal: 180)
            TableColumn("Class") { Text($0.className).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 90)
            TableColumn("Host") { row in
                HStack(spacing: 4) {
                    if row.tls { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green) }
                    Text(row.host).font(.system(.body, design: .monospaced))
                }
            }.width(min: 160, ideal: 260)
            TableColumn("Path") { Text($0.path).font(.system(.body, design: .monospaced)) }
                .width(min: 80, ideal: 140)
            TableColumn("→ Service") { Text("\($0.service):\($0.port)").foregroundStyle(.secondary) }
                .width(min: 140, ideal: 200)
            TableColumn("External") { Text($0.external).foregroundStyle(.secondary).font(.caption) }
                .width(min: 100, ideal: 180)
        }
    }
}

