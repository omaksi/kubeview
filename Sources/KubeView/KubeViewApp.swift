import SwiftUI

@main
struct KubeViewApp: App {
    @StateObject private var manager = ClusterManager()
    @StateObject private var emojis = EmojiStore()

    var body: some Scene {
        WindowGroup("KubeView", id: "main") {
            RootView()
                .environmentObject(manager)
                .environmentObject(emojis)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(manager)
                .environmentObject(emojis)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        let anyFailing = manager.activeStores.contains { !$0.unhealthyPods.isEmpty }
        let anyDegraded = manager.activeStores.contains { !$0.unhealthyWorkloads.isEmpty }
        if anyFailing  { return "exclamationmark.triangle.fill" }
        if anyDegraded { return "exclamationmark.circle" }
        return "binoculars.fill"
    }
}

struct RootView: View {
    @EnvironmentObject var manager: ClusterManager

    var body: some View {
        if let store = manager.selectedStore {
            VStack(spacing: 0) {
                ClusterBar()
                ContentView().environmentObject(store)
            }
        } else {
            VStack(spacing: 0) {
                ClusterBar()
                EmptyClusterView()
            }
        }
    }
}
