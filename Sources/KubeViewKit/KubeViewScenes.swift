import SwiftUI
import KubeModel
import KubeClient
import KubeUI


/// The whole scene graph. Lives in the kit rather than the executable so test
/// targets can import it - a test target cannot reliably import an executable.
public struct KubeViewScenes: Scene {
    @StateObject private var manager = ClusterManager()
    @StateObject private var emojis = EmojiStore()
    @StateObject private var search = SearchState()
    @StateObject private var stars = StarStore()
    @StateObject private var nav = NavState()
    @StateObject private var logs = LogStore.shared
    @StateObject private var aws = AwsStore()
    @StateObject private var names = ClusterNameStore()
    @StateObject private var tabs = TabStore()
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    public init() {}

    public var body: some Scene {
        WindowGroup("KubeView", id: "main") {
            RootView()
                .environmentObject(manager)
                .environmentObject(emojis)
                .environmentObject(search)
                .environmentObject(stars)
                .environmentObject(nav)
                .environmentObject(logs)
                .environmentObject(aws)
                .environmentObject(names)
                .environmentObject(tabs)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { aws.onCredentialsChanged = { await manager.retryFaulted() } }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { TabCommands(tabs: tabs, manager: manager) }

        Settings {
            SettingsView()
                .environmentObject(manager)
                .environmentObject(names)
                // AWS and Diagnostics moved in from the sidebar, and bring their
                // own dependencies. Settings is its own window, so nothing is
                // inherited from the WindowGroup.
                .environmentObject(aws)
                .environmentObject(search)
                .environmentObject(logs)
                .preferredColorScheme(appearance.colorScheme)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(manager)
                .environmentObject(emojis)
                .environmentObject(names)
                .environmentObject(tabs)
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
    @EnvironmentObject var tabs: TabStore

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            if let tab = tabs.active, let store = manager.stores[tab.context] {
                ContextBar(store: store)
                ClusterContentView(store: store)
            } else {
                EmptyClusterView()
            }
        }
        .task {
            // Order matters: contexts have to be known before tabs can be
            // filtered against them, and cadence can't be applied until the
            // tab set is final.
            await manager.reloadContexts()
            let current = try? await KubectlService().currentContext()
            tabs.bootstrap(availableContexts: manager.availableContexts,
                           current: current)
            manager.applyCadence(openContexts: tabs.openContexts,
                                 live: tabs.active?.context)
            // The focused tab's namespace has to reach the store, which is what
            // every list view actually filters on.
            if let tab = tabs.active {
                manager.stores[tab.context]?.namespaceFilter = tab.namespace
            }
        }
        .onChange(of: tabs.activeID) { _, _ in
            guard let tab = tabs.active else { return }
            manager.stores[tab.context]?.namespaceFilter = tab.namespace
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
