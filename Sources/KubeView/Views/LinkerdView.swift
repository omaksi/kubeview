import SwiftUI

struct LinkerdNamespaceSummary: Identifiable, Hashable {
    let name: String
    let meshedCount: Int
    let totalCount: Int
    var id: String { name }
    var percent: Double { totalCount > 0 ? Double(meshedCount) / Double(totalCount) : 0 }
}

struct LinkerdView: View {
    @EnvironmentObject var store: ClusterStore

    private var meshedPods: [Pod] { store.pods.filter { $0.isLinkerdMeshed } }

    private var controlPlanePods: [Pod] {
        store.pods.filter { $0.namespace == "linkerd" }
    }

    private var controlPlaneInstalled: Bool { !controlPlanePods.isEmpty }

    private var namespaceSummaries: [LinkerdNamespaceSummary] {
        let podsByNs = Dictionary(grouping: store.pods, by: { $0.namespace })
        return podsByNs.map { ns, ps in
            LinkerdNamespaceSummary(
                name: ns,
                meshedCount: ps.filter { $0.isLinkerdMeshed }.count,
                totalCount: ps.count
            )
        }
        .filter { $0.meshedCount > 0 || $0.name == "linkerd" }
        .sorted { $0.name < $1.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCards
                controlPlaneSection
                namespacesSection
                meshedPodsSection
            }
            .padding()
        }
    }

    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            StatCard(label: "Control Plane",
                     value: controlPlaneInstalled ? "Installed" : "Not found",
                     icon: "link",
                     color: controlPlaneInstalled ? .green : .secondary)
            StatCard(label: "Meshed Pods",
                     value: "\(meshedPods.count) / \(store.pods.count)",
                     icon: "shippingbox",
                     color: .pink)
            StatCard(label: "Meshed Namespaces",
                     value: "\(namespaceSummaries.filter { $0.meshedCount > 0 }.count)",
                     icon: "square.stack.3d.up",
                     color: .pink)
        }
    }

    @ViewBuilder
    private var controlPlaneSection: some View {
        if controlPlaneInstalled {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Control Plane", trailing: "\(controlPlanePods.count) pods in linkerd namespace")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                    ForEach(controlPlanePods) { pod in
                        NavigationLink(value: AppRoute.pod(PodRoute(namespace: pod.namespace, name: pod.name))) {
                            ResourceCard(ref: .pod(pod.namespace, pod.name), navigable: true) {
                                PodCardBody(pod: pod)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Linkerd control plane not detected", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Expected pods in the `linkerd` namespace. Install with `linkerd install | kubectl apply -f -`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var namespacesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Mesh Coverage by Namespace",
                          trailing: "\(namespaceSummaries.count) active")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                ForEach(namespaceSummaries) { ns in
                    NavigationLink(value: AppRoute.namespace(NamespaceRoute(name: ns.name))) {
                        LinkerdNamespaceCard(summary: ns)
                    }
                    .buttonStyle(.plain)
                }
            }
            if namespaceSummaries.isEmpty {
                Text("No meshed workloads found").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private var meshedPodsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Meshed Pods", trailing: "\(meshedPods.count)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                ForEach(meshedPods) { pod in
                    NavigationLink(value: PodRoute(namespace: pod.namespace, name: pod.name)) {
                        ResourceCard(ref: .pod(pod.namespace, pod.name), navigable: true) {
                            VStack(alignment: .leading, spacing: 6) {
                                PodCardBody(pod: pod)
                                Text(pod.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct LinkerdNamespaceCard: View {
    let summary: LinkerdNamespaceSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "link").foregroundStyle(.pink)
                Text(summary.name).font(.system(.callout, design: .monospaced).weight(.semibold))
                Spacer()
                Text("\(Int(summary.percent * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            UsageBar(label: "Meshed",
                     used: Double(summary.meshedCount),
                     total: Double(summary.totalCount),
                     format: { "\(Int($0))" })
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
