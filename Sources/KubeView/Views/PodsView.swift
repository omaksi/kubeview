import SwiftUI

struct PodsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [Pod] {
        store.pods.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "pods") { ViewModeToggle(mode: $mode) }
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
                    NavigationLink(value: AppRoute.pod(PodRoute(namespace: pod.namespace, name: pod.name))) {
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
