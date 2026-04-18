import SwiftUI

struct ServiceAccountsView: View {
    let irsaOnly: Bool
    @EnvironmentObject var store: ClusterStore
    @State private var filter: String = ""
    @State private var mode: ViewMode = .cards

    var all: [ServiceAccount] {
        irsaOnly ? store.serviceAccounts.filter { $0.irsaRoleArn != nil } : store.serviceAccounts
    }

    var filtered: [ServiceAccount] {
        guard !filter.isEmpty else { return all }
        let q = filter.lowercased()
        return all.filter {
            $0.name.lowercased().contains(q) ||
            $0.namespace.lowercased().contains(q) ||
            ($0.irsaRoleArn ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(text: $filter,
                      placeholder: irsaOnly ? "Filter by SA name or role ARN" : "Filter service accounts",
                      count: filtered.count,
                      trailing: { ViewModeToggle(mode: $mode) })
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { sa in
                            ResourceCard(ref: .init(kind: irsaOnly ? .irsa : .serviceAccount, key: sa.id)) {
                                saCard(sa: sa)
                            }
                        }
                    }.padding(12)
                }
            case .table:
                if irsaOnly {
                    Table(filtered) {
                        TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                        TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                        TableColumn("Role ARN") { sa in
                            Text(sa.irsaRoleArn ?? "-")
                                .font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                        }
                        TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                    }
                } else {
                    Table(filtered) {
                        TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                        TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                        TableColumn("IRSA") { sa in
                            if sa.irsaRoleArn != nil {
                                Label("yes", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }.width(min: 50, ideal: 70)
                        TableColumn("Secrets") { Text("\($0.secrets?.count ?? 0)") }.width(min: 50, ideal: 70)
                        TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                    }
                }
            }
        }
    }

    private func saCard(sa: ServiceAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sa.name).font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if sa.irsaRoleArn != nil {
                    StatusBadge(text: "IRSA", color: .orange)
                }
            }
            Text(sa.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
            if let arn = sa.irsaRoleArn {
                HStack(spacing: 4) {
                    Image(systemName: "person.badge.shield.checkmark").font(.caption2).foregroundStyle(.orange)
                    Text(arn)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 12) {
                if let count = sa.secrets?.count {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Secrets").font(.caption2).foregroundStyle(.secondary)
                        Text("\(count)").font(.caption.monospacedDigit())
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Age").font(.caption2).foregroundStyle(.secondary)
                    Text(sa.age).font(.caption.monospacedDigit())
                }
            }
        }
    }
}
