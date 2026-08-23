import Foundation
import SwiftUI
import KubeModel
import KubeClient
import KubeUI

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

        // Record whatever we settled on, including the very first run. Without
        // this, `activate(persist: false)` above means the active set is only
        // ever written when the user adds or removes a cluster by hand — so an
        // untouched install re-derives from `kubectl config current-context` at
        // every launch and silently follows the terminal around, which defeats
        // the point of not mutating the kubeconfig in the first place.
        persistActive()
    }

    /// Re-read the kubeconfig context list without disturbing active clusters.
    /// Only `bootstrap()` did this, and it runs once from `init()`, so a context
    /// added to the kubeconfig after launch stayed invisible until a restart.
    func reloadContexts() async {
        do {
            availableContexts = try await KubectlService().contexts().map(\.name)
            bootstrapError = nil
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    /// The store for a context, created on demand. Stores are shared: two tabs
    /// on the same cluster get the same one, so the cluster is never fetched
    /// twice. A newly created store is `.idle` — creating it must not start any
    /// network work, or restoring tabs at launch would connect to everything.
    func store(for context: String) -> ClusterStore {
        if let existing = stores[context] { return existing }
        let store = ClusterStore(context: context)
        stores[context] = store
        return store
    }

    /// The whole lifecycle in one place: exactly one cluster fetches, every
    /// other cluster with a tab open probes, and anything else is torn down.
    ///
    /// Called on every tab focus, open, close and repoint. It's idempotent —
    /// `goLive`/`goBackground` return immediately if the cadence already
    /// matches — so calling it more often than strictly necessary is free.
    func applyCadence(openContexts: Set<String>, live: String?) {
        for context in openContexts where stores[context] == nil {
            _ = store(for: context)
        }
        for (context, store) in stores {
            if context == live {
                store.goLive()
            } else if openContexts.contains(context) {
                store.goBackground()
            } else {
                // No tab refers to it: stop the loop and drop the data.
                store.stop()
                stores.removeValue(forKey: context)
            }
        }
    }

    func activate(_ ctx: String, persist: Bool = true) {
        guard stores[ctx] == nil else {
            if selected == nil { selected = ctx }
            return
        }
        let store = ClusterStore(context: ctx)
        stores[ctx] = store
        // Deliberately does not start polling. Cadence belongs to
        // `applyCadence`, driven by which tabs are open and which has focus —
        // a store that started itself here would poll with no tab to show it.
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

    /// Retry every cluster that currently can't be reached. Called when AWS
    /// credentials change on disk — a fresh token usually un-breaks several
    /// clusters at once, and waiting out the 5s poll makes the login feel dead.
    /// Awaits the refreshes rather than firing and forgetting, so the caller
    /// can keep showing progress until the clusters are actually back.
    func retryFaulted() async {
        await withTaskGroup(of: Void.self) { group in
            for store in activeStores where store.fault != nil {
                group.addTask { await store.refresh() }
            }
        }
    }

    private func persistActive() {
        UserDefaults.standard.set(activeOrder, forKey: defaultsActiveKey)
        if let selected {
            UserDefaults.standard.set(selected, forKey: defaultsSelectedKey)
        }
    }
}
