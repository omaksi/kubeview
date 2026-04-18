import SwiftUI

@main
struct KubeViewApp: App {
    @StateObject private var store = ClusterStore()
    @StateObject private var emojis = EmojiStore()

    var body: some Scene {
        WindowGroup("KubeView", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(emojis)
                .frame(minWidth: 900, minHeight: 560)
                .task { store.start() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarContent().environmentObject(store).environmentObject(emojis)
        } label: {
            Label {
                Text("KubeView")
            } icon: {
                Image(systemName: menuIcon)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if store.podsFailing > 0 { return "exclamationmark.triangle.fill" }
        if store.nodesReady < store.nodes.count { return "exclamationmark.circle" }
        return "circle.grid.3x3.fill"
    }
}
