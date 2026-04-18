import SwiftUI

struct PodsView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var filter: String = ""
    @State private var mode: ViewMode = .cards

    var filtered: [Pod] {
        guard !filter.isEmpty else { return store.pods }
        let q = filter.lowercased()
        return store.pods.filter {
            $0.name.lowercased().contains(q) || $0.namespace.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(text: $filter,
                      placeholder: "Filter pods by name or namespace",
                      count: filtered.count,
                      trailing: AnyView(ViewModeToggle(mode: $mode)))
            switch mode {
            case .cards: cards
            case .table: table
            }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                ForEach(filtered) { pod in
                    NavigationLink(value: PodRoute(namespace: pod.namespace, name: pod.name)) {
                        ResourceCard(ref: .pod(pod.namespace, pod.name),
                                     namespaceForTint: pod.namespace) {
                            VStack(alignment: .leading, spacing: 6) {
                                PodCardBody(pod: pod)
                                Text(pod.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    private var table: some View {
        Table(filtered) {
            TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                .width(min: 80, ideal: 140)
            TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                .width(min: 160, ideal: 280)
            TableColumn("Ready") { Text($0.readyRatio) }.width(min: 50, ideal: 60)
            TableColumn("Status") { pod in
                Text(pod.phase).foregroundStyle(PodCard.phaseColor(pod.phase))
            }.width(min: 80, ideal: 110)
            TableColumn("Restarts") { Text("\($0.restarts)") }.width(min: 50, ideal: 70)
            TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
            TableColumn("Node") { Text($0.spec?.nodeName ?? "-").foregroundStyle(.secondary) }
                .width(min: 100, ideal: 160)
        }
    }
}

enum PodCard {
    static func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "Running", "Succeeded": return .green
        case "Pending", "ContainerCreating": return .orange
        case "Failed", "Error", "CrashLoopBackOff": return .red
        default: return .secondary
        }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
