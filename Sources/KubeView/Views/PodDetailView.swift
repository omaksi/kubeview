import SwiftUI

struct PodRoute: Hashable {
    let namespace: String
    let name: String
}

@MainActor
final class PodEventsLoader: ObservableObject {
    @Published var events: [KubeEvent] = []
    @Published var loading = false
    @Published var error: String?
    private let kubectl = KubectlService()

    func load(namespace: String, pod: String) async {
        loading = true
        defer { loading = false }
        do {
            events = try await kubectl.events(namespace: namespace, podName: pod)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PodDetailView: View {
    let route: PodRoute
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var emojis: EmojiStore
    @StateObject private var eventsLoader = PodEventsLoader()
    @State private var tab: PodDetailTab = .overview

    private var pod: Pod? {
        store.pods.first { $0.namespace == route.namespace && $0.name == route.name }
    }

    private var containerNames: [String] {
        guard let p = pod else { return [] }
        let main = (p.spec?.containers ?? []).map(\.name)
        let inits = (p.spec?.initContainers ?? []).map(\.name)
        return main + inits
    }

    var body: some View {
        Group {
            if let pod {
                VStack(spacing: 0) {
                    header(for: pod)
                        .padding(.horizontal)
                        .padding(.top)
                    Picker("", selection: $tab) {
                        ForEach(PodDetailTab.allCases) { t in
                            Label(t.title, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider()

                    switch tab {
                    case .overview: overviewBody(for: pod)
                    case .logs:     PodLogsView(route: route, containers: containerNames)
                    case .describe: PodDescribeView(route: route)
                    }
                }
            } else {
                ContentUnavailableView("Pod not found",
                                       systemImage: "shippingbox",
                                       description: Text("\(route.namespace)/\(route.name) no longer exists in the current context."))
            }
        }
        .navigationTitle(route.name)
        .task(id: route) {
            await eventsLoader.load(namespace: route.namespace, pod: route.name)
        }
    }

    @ViewBuilder
    private func overviewBody(for pod: Pod) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCard(for: pod)
                containersSection(pod: pod)
                if let inits = pod.spec?.initContainers, !inits.isEmpty {
                    initContainersSection(pod: pod, inits: inits)
                }
                conditionsSection(pod: pod)
                eventsSection(pod: pod)
            }
            .padding()
        }
    }

    private func header(for pod: Pod) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(PodCard.phaseColor(pod.phase).opacity(0.2))
                .frame(width: 56, height: 56)
                .overlay(
                    Text(emojis.emoji(for: .pod(pod.namespace, pod.name)) ?? "🐳")
                        .font(.system(size: 28))
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(pod.name).font(.title2.monospaced().weight(.semibold))
                    StatusBadge(text: pod.phase, color: PodCard.phaseColor(pod.phase))
                }
                NavigationLink(value: NamespaceRoute(name: pod.namespace)) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up")
                        Text(pod.namespace).font(.callout.monospaced())
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryCard(for pod: Pod) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "info.circle", title: "Overview", color: ResourceKind.pod.accent)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                kv("Node", pod.spec?.nodeName ?? "-")
                kv("Pod IP", pod.status?.podIP ?? "-")
                kv("Host IP", pod.status?.hostIP ?? "-")
                kv("QoS", pod.status?.qosClass ?? "-")
                kv("Service Account", pod.spec?.serviceAccountName ?? "-")
                kv("Restart Policy", pod.spec?.restartPolicy ?? "-")
                kv("Start Time", pod.status?.startTime.map { Pod.formatAge(from: $0) } ?? "-")
                kv("Age", pod.age)
            }
            if let reason = pod.status?.reason, !reason.isEmpty {
                Text("Reason: \(reason)").font(.caption).foregroundStyle(.orange)
            }
            if let msg = pod.status?.message, !msg.isEmpty {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func containersSection(pod: Pod) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "cube.box", title: "Containers",
                          count: pod.spec?.containers.count ?? 0,
                          color: ResourceKind.pod.accent)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                ForEach(pod.spec?.containers ?? [], id: \.name) { c in
                    ContainerCard(
                        container: c,
                        status: pod.status?.containerStatuses?.first { $0.name == c.name }
                    )
                }
            }
        }
    }

    private func initContainersSection(pod: Pod, inits: [Container]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "arrow.up.forward.app", title: "Init Containers",
                          count: inits.count, color: .orange)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                ForEach(inits, id: \.name) { c in
                    ContainerCard(
                        container: c,
                        status: pod.status?.initContainerStatuses?.first { $0.name == c.name }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func conditionsSection(pod: Pod) -> some View {
        let conds = pod.status?.conditions ?? []
        if !conds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(icon: "checkmark.seal", title: "Conditions",
                              count: conds.count, color: .blue)
                VStack(spacing: 6) {
                    ForEach(conds, id: \.self) { c in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(c.status == "True" ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(c.type).font(.callout.monospaced()).frame(minWidth: 140, alignment: .leading)
                            Text(c.status).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let r = c.reason, !r.isEmpty {
                                Text(r).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func eventsSection(pod: Pod) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(icon: "bell", title: "Events",
                              count: eventsLoader.events.count, color: .teal)
                Spacer()
                if eventsLoader.loading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await eventsLoader.load(namespace: route.namespace, pod: route.name) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh events")
            }
            if let err = eventsLoader.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if eventsLoader.events.isEmpty && !eventsLoader.loading {
                Text("No events").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(eventsLoader.events) { EventRow(event: $0) }
                }
            }
        }
    }

    private func sectionHeader(icon: String, title: String, count: Int? = nil, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.headline)
            if let c = count {
                Text("(\(c))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced())
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ContainerCard: View {
    let container: Container
    let status: ContainerStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "cube.box")
                    .foregroundStyle(ResourceKind.pod.accent)
                Text(container.name)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                Spacer()
                if let state = status?.state?.summary {
                    StatusBadge(text: state, color: stateColor(state))
                }
            }
            Text(container.image)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)

            HStack(spacing: 12) {
                mini("Ready", status?.ready == true ? "yes" : "no",
                     tint: status?.ready == true ? .green : .orange)
                mini("Restarts", "\(status?.restartCount ?? 0)",
                     tint: (status?.restartCount ?? 0) > 0 ? .orange : nil)
                if let ports = container.ports, !ports.isEmpty {
                    mini("Ports", ports.map(\.display).joined(separator: ", "))
                }
            }

            if let reqs = container.resources?.requests, !reqs.isEmpty {
                resourceLine(label: "Requests", values: reqs)
            }
            if let lims = container.resources?.limits, !lims.isEmpty {
                resourceLine(label: "Limits", values: lims)
            }

            if let detail = status?.state?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ResourceKind.pod.accent.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func mini(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(tint ?? .primary)
        }
    }

    private func resourceLine(label: String, values: [String: String]) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            ForEach(values.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                Text("\(k):").font(.caption2).foregroundStyle(.secondary)
                Text(v).font(.caption.monospacedDigit())
            }
            Spacer()
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "Running": return .green
        case "Terminated": return .secondary
        case "Completed": return .blue
        default: return .orange
        }
    }
}

struct EventRow: View {
    let event: KubeEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(typeColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.reason ?? "-").font(.caption.weight(.semibold))
                    Text(event.type ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let count = event.count, count > 1 {
                        Text("×\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(event.when).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(event.message ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var typeColor: Color {
        switch event.type {
        case "Warning": return .orange
        case "Normal":  return .green
        default:        return .secondary
        }
    }
}
