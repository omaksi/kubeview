import SwiftUI

struct NetworkPoliciesView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var filter: String = ""
    @State private var mode: ViewMode = .cards

    var filtered: [NetworkPolicy] {
        guard !filter.isEmpty else { return store.networkPolicies }
        let q = filter.lowercased()
        return store.networkPolicies.filter {
            $0.name.lowercased().contains(q) || $0.namespace.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(text: $filter, placeholder: "Filter network policies",
                      count: filtered.count,
                      trailing: { ViewModeToggle(mode: $mode) })
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { np in
                            ResourceCard(ref: .init(kind: .networkPolicy, key: np.id)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(np.name).font(.system(.callout, design: .monospaced).weight(.semibold))
                                            .lineLimit(1).truncationMode(.middle)
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
