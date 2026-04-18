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
                                ResourceCard(ref: .ingress(ing.namespace, ing.name), namespaceForTint: name) {
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
                                ResourceCard(ref: .service(svc.namespace, svc.name), namespaceForTint: name) {
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
                                NavigationLink(value: PodRoute(namespace: pod.namespace, name: pod.name)) {
                                    ResourceCard(ref: .pod(pod.namespace, pod.name), namespaceForTint: name) {
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
        .navigationTitle(name)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(NamespacePalette.color(for: name).opacity(0.25))
                .frame(width: 56, height: 56)
                .overlay(
                    Text(emojis.emoji(for: .namespace(name)) ?? "📦").font(.system(size: 28))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.title2.monospaced().weight(.semibold))
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
                Text(pod.name)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                StatusBadge(text: pod.phase, color: PodCard.phaseColor(pod.phase))
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
                Text(service.name)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
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

struct IngressCardBody: View {
    let ingress: Ingress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(ingress.name)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                StatusBadge(text: ingress.className, color: .purple)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ingress.paths, id: \.self) { p in
                    HStack(spacing: 6) {
                        Image(systemName: ingress.tlsHosts.contains(p.host) ? "lock.fill" : "lock.open")
                            .font(.caption2)
                            .foregroundStyle(ingress.tlsHosts.contains(p.host) ? .green : .secondary)
                        Text("\(p.host)\(p.path)")
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text("\(p.serviceName):\(p.servicePort)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
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
