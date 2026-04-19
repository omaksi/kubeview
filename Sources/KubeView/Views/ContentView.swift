import SwiftUI

enum NavSection: String, CaseIterable, Identifiable {
    case overview, events
    case namespaces, nodes
    case deployments, statefulsets, replicasets, daemonsets, jobs, cronjobs, pods, hpas
    case services, ingresses, networkpolicies
    case pvcs, storageclasses
    case configmaps, secrets, serviceaccounts, irsa
    case linkerd
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .events: return "Events"
        case .namespaces: return "Namespaces"
        case .nodes: return "Nodes"
        case .deployments: return "Deployments"
        case .statefulsets: return "StatefulSets"
        case .replicasets: return "ReplicaSets"
        case .daemonsets: return "DaemonSets"
        case .jobs: return "Jobs"
        case .cronjobs: return "CronJobs"
        case .pods: return "Pods"
        case .hpas: return "HPAs"
        case .services: return "Services"
        case .ingresses: return "Ingresses"
        case .networkpolicies: return "NetworkPolicies"
        case .pvcs: return "PVCs"
        case .storageclasses: return "StorageClasses"
        case .configmaps: return "ConfigMaps"
        case .secrets: return "Secrets"
        case .serviceaccounts: return "ServiceAccounts"
        case .irsa: return "IRSA"
        case .linkerd: return "Linkerd"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.doc.horizontal"
        case .events: return "bell"
        case .namespaces: return "square.stack.3d.up"
        case .nodes: return "server.rack"
        case .deployments: return "square.grid.2x2"
        case .statefulsets: return "cylinder.split.1x2"
        case .replicasets: return "rectangle.stack"
        case .daemonsets: return "square.stack.3d.down.right"
        case .jobs: return "hammer"
        case .cronjobs: return "clock.arrow.circlepath"
        case .pods: return "shippingbox"
        case .hpas: return "arrow.up.and.down.and.arrow.left.and.right"
        case .services: return "bolt.horizontal.circle"
        case .ingresses: return "network"
        case .networkpolicies: return "shield.lefthalf.filled"
        case .pvcs: return "externaldrive"
        case .storageclasses: return "internaldrive"
        case .configmaps: return "doc.plaintext"
        case .secrets: return "key.fill"
        case .serviceaccounts: return "person.badge.key"
        case .irsa: return "person.badge.shield.checkmark"
        case .linkerd: return "link"
        }
    }
}

private struct NavGroup {
    let title: String
    let items: [NavSection]
}

extension NavSection {
    /// Hide sections that have nothing to show for this cluster.
    /// `overview`, `namespaces`, `nodes`, `pods`, `services`, `ingresses`, `secrets`,
    /// `serviceaccounts`, `storageclasses`, `deployments` are always visible.
    @MainActor
    func isVisible(store: ClusterStore) -> Bool {
        switch self {
        case .overview, .namespaces, .nodes, .pods,
             .services, .ingresses, .secrets, .serviceaccounts,
             .storageclasses, .deployments:
            return true
        case .events:         return true
        case .statefulsets:   return !store.statefulSets.isEmpty
        case .replicasets:    return !store.replicaSets.isEmpty
        case .daemonsets:     return !store.daemonSets.isEmpty
        case .jobs:           return !store.jobs.isEmpty
        case .cronjobs:       return !store.cronJobs.isEmpty
        case .hpas:           return !store.hpas.isEmpty
        case .networkpolicies: return !store.networkPolicies.isEmpty
        case .pvcs:           return !store.pvcs.isEmpty
        case .configmaps:     return !store.configMaps.isEmpty
        case .irsa:           return store.serviceAccounts.contains { $0.irsaRoleArn != nil }
        case .linkerd:
            return store.pods.contains { $0.isLinkerdMeshed } ||
                   store.pods.contains { $0.namespace == "linkerd" }
        }
    }
}

private let navGroups: [NavGroup] = [
    NavGroup(title: "Cluster", items: [.overview, .events, .namespaces, .nodes]),
    NavGroup(title: "Workloads", items: [.deployments, .statefulsets, .daemonsets, .replicasets, .jobs, .cronjobs, .pods, .hpas]),
    NavGroup(title: "Network", items: [.services, .ingresses, .networkpolicies]),
    NavGroup(title: "Storage", items: [.pvcs, .storageclasses]),
    NavGroup(title: "Config & RBAC", items: [.configmaps, .secrets, .serviceaccounts, .irsa]),
    NavGroup(title: "Service Mesh", items: [.linkerd]),
]

