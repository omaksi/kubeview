import SwiftUI

@main
struct KubeViewApp: App {
    @StateObject private var manager = ClusterManager()
    @StateObject private var emojis = EmojiStore()
    @StateObject private var search = SearchState()
    @StateObject private var stars = StarStore()
    @StateObject private var nav = NavState()

    var body: some Scene {
        WindowGroup("KubeView", id: "main") {
            RootView()
                .environmentObject(manager)
                .environmentObject(emojis)
                .environmentObject(search)
                .environmentObject(stars)
                .environmentObject(nav)
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
    @EnvironmentObject var nav: NavState

    var body: some View {
        if let store = manager.selectedStore {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ClusterBar()
                    GlobalSearchBar()
                        .frame(width: 260)
                }
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                TopLoadingBar(visible: store.loading && store.lastRefresh == nil)
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

struct GlobalSearchBar: View {
    @EnvironmentObject var search: SearchState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search resources (⌘F)", text: $search.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { focused = false }
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0)
        )
    }
}
