import SwiftUI
import KubeModel
import KubeUI

/// The LGTM app's replacement for reaching into the main app's Pod screens.
/// That used to happen two ways, and both assumed a second screen inside the
/// SAME process: `showPods()` wrote `SearchState`/`NavState`/`TabStore`/
/// `ClusterStore` directly, and the pod cards in `LgtmClusterView.swift`
/// pushed `AppRoute.pod(PodRoute(...))` onto a `NavigationStack` that
/// `ContentView` resolved. Neither survives a process boundary, and this app
/// has no shared stores or nav stack to write into or resolve against. No URL
/// scheme, no XPC: everything this needs already lives in `KubeUI` and takes
/// nothing but a `PodRoute` plus a context.
///
/// A sheet, not a pod list: `LgtmClusterView` already renders every pod as a
/// card with ready/restarts/CPU/Mem/node on it (`LgtmPodUsageCardBody`), so a
/// list would repeat what's already on screen. Logs and `kubectl describe`
/// are the two things a card genuinely can't show, and this shows exactly
/// those two - `PodLogsView` and `PodDescribeView` (`KubeUI`) already do both
/// and take no environment objects, so this wraps them rather than
/// reimplementing a log viewer.
///
/// Takes the whole `Pod`, not just a route, so the container list for the
/// Logs tab's picker doesn't need a second live lookup into a store - the
/// caller already has the `Pod` in hand (it built the card this sheet opens
/// from). `Pod` is `Identifiable`, so a call site can present this with a
/// plain `.sheet(item:)` over `@State private var inspecting: Pod?`.
struct PodInspectSheet: View {
    let pod: Pod
    /// The cluster this pod belongs to, so `PodLogsView`/`PodDescribeView`
    /// build their `KubectlService` against the right context rather than
    /// whatever `kubectl config current-context` happens to be.
    let context: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .logs

    private enum Tab: String, CaseIterable, Identifiable {
        case logs, describe
        var id: String { rawValue }
        var title: String { self == .logs ? "Logs" : "Describe" }
        var icon: String { self == .logs ? "text.alignleft" : "doc.text" }
    }

    private var route: PodRoute { PodRoute(namespace: pod.namespace, name: pod.name) }

    /// Same construction as the main app's `PodDetailView.containerNames` -
    /// main containers before init containers, so the Logs tab's picker
    /// defaults to one still running rather than one that already exited.
    private var containerNames: [String] {
        let main = (pod.spec?.containers ?? []).map(\.name)
        let inits = (pod.spec?.initContainers ?? []).map(\.name)
        return main + inits
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Label(t.title, systemImage: t.icon).tag(t) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .logs:     PodLogsView(route: route, containers: containerNames, context: context)
            case .describe: PodDescribeView(route: route, context: context)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(pod.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(pod.namespace).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }
}
