import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var store: ClusterStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            summary
            Divider()
            contextsMenu
            Divider()
            actions
        }
        .frame(width: 280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("KubeView").font(.headline)
            Text(store.currentContext.isEmpty ? "No context" : store.currentContext)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(icon: "server.rack", label: "Nodes ready", value: "\(store.nodesReady)/\(store.nodes.count)", color: store.nodesReady == store.nodes.count ? .green : .orange)
            row(icon: "shippingbox", label: "Pods running", value: "\(store.podsRunning)", color: .green)
            row(icon: "exclamationmark.triangle.fill", label: "Pods failing", value: "\(store.podsFailing)", color: store.podsFailing > 0 ? .red : .secondary)
        }
        .padding(10)
    }

    private func row(icon: String, label: String, value: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(label).font(.callout)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var contextsMenu: some View {
        Menu("Switch Context") {
            ForEach(store.contexts) { ctx in
                Button(ctx.name) {
                    Task { await store.switchContext(ctx.name) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .padding(10)
    }

    private var actions: some View {
        VStack(spacing: 4) {
            Button("Open Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Refresh Now") {
                Task { await store.refresh() }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}
