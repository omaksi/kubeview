import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var names: ClusterNameStore
    @EnvironmentObject var tabs: TabStore
    @Environment(\.openWindow) private var openWindow

    /// One row per tab, not per cluster: two tabs on the same cluster are two
    /// places you work, and the menu bar is a list of those places.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if tabs.tabs.isEmpty {
                Text("No open tabs").font(.caption).foregroundStyle(.secondary).padding(10)
            } else {
                ForEach(tabs.tabs) { tab in
                    if let store = manager.stores[tab.context] {
                        ClusterSummaryRow(ctx: tab.context, store: store,
                                          isSelected: tab.id == tabs.activeID)
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

    private var inactiveContexts: [String] {
        manager.availableContexts.filter { !tabs.openContexts.contains($0) }
    }

    @ViewBuilder
    private var addClusterMenu: some View {
        if inactiveContexts.isEmpty {
            Text(manager.availableContexts.isEmpty ? "No contexts in kubeconfig" : "All contexts active")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            Menu("Open in New Tab…") {
                ForEach(inactiveContexts, id: \.self) { ctx in
                    Button(names.name(for: ctx)) {
                        tabs.open(context: ctx)
                        manager.applyCadence(openContexts: tabs.openContexts,
                                             live: tabs.active?.context)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            MenuActionRow(title: "Open Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuActionRow(title: "Refresh All") {
                for s in manager.activeStores { Task { await s.refresh() } }
            }
            MenuActionRow(title: "Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 4)
    }
}

/// A menu bar panel is a non-activating window that never becomes key, so
/// standard button styles draw in their inactive appearance and read as
/// disabled. Draw the row instead, and keep the hit area full-width — a bare
/// `Button` in a VStack is only as wide as its label, which staggers rows.
struct MenuActionRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.callout).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ClusterSummaryRow: View {
    let ctx: String
    @EnvironmentObject var names: ClusterNameStore
    @ObservedObject var store: ClusterStore
    let isSelected: Bool
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var tabs: TabStore

    private func sync() {
        manager.applyCadence(openContexts: tabs.openContexts, live: tabs.active?.context)
    }

    private var health: Color {
        if let fault = store.fault { return fault.color }
        if store.lastRefresh == nil { return .secondary }
        if !store.unhealthyPods.isEmpty { return .red }
        if !store.unhealthyWorkloads.isEmpty { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(health).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(names.name(for: ctx)).font(.callout.monospaced())
                    if isSelected {
                        Image(systemName: "checkmark").font(.caption2).foregroundStyle(Color.accentColor)
                    }
                }
                HStack(spacing: 10) {
                    if let fault = store.fault {
                        Label(fault.short, systemImage: fault.icon)
                            .font(.caption)
                            .foregroundStyle(fault.color)
                    } else {
                        Text("\(store.podsRunning) running").font(.caption).foregroundStyle(.secondary)
                        if !store.unhealthyAll.isEmpty {
                            Text("\(store.unhealthyAll.count) unhealthy").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Spacer()
            Button {
                if let tab = tabs.tabs.first(where: { $0.context == ctx }) {
                    tabs.close(tab.id)
                    sync()
                }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close this tab")
        }
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture {
            if let tab = tabs.tabs.first(where: { $0.context == ctx }) {
                tabs.focus(tab.id)
                sync()
            }
        }
    }
}
