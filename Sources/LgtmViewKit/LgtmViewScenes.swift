import SwiftUI
import KubeModel
import KubeClient
import KubeUI

/// The whole scene graph for the standalone LGTM app. Lives in the kit rather
/// than the executable so test targets can import it - a test target cannot
/// reliably import an executable target, and the assertions worth having
/// (medians, ratios, node levels, Kahn tiering) live in kit code.
public struct LgtmViewScenes: Scene {
    @StateObject private var emojis = EmojiStore()

    public init() {}

    public var body: some Scene {
        WindowGroup("LGTM", id: "main") {
            LgtmContextRoot()
                .environmentObject(emojis)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

/// This app is standalone - there is no `ClusterManager`/tab strip to hand it
/// a cluster the way the main app's does, so this is the whole of that: seed
/// the kubeconfig's current context, offer the rest from a toolbar menu, and
/// remember the choice.
private struct LgtmContextRoot: View {
    @StateObject private var picker = ContextPicker()

    var body: some View {
        Group {
            if let context = picker.selected {
                // Keyed on the context. A view that keeps its SwiftUI identity
                // across a cluster switch never rebuilds the @StateObject
                // inside, and goes on showing the previous cluster's report
                // under the new cluster's name - this shipped once already in
                // the main app (`ContentView`'s `.id(store.context)` call
                // site, since deleted along with that app's LGTM tab), so it
                // has to be re-established here rather than assumed inherited.
                LgtmRootView(context: context)
                    .id(context)
            } else if let error = picker.error {
                ContentUnavailableView {
                    Label("No cluster context", systemImage: "server.rack")
                } description: {
                    Text(error)
                }
            } else {
                ProgressView("Reading kubeconfig…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                contextMenu
            }
        }
        .task { await picker.load() }
    }

    private var contextMenu: some View {
        Menu {
            ForEach(picker.contexts, id: \.self) { ctx in
                Button {
                    picker.select(ctx)
                } label: {
                    if ctx == picker.selected {
                        Label(ctx, systemImage: "checkmark")
                    } else {
                        Text(ctx)
                    }
                }
            }
            if picker.contexts.isEmpty {
                Text("No contexts found").disabled(true)
            }
        } label: {
            Label(picker.selected ?? "Select Cluster", systemImage: "server.rack")
        }
    }
}

/// Reads the kubeconfig once, the same two calls `RootView` (KubeViewKit)
/// makes for its own bootstrap: `contexts()` for the list, `currentContext()`
/// only to seed a first run - never touched again after, same restriction
/// `ClusterManager` places on itself, for the same reason: this app's
/// selection is its own from that point on, and must not silently follow
/// whatever a terminal's `kubectl config use-context` last set.
@MainActor
private final class ContextPicker: ObservableObject {
    @Published private(set) var contexts: [String] = []
    @Published private(set) var selected: String?
    @Published private(set) var error: String?

    /// Namespaced under the app's own bundle id, not the informal
    /// `"kubeview.*"` prefix KubeView's `UserDefaults` keys use - the two
    /// apps share no state, and the key name should not imply otherwise.
    private static let defaultsKey = "com.omaksi.lgtmview.context"

    func load() async {
        do {
            let all = try await KubectlService().contexts().map(\.name).sorted()
            contexts = all
            guard !all.isEmpty else {
                error = "No contexts found in the kubeconfig."
                return
            }
            let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
            let current = try? await KubectlService().currentContext()
            // Saved choice first (this app's own last selection), then
            // whatever kubectl already points at (a reasonable first-run
            // guess), then just the first available context.
            if let saved, all.contains(saved) {
                selected = saved
            } else if let current, all.contains(current) {
                selected = current
            } else {
                selected = all.first
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ context: String) {
        selected = context
        UserDefaults.standard.set(context, forKey: Self.defaultsKey)
    }
}
