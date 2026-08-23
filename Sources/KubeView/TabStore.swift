import Foundation
import SwiftUI

/// One tab is a saved position: a cluster, a namespace, and the view you were
/// reading. Not a window — several tabs can share one cluster, and they share
/// its `ClusterStore` too. The tab owns *where you're looking*; the store owns
/// *the data*, so two tabs on the same cluster never fetch it twice.
struct WorkspaceTab: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var context: String
    /// nil = all namespaces.
    var namespace: String?
    var view: NavSection = .overview

    /// Drill-down isn't restored across a tab switch — see TabStore's note.
    var title: String { context }
    var subtitle: String { namespace ?? "All Namespaces" }
}

/// Tabs, their order, and which one has focus. Persisted so the workspace
/// survives a relaunch — but see `ClusterManager.applyCadence`: restoring a tab
/// deliberately does *not* connect to its cluster. Nothing fetches until you
/// look at it.
///
/// ponytail: `nav.path` (the drill-down stack) stays global and resets when you
/// switch tabs, rather than being stored per tab. Restoring "you were three
/// levels into a pod" is a bigger promise than this needs to make yet; the
/// upgrade path is moving `[AppRoute]` onto WorkspaceTab, which is Codable
/// already.
@MainActor
final class TabStore: ObservableObject {
    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published private(set) var activeID: UUID?
    /// Closed tabs, newest last — ⌘⇧T territory.
    private var closed: [WorkspaceTab] = []

    private let defaultsKey = "kubeview.tabs"
    private let activeKey = "kubeview.activeTab"
    /// False only for the DEBUG self-check instances. Without this, asserting on
    /// close/focus behaviour would write test tabs into the real preferences and
    /// wipe the user's workspace at every debug launch.
    private let persists: Bool

    var active: WorkspaceTab? {
        guard let activeID else { return nil }
        return tabs.first { $0.id == activeID }
    }

    var activeIndex: Int? {
        guard let activeID else { return nil }
        return tabs.firstIndex { $0.id == activeID }
    }

    /// Every context with a tab open. These get the cheap probe; the active
    /// one gets real fetching.
    var openContexts: Set<String> { Set(tabs.map(\.context)) }

    init() {
        persists = true
        load()
        #if DEBUG
        Self.selfCheck()
        #endif
    }

    // MARK: - Mutation

    /// Restores tabs from a previous launch, or seeds one. Contexts that have
    /// vanished from the kubeconfig are dropped — a tab pointing at nothing
    /// would probe forever and never succeed.
    func bootstrap(availableContexts: [String], current: String?) {
        tabs.removeAll { !availableContexts.contains($0.context) }
        if tabs.isEmpty {
            let seed = current ?? availableContexts.first
            if let seed { tabs = [WorkspaceTab(context: seed, namespace: nil)] }
        }
        if activeID == nil || !tabs.contains(where: { $0.id == activeID }) {
            activeID = tabs.first?.id
        }
        save()
    }

    func focus(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
    }

    func focus(index: Int) {
        guard tabs.indices.contains(index) else { return }
        focus(tabs[index].id)
    }

    func focusNext(by step: Int) {
        guard let i = activeIndex, !tabs.isEmpty else { return }
        let n = tabs.count
        focus(index: ((i + step) % n + n) % n)
    }

    @discardableResult
    func open(context: String, namespace: String? = nil, view: NavSection = .overview) -> UUID {
        let tab = WorkspaceTab(context: context, namespace: namespace, view: view)
        if let i = activeIndex { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        activeID = tab.id
        save()
        return tab.id
    }

    /// Closing the last tab is refused rather than leaving an empty window with
    /// no way back — there's no "new tab" affordance once the strip is gone.
    func close(_ id: UUID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        closed.append(tabs[i])
        tabs.remove(at: i)
        if activeID == id {
            activeID = tabs[min(i, tabs.count - 1)].id
        }
        save()
    }

    func reopenClosed() {
        guard let tab = closed.popLast() else { return }
        tabs.append(tab)
        activeID = tab.id
        save()
    }

    /// Repointing at a different cluster is a new connection; the caller is
    /// expected to re-apply cadence afterwards.
    func setContext(_ context: String, for id: UUID) {
        update(id) { $0.context = context }
    }

    func setNamespace(_ namespace: String?, for id: UUID) {
        update(id) { $0.namespace = namespace }
    }

    func setView(_ view: NavSection, for id: UUID) {
        update(id) { $0.view = view }
    }

    private func update(_ id: UUID, _ body: (inout WorkspaceTab) -> Void) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&tabs[i])
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(tabs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: activeKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([WorkspaceTab].self, from: data) {
            tabs = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: activeKey) {
            activeID = UUID(uuidString: raw)
        }
    }

    #if DEBUG
    static func selfCheck() {
        // Closing never empties the strip, and focus lands on a neighbour.
        let s = TabStore(fresh: [WorkspaceTab(context: "a"), WorkspaceTab(context: "b")])
        let first = s.tabs[0].id
        s.focus(first)
        s.close(first)
        assert(s.tabs.count == 1, "one tab must always survive")
        assert(s.activeID == s.tabs[0].id, "focus follows to the remaining tab")
        s.close(s.tabs[0].id)
        assert(s.tabs.count == 1, "closing the last tab is refused")

        // Wrapping in both directions, so ⌃⇥ and ⌃⇧⇥ can share one call.
        let w = TabStore(fresh: [WorkspaceTab(context: "a"),
                                 WorkspaceTab(context: "b"),
                                 WorkspaceTab(context: "c")])
        w.focus(index: 2)
        w.focusNext(by: 1)
        assert(w.activeIndex == 0, "next wraps past the end")
        w.focusNext(by: -1)
        assert(w.activeIndex == 2, "previous wraps past the start")

        // A tab whose context left the kubeconfig is dropped, not left probing.
        let b = TabStore(fresh: [WorkspaceTab(context: "gone"), WorkspaceTab(context: "a")])
        b.bootstrap(availableContexts: ["a"], current: "a")
        assert(b.tabs.map(\.context) == ["a"], "stale contexts are dropped")
        assert(b.activeID != nil, "bootstrap always leaves something focused")
    }

    /// Test-only seed: never reads or writes UserDefaults.
    private init(fresh: [WorkspaceTab]) {
        persists = false
        tabs = fresh
        activeID = fresh.first?.id
    }
    #endif
}
