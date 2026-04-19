import SwiftUI

/// Shown on Overview when the global search is non-empty. Searches every
/// loaded resource type and renders one section per kind with at least one hit.
struct GlobalSearchResultsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState

    private var namespaces: [NamespaceSummary] {
        store.namespaceSummaries.searchFiltered(search) { [$0.name] }
    }
    private var pods: [Pod] {
        store.pods.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var services: [Service] {
        store.services.searchFiltered(search) { [$0.name, $0.namespace, $0.type] }
    }
    private var ingresses: [Ingress] {
        store.ingresses.searchFiltered(search) { ing in
            [ing.name, ing.namespace] + ing.hosts + ing.paths.map(\.serviceName)
        }
    }
    private var deployments: [Deployment] {
        store.deployments.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var statefulSets: [StatefulSet] {
        store.statefulSets.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var daemonSets: [DaemonSet] {
        store.daemonSets.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var jobs: [KubeJob] {
        store.jobs.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var cronJobs: [CronJob] {
        store.cronJobs.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var configMaps: [ConfigMap] {
        store.configMaps.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var secrets: [Secret] {
        store.secrets.searchFiltered(search) { [$0.name, $0.namespace, $0.type ?? ""] }
    }
    private var pvcs: [PVC] {
        store.pvcs.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var storageClasses: [StorageClass] {
        store.storageClasses.searchFiltered(search) { [$0.name, $0.provisioner ?? ""] }
    }
    private var hpas: [HPA] {
        store.hpas.searchFiltered(search) { [$0.name, $0.namespace, $0.targetName] }
    }
    private var networkPolicies: [NetworkPolicy] {
        store.networkPolicies.searchFiltered(search) { [$0.name, $0.namespace] }
    }
    private var serviceAccounts: [ServiceAccount] {
        store.serviceAccounts.searchFiltered(search) { [$0.name, $0.namespace, $0.irsaRoleArn ?? ""] }
    }
    private var nodes: [Node] {
        store.nodes.searchFiltered(search) { [$0.name, $0.kubeletVersion, $0.os] }
    }

    private var totalHits: Int {
        namespaces.count + pods.count + services.count + ingresses.count
        + deployments.count + statefulSets.count + daemonSets.count
        + jobs.count + cronJobs.count + configMaps.count + secrets.count
        + pvcs.count + storageClasses.count + hpas.count
        + networkPolicies.count + serviceAccounts.count + nodes.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Results for ")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    + Text("“\(search.trimmed)”")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(totalHits) matches").font(.caption).foregroundStyle(.secondary)
                }

                if totalHits == 0 {
                    ContentUnavailableView("No matches",
                                           systemImage: "questionmark.circle",
                                           description: Text("Nothing in the cluster matches “\(search.trimmed)”."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                }

                section(title: "Namespaces", kind: .namespace, count: namespaces.count) {
                    LazyVGrid(columns: cols(260), spacing: 10) {
                        ForEach(namespaces) { NamespaceCard(ns: $0, metricsAvailable: store.metricsAvailable) }
                    }
                }
                section(title: "Pods", kind: .pod, count: pods.count) {
                    grid(280) {
                        ForEach(pods) { pod in
                            NavigationLink(value: AppRoute.pod(PodRoute(namespace: pod.namespace, name: pod.name))) {
                                ResourceCard(ref: .pod(pod.namespace, pod.name), navigable: true) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        PodCardBody(pod: pod)
                                        Text(pod.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                section(title: "Deployments", kind: .deployment, count: deployments.count) {
                    grid(300) {
                        ForEach(deployments) { d in
                            let ref = ResourceRef(kind: .deployment, key: d.id)
                            ResourceCard(ref: ref) {
                                WorkloadCardBody(ref: ref, name: d.name, namespace: d.namespace,
                                                 desired: d.desired, ready: d.ready,
                                                 kindLabel: "Deployment", strategy: d.strategy,
                                                 healthy: d.isHealthy, reason: d.unhealthyReason, age: d.age)
                            }
                        }
                    }
                }
                section(title: "StatefulSets", kind: .statefulSet, count: statefulSets.count) {
                    grid(300) {
                        ForEach(statefulSets) { s in
                            let ref = ResourceRef(kind: .statefulSet, key: s.id)
                            ResourceCard(ref: ref) {
                                WorkloadCardBody(ref: ref, name: s.name, namespace: s.namespace,
                                                 desired: s.desired, ready: s.ready,
                                                 kindLabel: "StatefulSet", strategy: s.serviceName,
                                                 healthy: s.isHealthy, reason: s.unhealthyReason, age: s.age)
                            }
                        }
                    }
                }
                section(title: "DaemonSets", kind: .daemonSet, count: daemonSets.count) {
                    grid(300) {
                        ForEach(daemonSets) { d in
                            let ref = ResourceRef(kind: .daemonSet, key: d.id)
                            ResourceCard(ref: ref) {
                                WorkloadCardBody(ref: ref, name: d.name, namespace: d.namespace,
                                                 desired: d.desired, ready: d.ready,
                                                 kindLabel: "DaemonSet", strategy: nil,
                                                 healthy: d.isHealthy, reason: d.unhealthyReason, age: d.age)
                            }
                        }
                    }
                }
                section(title: "Services", kind: .service, count: services.count) {
                    grid(280) {
                        ForEach(services) { svc in
                            ResourceCard(ref: .service(svc.namespace, svc.name)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ServiceCardBody(service: svc)
                                    Text(svc.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                section(title: "Ingresses", kind: .ingress, count: ingresses.count) {
                    grid(320) {
                        ForEach(ingresses) { ing in
                            ResourceCard(ref: .ingress(ing.namespace, ing.name)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    IngressCardBody(ingress: ing)
                                    Text(ing.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                section(title: "ConfigMaps", kind: .configMap, count: configMaps.count) {
                    grid(300) { ForEach(configMaps) { cm in
                        ResourceCard(ref: .init(kind: .configMap, key: cm.id)) { ConfigMapCardBody(configMap: cm) }
                    } }
                }
                section(title: "Secrets", kind: .secret, count: secrets.count) {
                    grid(280) { ForEach(secrets) { s in
                        ResourceCard(ref: .init(kind: .secret, key: s.id)) { SecretCardBody(secret: s) }
                    } }
                }
                section(title: "Jobs", kind: .job, count: jobs.count) {
                    grid(280) { ForEach(jobs) { j in
                        ResourceCard(ref: .init(kind: .job, key: j.id)) { SimpleNameNamespaceBody(name: j.name, namespace: j.namespace, sub: "active=\(j.active) succeeded=\(j.succeeded) failed=\(j.failed)") }
                    } }
                }
                section(title: "CronJobs", kind: .cronJob, count: cronJobs.count) {
                    grid(280) { ForEach(cronJobs) { cj in
                        ResourceCard(ref: .init(kind: .cronJob, key: cj.id)) { SimpleNameNamespaceBody(name: cj.name, namespace: cj.namespace, sub: cj.schedule) }
                    } }
                }
                section(title: "HPAs", kind: .hpa, count: hpas.count) {
                    grid(280) { ForEach(hpas) { h in
                        ResourceCard(ref: .init(kind: .hpa, key: h.id)) { SimpleNameNamespaceBody(name: h.name, namespace: h.namespace, sub: "→ \(h.targetKind)/\(h.targetName)") }
                    } }
                }
                section(title: "PVCs", kind: .pvc, count: pvcs.count) {
                    grid(280) { ForEach(pvcs) { p in
                        ResourceCard(ref: .init(kind: .pvc, key: p.id)) { PVCCardBody(pvc: p) }
                    } }
                }
                section(title: "NetworkPolicies", kind: .networkPolicy, count: networkPolicies.count) {
                    grid(280) { ForEach(networkPolicies) { np in
                        ResourceCard(ref: .init(kind: .networkPolicy, key: np.id)) {
                            SimpleNameNamespaceBody(name: np.name, namespace: np.namespace,
                                                    sub: "ingress=\(np.ingressRuleCount) egress=\(np.egressRuleCount)")
                        }
                    } }
                }
                section(title: "ServiceAccounts", kind: .serviceAccount, count: serviceAccounts.count) {
                    grid(280) { ForEach(serviceAccounts) { sa in
                        ResourceCard(ref: .init(kind: .serviceAccount, key: sa.id)) {
                            SimpleNameNamespaceBody(name: sa.name, namespace: sa.namespace,
                                                    sub: sa.irsaRoleArn ?? "—")
                        }
                    } }
                }
                section(title: "StorageClasses", kind: .storageClass, count: storageClasses.count) {
                    grid(280) { ForEach(storageClasses) { sc in
                        ResourceCard(ref: .init(kind: .storageClass, key: sc.name)) {
                            VStack(alignment: .leading, spacing: 4) {
                                ResourceTitle(ref: .init(kind: .storageClass, key: sc.name), name: sc.name)
                                Text(sc.provisioner ?? "-").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    } }
                }
                section(title: "Nodes", kind: .node, count: nodes.count) {
                    grid(320) { ForEach(nodes) { n in
                        ResourceCard(ref: .node(n.name)) {
                            NodeCardBody(node: n,
                                         usage: store.nodeUsage.first { $0.name == n.name },
                                         showMetrics: store.metricsAvailable)
                        }
                    } }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func section<C: View>(title: String, kind: ResourceKind, count: Int,
                                   @ViewBuilder content: () -> C) -> some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: kind.icon).foregroundStyle(kind.accent)
                    Text(title).font(.headline)
                    Text("(\(count))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                content()
            }
        }
    }

    private func cols(_ min: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: min), spacing: 10)]
    }

    @ViewBuilder
    private func grid<C: View>(_ min: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: cols(min), spacing: 10) { content() }
    }
}

/// Minimal card body for resources without a dedicated CardBody yet.
struct SimpleNameNamespaceBody: View {
    let name: String
    let namespace: String?
    let sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(.callout, design: .monospaced).weight(.semibold))
                .lineLimit(1).truncationMode(.middle)
            if let namespace {
                Text(namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let sub, !sub.isEmpty {
                Text(sub).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
    }
}
