import SwiftUI

enum NavSection: String, CaseIterable, Identifiable, Codable {
    case overview, events
    case namespaces, nodes
    case deployments, statefulsets, replicasets, daemonsets, jobs, cronjobs, pods, hpas
    case services, ingresses, networkpolicies
    case pvcs, storageclasses
    case configmaps, secrets, serviceaccounts, irsa
    case linkerd, lgtm
    case graph
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
        case .lgtm: return "LGTM"
        case .graph: return "Graph"
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
        case .lgtm: return "chart.line.downtrend.xyaxis"
        case .graph: return "point.3.connected.trianglepath.dotted"
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
    /// ponytail: deliberately blind to `store.namespaceFilter`. Recomputing
    /// visibility per namespace would make sections appear and disappear as the
    /// scope changes, and a filtered-to-empty list already says so itself.
    @MainActor
    func isVisible(store: ClusterStore) -> Bool {
        switch self {
        case .overview, .namespaces, .nodes, .pods,
             .services, .ingresses, .secrets, .serviceaccounts,
             .storageclasses, .deployments:
            return true
        case .events:         return true
        case .graph:          return true
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
        case .lgtm:
            // Cheap name check against workloads already in memory. The real
            // classification lives in kubectl-lgtm, but running it just to
            // decide whether to show a sidebar row would cost a port-forward.
            return store.deployments.contains { isLgtm($0.name) } ||
                   store.statefulSets.contains { isLgtm($0.name) }
        }
    }
}

// The sidebar is split by scope, and the split is the point: everything above
// the namespace header ignores the namespace picker, everything below obeys it.
//
// Overview stands alone because it's the landing view; the rest of the
// cluster-wide items collapse, since you consult them far less often than the
// namespaced lists underneath.
/// Whole-scope views, above the per-kind lists.
private let navLead: [NavSection] = [.overview, .graph, .events]

