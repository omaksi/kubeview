import SwiftUI

enum NavSection: String, CaseIterable, Identifiable {
    case overview, namespaces, pods, nodes, services, ingresses
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .namespaces: return "Namespaces"
        case .pods: return "Pods"
        case .nodes: return "Nodes"
        case .services: return "Services"
        case .ingresses: return "Ingresses"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "chart.bar.doc.horizontal"
        case .namespaces: return "square.stack.3d.up"
        case .pods: return "shippingbox"
        case .nodes: return "server.rack"
        case .services: return "bolt.horizontal.circle"
        case .ingresses: return "network"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var selected: NavSection? = .overview
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                SwiftUI.Section("Cluster") {
                    ForEach(NavSection.allCases) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .onChange(of: selected) { _, _ in path = NavigationPath() }
        } detail: {
            NavigationStack(path: $path) {
                currentRoot
                    .navigationDestination(for: NamespaceRoute.self) { route in
                        NamespaceDetailView(name: route.name)
                    }
                    .navigationDestination(for: PodRoute.self) { route in
                        PodDetailView(route: route)
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigation) { ContextPicker() }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                Task { await store.refresh() }
                            } label: {
                                Image(systemName: store.loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                            }
                            .disabled(store.loading)
                            .help("Refresh now")
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var currentRoot: some View {
        switch selected ?? .overview {
        case .overview: OverviewView()
        case .namespaces: NamespacesView()
        case .pods: PodsView()
        case .nodes: NodesView()
        case .services: ServicesView()
        case .ingresses: IngressesView()
        }
    }
}

struct ContextPicker: View {
    @EnvironmentObject var store: ClusterStore

    var body: some View {
        Menu {
            ForEach(store.contexts) { ctx in
                Button {
                    Task { await store.switchContext(ctx.name) }
                } label: {
                    if ctx.name == store.currentContext {
                        Label(ctx.name, systemImage: "checkmark")
                    } else {
                        Text(ctx.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text(store.currentContext.isEmpty ? "No context" : store.currentContext)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