enum AppRoute: Hashable {
    case namespace(NamespaceRoute)
    case pod(PodRoute)

    var kind: ResourceKind {
        switch self {
        case .namespace: return .namespace
        case .pod:       return .pod
        }
    }
    var displayName: String {
        switch self {
        case .namespace(let r): return r.name
        case .pod(let r):       return r.name
        }
    }
}

@MainActor
final class NavState: ObservableObject {
    @Published var selected: NavSection? = .overview
    @Published var path: [AppRoute] = []
}

struct ContentView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var nav: NavState

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selected) {
                ForEach(navGroups, id: \.title) { group in
                    let items = group.items.filter { $0.isVisible(store: store) }
                    if !items.isEmpty {
                        SwiftUI.Section(group.title) {
                            ForEach(items) { s in
                                Label(s.title, systemImage: s.icon).tag(s)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .onChange(of: nav.selected) { _, _ in nav.path = [] }
        } detail: {
            NavigationStack(path: $nav.path) {
                currentRoot
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .namespace(let r): NamespaceDetailView(name: r.name)
                        case .pod(let r):       PodDetailView(route: r)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                Task { await store.refresh() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Refresh now")
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var currentRoot: some View {
        switch nav.selected ?? .overview {
        case .overview: OverviewView()
        case .events: EventsView(store: store)
        case .namespaces: NamespacesView()
        case .nodes: NodesView()
        case .deployments: DeploymentsView()
        case .statefulsets: StatefulSetsView()
        case .replicasets: ReplicaSetsView()
        case .daemonsets: DaemonSetsView()
        case .jobs: JobsView()
        case .cronjobs: CronJobsView()
        case .pods: PodsView()
        case .hpas: HPAsView()
        case .services: ServicesView()
        case .ingresses: IngressesView()
        case .networkpolicies: NetworkPoliciesView()
        case .pvcs: PVCsView()
        case .storageclasses: StorageClassesView()
        case .configmaps: ConfigMapsView()
        case .secrets: SecretsView()
        case .serviceaccounts: ServiceAccountsView(irsaOnly: false)
        case .irsa: ServiceAccountsView(irsaOnly: true)
        case .linkerd: LinkerdView()
        }
    }
}

struct ClusterBar: View {
    @EnvironmentObject var manager: ClusterManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(manager.activeOrder, id: \.self) { ctx in
                    ClusterPill(context: ctx)
                }
                addMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(manager.availableContexts.filter { !manager.activeOrder.contains($0) }, id: \.self) { ctx in
                Button(ctx) { manager.activate(ctx); manager.select(ctx) }
            }
            if manager.availableContexts.allSatisfy({ manager.activeOrder.contains($0) }) {
                Text("All contexts active").foregroundStyle(.secondary)
            }
        } label: {
            Label("Add Cluster", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct ClusterPill: View {
    let context: String
    @EnvironmentObject var manager: ClusterManager

    private var store: ClusterStore? { manager.stores[context] }
    private var isSelected: Bool { manager.selected == context }
    private var health: Color {
        guard let s = store else { return .secondary }
        if !s.unhealthyPods.isEmpty { return .red }
        if !s.unhealthyWorkloads.isEmpty { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(health).frame(width: 7, height: 7)
            Text(context)
                .font(.caption.monospaced())
                .lineLimit(1)
            Button {
                manager.deactivate(context)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from active clusters")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                    in: Capsule())
        .overlay(
            Capsule().stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1)
        )
        .onTapGesture { manager.select(context) }
    }
}

struct EmptyClusterView: View {
    @EnvironmentObject var manager: ClusterManager
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "binoculars").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No cluster selected").font(.headline)
            if !manager.availableContexts.isEmpty {
                Menu("Activate a Context") {
                    ForEach(manager.availableContexts, id: \.self) { ctx in
                        Button(ctx) { manager.activate(ctx); manager.select(ctx) }
                    }
                }
            } else if let err = manager.bootstrapError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text("Loading contexts…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
