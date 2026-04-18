import Foundation
import SwiftUI

@MainActor
final class ClusterManager: ObservableObject {
    @Published var availableContexts: [String] = []
    @Published var activeOrder: [String] = []
    @Published var selected: String?
    @Published private(set) var stores: [String: ClusterStore] = [:]
    @Published var bootstrapError: String?

    private let defaultsActiveKey = "kubeview.activeContexts"
    private let defaultsSelectedKey = "kubeview.selectedContext"

    init() {
        Task { await bootstrap() }
    }

    /// Load kubeconfig once using a context-less service, then auto-activate the
    /// last selected (or current) context.
    func bootstrap() async {
        let probe = KubectlService()
        do {
            availableContexts = try await probe.contexts().map(\.name)
        } catch {
            bootstrapError = error.localizedDescription
            return
        }

        let defaults = UserDefaults.standard
        let saved = (defaults.stringArray(forKey: defaultsActiveKey) ?? [])
            .filter { availableContexts.contains($0) }

        var toActivate = saved
        if toActivate.isEmpty {
            if let current = try? await probe.currentContext(), !current.isEmpty {
                toActivate = [current]
            } else if let first = availableContexts.first {
                toActivate = [first]
            }
        }

        for ctx in toActivate { activate(ctx, persist: false) }

        if let savedSelected = defaults.string(forKey: defaultsSelectedKey),
           activeOrder.contains(savedSelected) {
            selected = savedSelected
        } else {
            selected = activeOrder.first
        }
    }

    func activate(_ ctx: String, persist: Bool = true) {
        guard stores[ctx] == nil else {
            if selected == nil { selected = ctx }
            return
        }
        let store = ClusterStore(context: ctx)
        stores[ctx] = store
        store.start()
        activeOrder.append(ctx)
        if selected == nil { selected = ctx }
        if persist { persistActive() }
    }

    func deactivate(_ ctx: String) {
        stores[ctx]?.stop()
        stores.removeValue(forKey: ctx)
        activeOrder.removeAll { $0 == ctx }
        if selected == ctx { selected = activeOrder.first }
        persistActive()
    }

    func select(_ ctx: String) {
        guard stores[ctx] != nil else { return }
        selected = ctx
        UserDefaults.standard.set(ctx, forKey: defaultsSelectedKey)
    }

    var selectedStore: ClusterStore? {
        guard let s = selected else { return nil }
        return stores[s]
    }

    var activeStores: [ClusterStore] {
        activeOrder.compactMap { stores[$0] }
    }

    /// Cluster-wide unhealthy aggregate for the tray icon.
    var anyClusterUnhealthy: Bool {
        activeStores.contains { !$0.unhealthyAll.isEmpty }
    }

    private func persistActive() {
        UserDefaults.standard.set(activeOrder, forKey: defaultsActiveKey)
        if let selected {
            UserDefaults.standard.set(selected, forKey: defaultsSelectedKey)
        }
    }
}
