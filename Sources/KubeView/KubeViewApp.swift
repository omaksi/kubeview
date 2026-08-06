import SwiftUI

@main
struct KubeViewApp: App {
    @StateObject private var manager = ClusterManager()
    @StateObject private var emojis = EmojiStore()
    @StateObject private var search = SearchState()
    @StateObject private var stars = StarStore()
    @StateObject private var nav = NavState()
    @StateObject private var logs = LogStore.shared
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some Scene {
        WindowGroup("KubeView", id: "main") {
            RootView()
                .environmentObject(manager)
                .environmentObject(emojis)
                .environmentObject(search)
                .environmentObject(stars)
                .environmentObject(nav)
                .environmentObject(logs)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .preferredColorScheme(appearance.colorScheme)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(manager)
                .environmentObject(emojis)
                // The menu bar panel is its own window — it does not inherit the
                // WindowGroup's scheme, so it has to be set here too.
                .preferredColorScheme(appearance.colorScheme)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        let anyFault = manager.activeStores.contains { $0.fault != nil }
        let anyFailing = manager.activeStores.contains { !$0.unhealthyPods.isEmpty }
        let anyDegraded = manager.activeStores.contains { !$0.unhealthyWorkloads.isEmpty }
        // A cluster we can't reach is not "healthy" — before this it showed the
        // plain helm, because a disconnected store has no unhealthy pods to count.
        if anyFault    { return "exclamationmark.triangle.fill" }
        if anyFailing  { return "exclamationmark.triangle.fill" }
        if anyDegraded { return "exclamationmark.circle" }
        return "helm"
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
                ClusterContentView(store: store)
            }
        } else {
            VStack(spacing: 0) {
                ClusterBar()
                EmptyClusterView()
            }
        }
    }
}

/// Observes the selected store directly. `RootView` only watches the manager,
/// and `selectedStore` is computed — reading `lastError` up there would never
/// re-render when a refresh fails.
struct ClusterContentView: View {
    @ObservedObject var store: ClusterStore

    var body: some View {
        VStack(spacing: 0) {
            if let err = store.lastError {
                ErrorBanner(message: err) { Task { await store.refresh() } }
            }
            ContentView().environmentObject(store)
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
