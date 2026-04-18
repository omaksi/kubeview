import SwiftUI

struct PVCsView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var filter: String = ""
    @State private var mode: ViewMode = .cards

    var filtered: [PVC] {
        guard !filter.isEmpty else { return store.pvcs }
        let q = filter.lowercased()
        return store.pvcs.filter {
            $0.name.lowercased().contains(q) || $0.namespace.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(text: $filter, placeholder: "Filter PVCs",
                      count: filtered.count,
                      trailing: { ViewModeToggle(mode: $mode) })
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { pvc in
                            ResourceCard(ref: .init(kind: .pvc, key: pvc.id)) {
                                PVCCardBody(pvc: pvc)
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(filtered) {
                    TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Status") { pvc in
                        Text(pvc.phase).foregroundStyle(pvc.phase == "Bound" ? .green : .orange)
                    }.width(min: 70, ideal: 90)
                    TableColumn("Capacity") { Text($0.capacity) }.width(min: 70, ideal: 90)
                    TableColumn("StorageClass") { Text($0.storageClass).foregroundStyle(.secondary) }
                    TableColumn("Volume") { Text($0.volumeName).foregroundStyle(.secondary) }
                    TableColumn("Access") { Text($0.accessModes.joined(separator: ",")).font(.caption.monospaced()) }
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}

struct PVCCardBody: View {
    let pvc: PVC
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pvc.name).font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                StatusBadge(text: pvc.phase, color: pvc.phase == "Bound" ? .green : .orange)
            }
            Text(pvc.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                mini("Capacity", pvc.capacity)
                mini("Class", pvc.storageClass)
                mini("Age", pvc.age)
            }
            if !pvc.accessModes.isEmpty {
                Text(pvc.accessModes.joined(separator: ", "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
    private func mini(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

struct StorageClassesView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var mode: ViewMode = .cards

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                ViewModeToggle(mode: $mode)
                Text("\(store.storageClasses.count)").foregroundStyle(.secondary).font(.caption)
            }
            .padding(8).background(.bar)

            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                        ForEach(store.storageClasses) { sc in
                            ResourceCard(ref: .init(kind: .storageClass, key: sc.name)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(sc.name).font(.system(.callout, design: .monospaced).weight(.semibold))
                                    HStack(spacing: 4) {
                                        Image(systemName: "gear").font(.caption2).foregroundStyle(.secondary)
                                        Text(sc.provisioner ?? "-").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 10) {
                                        Text("reclaim: \(sc.reclaimPolicy ?? "-")").font(.caption2).foregroundStyle(.secondary)
                                        Text("bind: \(sc.volumeBindingMode ?? "-")").font(.caption2).foregroundStyle(.secondary)
                                        if sc.allowVolumeExpansion == true {
                                            Text("expandable").font(.caption2).foregroundStyle(.green)
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(store.storageClasses) {
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Provisioner") { Text($0.provisioner ?? "-").font(.caption.monospaced()) }
                    TableColumn("Reclaim") { Text($0.reclaimPolicy ?? "-").foregroundStyle(.secondary) }
                    TableColumn("Binding") { Text($0.volumeBindingMode ?? "-").foregroundStyle(.secondary) }
                    TableColumn("Expand") { Text($0.allowVolumeExpansion == true ? "yes" : "no") }
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}
