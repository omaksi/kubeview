import SwiftUI

// MARK: - DaemonSets

struct DaemonSetsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [DaemonSet] {
        store.daemonSets.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "daemonsets") { ViewModeToggle(mode: $mode) }
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { ds in
                            let ref = ResourceRef(kind: .daemonSet, key: ds.id)
                            ResourceCard(ref: ref) {
                                WorkloadCardBody(
                                    ref: ref,
                                    name: ds.name, namespace: ds.namespace,
                                    desired: ds.desired, ready: ds.ready,
                                    kindLabel: "DaemonSet", strategy: nil,
                                    healthy: ds.isHealthy, reason: ds.unhealthyReason, age: ds.age
                                )
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(filtered) {
                    TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Desired") { Text("\($0.desired)") }.width(min: 50, ideal: 70)
                    TableColumn("Ready") { ds in
                        Text("\(ds.ready)").foregroundStyle(ds.isHealthy ? Color.primary : Color.orange)
                    }.width(min: 50, ideal: 70)
                    TableColumn("Available") { Text("\($0.available)") }.width(min: 60, ideal: 80)
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}

// MARK: - ConfigMaps

struct ConfigMapsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [ConfigMap] {
        store.configMaps.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "configmaps") { ViewModeToggle(mode: $mode) }
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { cm in
                            ResourceCard(ref: .init(kind: .configMap, key: cm.id)) {
                                ConfigMapCardBody(configMap: cm)
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(filtered) {
                    TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Keys") { Text("\($0.textKeys.count + $0.binaryKeys.count)") }.width(min: 50, ideal: 70)
                    TableColumn("Size") { Text(ResourceParser.formatBytes(Double($0.sizeBytes))) }
                        .width(min: 70, ideal: 90)
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}

struct ConfigMapCardBody: View {
    let configMap: ConfigMap
    @State private var expanded: Set<String> = []

    private func toggle(_ k: String) {
        if expanded.contains(k) { expanded.remove(k) } else { expanded.insert(k) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ResourceTitle(ref: .init(kind: .configMap, key: configMap.id), name: configMap.name)
                Spacer()
                Text("\(configMap.textKeys.count + configMap.binaryKeys.count) keys")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(configMap.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Size").font(.caption2).foregroundStyle(.secondary)
                    Text(ResourceParser.formatBytes(Double(configMap.sizeBytes)))
                        .font(.caption.monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Age").font(.caption2).foregroundStyle(.secondary)
                    Text(configMap.age).font(.caption.monospacedDigit())
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(configMap.textKeys.prefix(6), id: \.self) { k in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            toggle(k)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: expanded.contains(k) ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 10)
                                Text(k).font(.caption.monospaced())
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if expanded.contains(k), let v = configMap.data?[k] {
                            Text(v)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(10)
                                .textSelection(.enabled)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                if configMap.textKeys.count > 6 {
                    Text("+\(configMap.textKeys.count - 6) more keys").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - HPAs

struct HPAsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [HPA] {
        store.hpas.searchFiltered(search) { [$0.name, $0.namespace, $0.targetName] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "HPAs") { ViewModeToggle(mode: $mode) }
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { h in
                            ResourceCard(ref: .init(kind: .hpa, key: h.id)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        ResourceTitle(ref: .init(kind: .hpa, key: h.id), name: h.name)
                                        Spacer()
                                        StatusBadge(text: "\(h.currentReplicas)/\(h.desiredReplicas)",
                                                    color: replicasColor(h))
                                    }
                                    Text(h.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                        Text("\(h.targetKind)/\(h.targetName)")
                                            .font(.caption.monospaced())
                                    }
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Replicas").font(.caption2).foregroundStyle(.secondary)
                                            Text("\(h.minReplicas)–\(h.maxReplicas)")
                                                .font(.caption.monospacedDigit())
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Age").font(.caption2).foregroundStyle(.secondary)
                                            Text(h.age).font(.caption.monospacedDigit())
                                        }
                                    }
                                    if !h.metricSummary.isEmpty {
                                        Text(h.metricSummary)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(filtered) {
                    TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Target") { Text("\($0.targetKind)/\($0.targetName)").font(.caption.monospaced()) }
                    TableColumn("Replicas") { Text("\($0.currentReplicas)/\($0.desiredReplicas)") }
                        .width(min: 70, ideal: 90)
                    TableColumn("Range") { Text("\($0.minReplicas)–\($0.maxReplicas)") }.width(min: 60, ideal: 80)
                    TableColumn("Metrics") { Text($0.metricSummary).font(.caption.monospaced()) }
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }

    private func replicasColor(_ h: HPA) -> Color {
        if h.currentReplicas >= h.maxReplicas { return .orange }
        if h.currentReplicas <= h.minReplicas { return .secondary }
        return .green
    }
}

// MARK: - Cluster Events (lazy)

@MainActor
final class AllEventsLoader: ObservableObject {
    @Published var events: [KubeEvent] = []
    @Published var loading = false
    @Published var error: String?
    @Published var warningsOnly = true

    private let kubectl: KubectlService

    init(context: String) {
        self.kubectl = KubectlService(context: context)
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            events = try await kubectl.allEvents(warningsOnly: warningsOnly)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct EventsView: View {
    @EnvironmentObject var store: ClusterStore
    @StateObject private var loader: AllEventsLoader
    @State private var filter = ""

    init(store: ClusterStore) {
        _loader = StateObject(wrappedValue: AllEventsLoader(context: store.context))
    }

    /// Convenience init for use inside NavigationStack — reads context from env.
    init() {
        // Placeholder; overridden below via .task
        _loader = StateObject(wrappedValue: AllEventsLoader(context: ""))
    }

    var filtered: [KubeEvent] {
        guard !filter.isEmpty else { return loader.events }
        let q = filter.lowercased()
        return loader.events.filter {
            ($0.reason ?? "").lowercased().contains(q) ||
            ($0.message ?? "").lowercased().contains(q) ||
            ($0.involvedObject?.name ?? "").lowercased().contains(q) ||
            ($0.metadata.namespace ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter events", text: $filter).textFieldStyle(.plain)
                Spacer()
                Toggle("Warnings only", isOn: $loader.warningsOnly)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: loader.warningsOnly) { _, _ in Task { await loader.load() } }
                Button {
                    Task { await loader.load() }
                } label: {
                    if loader.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loader.loading)
                Text("\(filtered.count)").foregroundStyle(.secondary).font(.caption)
            }
            .padding(8).background(.bar)

            if let err = loader.error {
                Text(err).font(.caption.monospaced()).foregroundStyle(.red).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { event in
                        EventRow(event: event)
                    }
                    if filtered.isEmpty && !loader.loading {
                        Text("No events")
                            .foregroundStyle(.secondary).font(.caption)
                            .padding()
                    }
                }
                .padding(10)
            }
        }
        .task { await loader.load() }
    }
}