/// No scope tiers any more. The tab states which cluster and namespace you're
/// in, so the sidebar is just a list of views — and each row's count moving
/// (or not) when the namespace changes demonstrates scope better than a header
/// claiming it. Cluster-scoped kinds sit in the trailing group, where their
/// static counts read as deliberate rather than broken.
private let navGroups: [NavGroup] = [
    NavGroup(title: "Workloads", items: [.deployments, .statefulsets, .daemonsets, .replicasets, .jobs, .cronjobs, .pods, .hpas]),
    NavGroup(title: "Network", items: [.services, .ingresses, .networkpolicies]),
    NavGroup(title: "Storage", items: [.pvcs]),
    NavGroup(title: "Config & RBAC", items: [.configmaps, .secrets, .serviceaccounts, .irsa]),
    NavGroup(title: "Observability", items: [.linkerd, .lgtm]),
    NavGroup(title: "Cluster", items: [.nodes, .namespaces, .storageclasses]),
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
    @EnvironmentObject var tabs: TabStore

    /// The sidebar no longer carries scope. The tab states which cluster and
    /// namespace you're in, so this is just a list of views — and each row's
    /// count demonstrates the scope rather than a header announcing it.
    ///
    /// The selection lives on the tab, not in `NavState`, so every tab
    /// remembers what it was showing.
    private var selection: Binding<NavSection?> {
        Binding(
            get: { tabs.active?.view ?? nav.selected },
            set: { new in
                guard let new else { return }
                if let id = tabs.activeID { tabs.setView(new, for: id) }
                nav.selected = new
                nav.path = []
            }
        )
    }

    private func row(_ s: NavSection) -> some View {
        HStack {
            Label(s.title, systemImage: s.icon)
            Spacer()
            // Counts come from fetched data. A background tab has none, and
            // showing a number the app can't stand behind is the one lie this
            // lifecycle can't afford — so they simply vanish.
            if store.cadence == .live, let n = count(s) {
                Text("\(n)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .tag(s)
    }

    private func count(_ s: NavSection) -> Int? {
        let ns = store.namespaceFilter
        switch s {
        case .pods:            return store.pods.inNamespace(ns, \.namespace).count
        case .deployments:     return store.deployments.inNamespace(ns, \.namespace).count
        case .statefulsets:    return store.statefulSets.inNamespace(ns, \.namespace).count
        case .daemonsets:      return store.daemonSets.inNamespace(ns, \.namespace).count
        case .replicasets:     return store.replicaSets.inNamespace(ns, \.namespace).count
        case .jobs:            return store.jobs.inNamespace(ns, \.namespace).count
        case .cronjobs:        return store.cronJobs.inNamespace(ns, \.namespace).count
        case .hpas:            return store.hpas.inNamespace(ns, \.namespace).count
        case .services:        return store.services.inNamespace(ns, \.namespace).count
        case .ingresses:       return store.ingresses.inNamespace(ns, \.namespace).count
        case .networkpolicies: return store.networkPolicies.inNamespace(ns, \.namespace).count
        case .pvcs:            return store.pvcs.inNamespace(ns, \.namespace).count
        case .configmaps:      return store.configMaps.inNamespace(ns, \.namespace).count
        case .secrets:         return store.secrets.inNamespace(ns, \.namespace).count
        case .serviceaccounts: return store.serviceAccounts.inNamespace(ns, \.namespace).count
        // Cluster-scoped: these counts deliberately don't move with the
        // namespace, which is the quiet way of saying they aren't scoped.
        case .nodes:           return store.nodes.count
        case .namespaces:      return store.namespaces.count
        case .storageclasses:  return store.storageClasses.count
        case .overview, .graph, .events, .irsa, .linkerd, .lgtm: return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                SwiftUI.Section {
                    ForEach(navLead.filter { $0.isVisible(store: store) }) { row($0) }
                }
                ForEach(navGroups, id: \.title) { group in
                    let items = group.items.filter { $0.isVisible(store: store) }
                    if !items.isEmpty {
                        SwiftUI.Section(group.title) {
                            ForEach(items) { row($0) }
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
                        // Same placement renders in declaration order, so this
                        // sits to the left of Refresh. `SettingsLink` is the
                        // supported way to open the Settings scene on macOS 14 —
                        // the old `showSettingsWindow:` selector is private API
                        // and was renamed once already.
                        ToolbarItem(placement: .primaryAction) {
                            SettingsLink {
                                Image(systemName: "gearshape")
                            }
                            .help("Settings — appearance, cluster names, AWS profiles")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            RefreshButton(store: store)
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
        // Keyed by context on purpose. `ContentView` keeps its identity when the
        // selected cluster changes, so without this the @StateObject inside
        // LgtmView is never rebuilt and the view goes on showing the previous
        // cluster's report — or its error — under the new cluster's name.
        case .lgtm: LgtmView(context: store.context).id(store.context)
        case .graph: NamespaceGraphRoot()
        }
    }
}

/// The Graph nav item needs one namespace, and "All Namespaces" isn't one.
/// Drawing every namespace at once is unreadable and slow, so this says what to
/// do instead rather than rendering a hairball.
/// ponytail: no multi-namespace mode. Add one if a cross-namespace view ever
/// earns its keep — the builder already takes arbitrary slices.
private struct NamespaceGraphRoot: View {
    @EnvironmentObject var store: ClusterStore

    var body: some View {
        if let ns = store.namespaceFilter {
            NamespaceGraphView(namespace: ns)
        } else {
            ContentUnavailableView {
                Label("Pick a namespace", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("The graph draws one namespace at a time. Choose one from the Namespace picker.")
            }
        }
    }
}

/// The namespace tier's header — and its picker. Putting the control in the
/// header instead of a row keeps it out of `List(selection:)`, where it would
/// look like a destination and fight the nav selection. The toolbar picker is
/// the same binding; this one is the second entry point, since the sidebar can
/// be collapsed away entirely.
private struct NamespaceTierHeader: View {
    @ObservedObject var store: ClusterStore

    var body: some View {
        HStack(spacing: 6) {
            Text("Namespace")
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
            Picker("Namespace", selection: $store.namespaceFilter) {
                Text("All").tag(String?.none)
                ForEach(ClusterStore.pickerOptions(store.namespaces.map(\.name),
                                                   selected: store.namespaceFilter), id: \.self) { ns in
                    Text(ns).tag(String?.some(ns))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.bottom, 1)
    }
}

/// The toolbar refresh. Reloads the *lists* too, not just the selected
/// cluster's resources — a kubeconfig context or AWS profile added after
/// launch was otherwise invisible until a restart.
///
/// This is the one place a spinner is correct: the design rule bans them for
/// the 5s background poll, but a press with no visible response reads as a
/// dead button.
struct RefreshButton: View {
    @ObservedObject var store: ClusterStore
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var aws: AwsStore
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            Task {
                await manager.reloadContexts()
                aws.reload()
                await aws.loadContexts()
                await store.refresh()
                busy = false
            }
        } label: {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(busy)
        .help("Reload contexts, AWS profiles and this cluster's resources")
    }
}

struct ClusterBar: View {
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var names: ClusterNameStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(manager.activeOrder, id: \.self) { ctx in
                    if let store = manager.stores[ctx] {
                        ClusterPill(context: ctx, store: store)
                    }
                }
                addMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        // RootView renders ClusterBar in both branches of its `selectedStore`
        // check, and bootstrap() flips that branch asynchronously *after* first
        // layout. SwiftUI reuses the same NSScrollView across the switch, which
        // keeps the content size it measured while the bar was empty — so the
        // pills exist with correct frames but aren't painted until a resize.
        // Keying on the active set forces a fresh scroll view when they arrive.
        .id(manager.activeOrder)
    }

    private var addMenu: some View {
        Menu {
            ForEach(manager.availableContexts.filter { !manager.activeOrder.contains($0) }, id: \.self) { ctx in
                Button(names.name(for: ctx)) { manager.activate(ctx); manager.select(ctx) }
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

/// Takes the store as an `@ObservedObject` rather than reaching through
/// `manager.stores[…]`. The manager only republishes when the *dictionary*
/// changes, so a pill that looked the store up would never re-render when its
/// health or connection state changed.
struct ClusterPill: View {
    let context: String
    @ObservedObject var store: ClusterStore
    @EnvironmentObject var names: ClusterNameStore
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var aws: AwsStore

    private var isSelected: Bool { manager.selected == context }

    /// Non-nil only when this pill can actually offer a fix: the fault is a
    /// login problem *and* the kubeconfig names a profile we can log into.
    private var loginProfile: AwsProfile? {
        guard store.fault == .notLoggedIn else { return nil }
        return aws.profile(forContext: context)
    }

    private var health: Color {
        if let fault = store.fault { return fault.color }
        if store.lastRefresh == nil { return .secondary }
        if !store.unhealthyPods.isEmpty { return .red }
        if !store.unhealthyWorkloads.isEmpty { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            if let fault = store.fault {
                Image(systemName: fault.icon)
                    .font(.caption2)
                    .foregroundStyle(fault.color)
            } else {
                Circle().fill(health).frame(width: 7, height: 7)
            }
            Text(names.name(for: context))
                .font(.caption.monospaced())
                .lineLimit(1)
            // The lock icon and the button both already say "not logged in", so
            // the label would be the third. Every other fault keeps its text —
            // none of them has an inline action, so the words are all they have.
            if let fault = store.fault, loginProfile == nil {
                Text(fault.short)
                    .font(.caption2)
                    .foregroundStyle(fault.color)
            }
            // "not logged in" is the one fault the user can fix from here, so
            // it gets the action inline rather than sending them to the AWS
            // pane to work out which profile this cluster uses.
            if let profile = loginProfile {
                if aws.isBusy(profile) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Log in") { aws.login(profile) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Run: \(aws.command(for: profile))")
                }
            }
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
        .help(store.lastError ?? context)
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

/// The namespace scope, always on screen beside the cluster pills. It is a
/// sibling of `ClusterBar`, not a child: that bar is keyed on
/// `manager.activeOrder`, so adding or removing a cluster rebuilds its whole
/// subtree — an open picker inside it would be torn down mid-interaction.
///
/// Selection lives on the store, so it is per cluster and survives relaunch.
struct NamespacePicker: View {
    @ObservedObject var store: ClusterStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.caption)
                .foregroundStyle(store.namespaceFilter == nil ? Color.secondary : Color.accentColor)
            Picker("Namespace", selection: $store.namespaceFilter) {
                Text("All Namespaces").tag(String?.none)
                ForEach(ClusterStore.pickerOptions(store.namespaces.map(\.name),
                                                   selected: store.namespaceFilter), id: \.self) { ns in
                    Text(ns).tag(String?.some(ns))
                }
            }
            // ponytail: a plain pop-up menu. No type-ahead or search field —
            // on a cluster with 200 namespaces this menu is long. Add a
            // searchable list only if that actually bites.
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 190)
            .help("Scope every namespaced list to one namespace")
        }
        .padding(.trailing, 8)
    }
}

/// Names the LGTM Helm charts give their workloads. Prefix-matched, because a
/// release name sits in front (`lgtm-distributed-mimir-ingester`) and a target
/// name behind it.
private func isLgtm(_ name: String) -> Bool {
    ["mimir", "loki", "tempo", "grafana", "pyroscope", "alloy", "cortex"]
        .contains { name.contains($0) }
}
