import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var manager: ClusterManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if manager.activeStores.isEmpty {
                Text("No active clusters").font(.caption).foregroundStyle(.secondary).padding(10)
            } else {
                ForEach(manager.activeOrder, id: \.self) { ctx in
                    if let store = manager.stores[ctx] {
                        ClusterSummaryRow(ctx: ctx, store: store,
                                          isSelected: manager.selected == ctx)
                    }
                }
            }
            Divider()
            addClusterMenu
            Divider()
            actions
        }
        .frame(width: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("KubeView").font(.headline)
            Text("\(manager.activeOrder.count) active cluster\(manager.activeOrder.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addClusterMenu: some View {
        Menu("Activate Cluster…") {
            ForEach(manager.availableContexts.filter { !manager.activeOrder.contains($0) }, id: \.self) { ctx in
                Button(ctx) { manager.activate(ctx); manager.select(ctx) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var actions: some View {
        VStack(spacing: 4) {
            Button("Open Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Refresh All") {
                for s in manager.activeStores { Task { await s.refresh() } }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

struct ClusterSummaryRow: View {
    let ctx: String
    @ObservedObject var store: ClusterStore
    let isSelected: Bool
    @EnvironmentObject var manager: ClusterManager

    private var health: Color {
        if !store.unhealthyPods.isEmpty { return .red }
        if !store.unhealthyWorkloads.isEmpty { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(health).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ctx).font(.callout.monospaced())
                    if isSelected {
                        Image(systemName: "checkmark").font(.caption2).foregroundStyle(Color.accentColor)
                    }
                }
                HStack(spacing: 10) {
                    Text("\(store.podsRunning) running").font(.caption).foregroundStyle(.secondary)
                    if !store.unhealthyAll.isEmpty {
                        Text("\(store.unhealthyAll.count) unhealthy").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button {
                manager.deactivate(ctx)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture { manager.select(ctx) }
    }
}
