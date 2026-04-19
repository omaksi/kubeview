import SwiftUI

struct NamespaceRoute: Hashable { let name: String }

struct NamespaceDetailView: View {
    let name: String
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var emojis: EmojiStore

    var summary: NamespaceSummary? { store.namespaceSummaries.first { $0.name == name } }
    var pods: [Pod] { store.pods.filter { $0.namespace == name } }
    var services: [Service] { store.services.filter { $0.namespace == name } }
    var ingresses: [Ingress] { store.ingresses.filter { $0.namespace == name } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                section(title: "Ingresses", kind: .ingress, count: ingresses.count) {
                    if ingresses.isEmpty { emptyState("No ingresses") }
                    else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                            ForEach(ingresses) { ing in
                                ResourceCard(ref: .ingress(ing.namespace, ing.name)) {
                                    IngressCardBody(ingress: ing)
                                }
                            }
                        }
                    }
                }
                section(title: "Services", kind: .service, count: services.count) {
                    if services.isEmpty { emptyState("No services") }
                    else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                            ForEach(services) { svc in
                                ResourceCard(ref: .service(svc.namespace, svc.name)) {
                                    ServiceCardBody(service: svc)
                                }
                            }
                        }
                    }
                }
                section(title: "Pods", kind: .pod, count: pods.count) {
                    if pods.isEmpty { emptyState("No pods") }
                    else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                            ForEach(pods) { pod in
                                NavigationLink(value: AppRoute.pod(PodRoute(namespace: pod.namespace, name: pod.name))) {
                                    ResourceCard(ref: .pod(pod.namespace, pod.name), navigable: true) {
                                        PodCardBody(pod: pod)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(ResourceKind.namespace.accent.opacity(0.2))
                .frame(width: 56, height: 56)
                .overlay(
                    Text(emojis.emoji(for: .namespace(name)) ?? "📦").font(.system(size: 28))
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name).font(.title2.monospaced().weight(.semibold))
                    Text("Namespace")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ResourceKind.namespace.accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(ResourceKind.namespace.accent)
                }
                if let s = summary {
                    HStack(spacing: 14) {
                        miniStat("Pods", "\(s.runningCount)/\(s.podCount)")
                        miniStat("Failing", "\(s.failingCount)",
                                 tint: s.failingCount > 0 ? .red : nil)
                        miniStat("Services", "\(services.count)")
                        miniStat("Ingresses", "\(s.ingressCount)")
                        miniStat("CPU used", ResourceParser.formatMillicores(s.cpuUsedMillicores))
                        miniStat("Mem used", ResourceParser.formatBytes(s.memoryUsedBytes))
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func miniStat(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(tint ?? .primary)
        }
    }

    @ViewBuilder
    private func section<C: View>(title: String, kind: ResourceKind, count: Int,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: kind.icon).foregroundStyle(kind.accent)
                Text(title).font(.headline)
                Text("(\(count))").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
}

// MARK: - Card bodies (shared between namespace detail and list views)

struct PodCardBody: View {
    let pod: Pod
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ResourceTitle(ref: .pod(pod.namespace, pod.name), name: pod.name)
                Spacer()
                if pod.isLinkerdMeshed {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                        .help("Linkerd meshed")
                }
                StatusBadge(text: pod.isFailing ? (pod.failureReason ?? pod.phase) : pod.phase,
                            color: pod.isFailing ? .red : PodCard.phaseColor(pod.phase))
            }
            HStack(spacing: 12) {
                mini("Ready", pod.readyRatio)
                mini("Restarts", "\(pod.restarts)", tint: pod.restarts > 0 ? .orange : nil)
                mini("Age", pod.age)
            }
            if let node = pod.spec?.nodeName {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.caption2).foregroundStyle(.secondary)
                    Text(node).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func mini(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(tint ?? .primary)
        }
    }
}

struct ServiceCardBody: View {
    let service: Service
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ResourceTitle(ref: .service(service.namespace, service.name), name: service.name)
                Spacer()
                StatusBadge(text: service.type, color: serviceTypeColor(service.type))
            }
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(.secondary)
                Text(service.clusterIP).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if !service.ports.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(service.ports, id: \.self) { p in
                        Text(p.display).font(.caption.monospaced())
                    }
                }
            }
            if !service.externalIPs.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.caption2).foregroundStyle(.secondary)
                    Text(service.externalIPs.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func serviceTypeColor(_ t: String) -> Color {
        switch t {
        case "LoadBalancer": return .green
        case "NodePort":     return .orange
        case "ExternalName": return .purple
        default:             return .indigo
        }
    }
}

struct IngressPathLink: View {
    let path: IngressPathSummary
    let tls: Bool

    private var url: URL? {
        guard path.host != "*", !path.host.isEmpty else { return nil }
        let scheme = tls ? "https" : "http"
        return URL(string: "\(scheme)://\(path.host)\(path.path)")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tls ? "lock.fill" : "lock.open")
                .font(.caption2).foregroundStyle(tls ? .green : .secondary)
            if let url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 2) {
                        Text("\(path.host)\(path.path)")
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.up.right.square").font(.caption2)
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Open \(url.absoluteString) in browser")
            } else {
                Text("\(path.host)\(path.path)")
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
            Text("\(path.serviceName):\(path.servicePort)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct IngressCardBody: View {
    let ingress: Ingress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ResourceTitle(ref: .ingress(ingress.namespace, ingress.name), name: ingress.name)
                Spacer()
                StatusBadge(text: ingress.className, color: .purple)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ingress.paths, id: \.self) { p in
                    IngressPathLink(path: p, tls: ingress.tlsHosts.contains(p.host))
                }
                if ingress.paths.isEmpty {
                    Text("(no rules)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !ingress.externalAddresses.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.caption2).foregroundStyle(.secondary)
                    Text(ingress.externalAddresses.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
