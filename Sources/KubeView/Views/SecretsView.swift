import SwiftUI

struct SecretsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [Secret] {
        store.secrets.searchFiltered(search) { [$0.name, $0.namespace, $0.type ?? ""] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "secrets") { ViewModeToggle(mode: $mode) }
            switch mode {
            case .cards: cards
            case .table: table
            }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                ForEach(filtered) { s in
                    ResourceCard(ref: .init(kind: .secret, key: s.id)) {
                        SecretCardBody(secret: s)
                    }
                }
            }
            .padding(12)
        }
    }

    private var table: some View {
        Table(filtered) {
            TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
            TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
            TableColumn("Type") { Text($0.type ?? "-").foregroundStyle(.secondary) }
            TableColumn("Keys") { Text("\($0.keys.count)") }.width(min: 50, ideal: 70)
            TableColumn("Size") { Text(ResourceParser.formatBytes(Double($0.sizeBytes))) }
                .width(min: 70, ideal: 90)
            TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
        }
    }
}

struct SecretCardBody: View {
    let secret: Secret
    @State private var revealed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ResourceTitle(ref: .init(kind: .secret, key: secret.id), name: secret.name)
                Spacer()
                StatusBadge(text: typeBadge, color: .red)
            }
            Text(secret.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                mini("Keys", "\(secret.keys.count)")
                mini("Size", ResourceParser.formatBytes(Double(secret.sizeBytes)))
                mini("Age", secret.age)
            }

            if !secret.keys.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(secret.keys.prefix(4), id: \.self) { k in
                        SecretKeyRow(
                            secret: secret,
                            key: k,
                            revealed: revealed.contains(k),
                            toggle: {
                                if revealed.contains(k) { revealed.remove(k) }
                                else { revealed.insert(k) }
                            }
                        )
                    }
                    if secret.keys.count > 4 {
                        Text("+\(secret.keys.count - 4) more").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var typeBadge: String {
        let t = secret.type ?? "Opaque"
        return t.split(separator: "/").last.map(String.init) ?? t
    }

    private func mini(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

struct SecretKeyRow: View {
    let secret: Secret
    let key: String
    let revealed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: revealed ? "eye.fill" : "eye.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .onTapGesture(perform: toggle)
            Text(key).font(.caption.monospaced())
            Spacer()
            if revealed, let value = secret.decoded(key) {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("••••")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
