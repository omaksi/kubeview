import SwiftUI

struct ServiceAccountsView: View {
    let irsaOnly: Bool
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var all: [ServiceAccount] {
        irsaOnly ? store.serviceAccounts.filter { $0.irsaRoleArn != nil } : store.serviceAccounts
    }

    var filtered: [ServiceAccount] {
        all.searchFiltered(search) { [$0.name, $0.namespace, $0.irsaRoleArn ?? ""] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count,
                       label: irsaOnly ? "IRSA SAs" : "SAs") {
                ViewModeToggle(mode: $mode)
            }
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
                ResourceTitle(ref: .init(kind: irsaOnly ? .irsa : .serviceAccount, key: sa.id),
                              name: sa.name)
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
