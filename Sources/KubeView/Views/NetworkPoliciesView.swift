import SwiftUI

struct NetworkPoliciesView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [NetworkPolicy] {
        store.networkPolicies.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "policies") { ViewModeToggle(mode: $mode) }
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { np in
                            ResourceCard(ref: .init(kind: .networkPolicy, key: np.id)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        ResourceTitle(ref: .init(kind: .networkPolicy, key: np.id), name: np.name)
                                        Spacer()
                                        if !np.policyTypes.isEmpty {
                                            Text(np.policyTypes.joined(separator: "+"))
                                                .font(.caption2).foregroundStyle(.purple)
                                        }
                                    }
                                    Text(np.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    HStack(spacing: 12) {
                                        mini("Ingress", "\(np.ingressRuleCount)")
                                        mini("Egress", "\(np.egressRuleCount)")
                                        mini("Age", np.age)
                                    }
                                    if !np.podSelector.isEmpty {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("selects").font(.caption2).foregroundStyle(.secondary)
                                            Text(np.podSelector.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                                                .font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                                        }
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
                    TableColumn("Types") { Text($0.policyTypes.joined(separator: "+")) }
                    TableColumn("Ingress") { Text("\($0.ingressRuleCount)") }.width(min: 50, ideal: 70)
                    TableColumn("Egress") { Text("\($0.egressRuleCount)") }.width(min: 50, ideal: 70)
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}

private func mini(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.caption.monospacedDigit())
    }
}
