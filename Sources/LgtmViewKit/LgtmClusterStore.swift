import Foundation
import KubeModel
import KubeClient

/// The LGTM app's own live-cluster data source - just enough Kubernetes state
/// for the Cluster tab to join kubectl-lgtm's classification (`LgtmComponent`)
/// against real pods, exactly the way `LgtmClusterView.buildRows()` already
/// does today. NOT `ClusterStore`: that store polls ~18 resource kinds every
/// 5s for a general-purpose cluster browser with a dozen other tabs to feed;
/// this app has one tab that needs live data, so a poll loop would keep
/// re-fetching five kinds nothing else here ever reads. Fetches once per
/// explicit `load()` call - no timer, no background task.
///
/// The five kinds below are exactly what the audit of
/// `Views/LgtmClusterView.swift` found reachable from `ClusterStore` - see:
///   - `store.pods`            LgtmClusterView.swift:164, :208, :220, :232
///   - `store.deployments`     LgtmClusterView.swift:159, :206
///   - `store.statefulSets`    LgtmClusterView.swift:160, :218
///   - `store.daemonSets`      LgtmClusterView.swift:161, :230
///   - `store.podMetrics`      LgtmClusterView.swift:128 (joined by "ns/name")
///   - `store.metricsAvailable` LgtmClusterView.swift:286, :397
/// `store.isFirstLoad` (LgtmClusterView.swift:58) is mirrored below as a
/// computed property so that call site needs no change. Nothing else in the
/// five Lgtm* view files reads `ClusterStore` - the only other stores the
/// original code touched (`SearchState`/`NavState`/`TabStore`) were all
/// confined to `showPods()`, which this app replaced with `LgtmStore.tab` /
/// `scrollToComponentTitle` (see `LgtmView.swift`) rather than porting them.
@MainActor
final class LgtmClusterStore: ObservableObject {
    let context: String

    @Published var pods: [Pod] = []
    @Published var deployments: [Deployment] = []
    @Published var statefulSets: [StatefulSet] = []
    @Published var daemonSets: [DaemonSet] = []
    @Published var podMetrics: [PodMetrics] = []
    /// Mirrors `ClusterStore.metricsAvailable` - false only when metrics-server
    /// didn't answer, so usage bars fail soft instead of drawing a real zero.
    @Published var metricsAvailable = true

    @Published var loading = false
    @Published var lastError: String?
    @Published var lastLoaded: Date?

    /// Mirrors `ClusterStore.isFirstLoad` so `LgtmClusterView`'s existing
    /// `LoadingPlaceholder` gate (line 43) needs no change to read this store
    /// instead: true only until the first load resolves either way.
    var isFirstLoad: Bool { lastLoaded == nil && lastError == nil }

    private let kubectl: KubectlService

    init(context: String) {
        self.context = context
        self.kubectl = KubectlService(context: context)
    }

    /// Explicit and UI-triggered - wired to `LgtmStore.load()` so the tab's
    /// two halves (live pods, analysed components) go stale and refresh
    /// together instead of drifting apart. No preflight before this fan-out,
    /// unlike `ClusterStore`: by the time anyone reaches the Cluster tab,
    /// kubectl-lgtm's own classification pass has already proven the cluster
    /// answers, so a second reachability probe here would only add latency to
    /// the common case.
    ///
    /// Pods fail hard - this tab has nothing to show without them, same as
    /// `ClusterStore.pods` in `ClusterStore.refresh()` (`KubeViewKit`).
    /// Deployments/StatefulSets/DaemonSets/pod metrics fail soft exactly like
    /// `ClusterStore` does for those same four kinds in the same method, so a
    /// cluster missing one workload type or metrics-server doesn't blank the
    /// tab.
    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let ps = kubectl.pods()
            async let deps = kubectl.deployments()
            async let sts = kubectl.statefulSets()
            async let ds = kubectl.daemonSets()
            async let pm = kubectl.podMetrics()

            pods = try await ps
            deployments = (try? await deps) ?? []
            statefulSets = (try? await sts) ?? []
            daemonSets = (try? await ds) ?? []
            let metrics = await pm
            podMetrics = metrics ?? []
            metricsAvailable = metrics != nil

            lastError = nil
            lastLoaded = Date()
        } catch {
            lastError = (error as? KubectlError)?.errorDescription ?? error.localizedDescription
        }
    }
}
