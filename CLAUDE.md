# CLAUDE.md — KubeView

Instructions for Claude Code when working in this repo.

## What this is

Native macOS desktop app for viewing Kubernetes clusters. SwiftUI, SPM executable,
macOS 14+. Shells out to `kubectl` (no native k8s client) — intentional for MVP.

## Featureset (as of v0.3.0)

| Category | Resources |
|---|---|
| Cluster | Overview (k8s server version, stats, unhealthy, nodes, namespaces grid), Events (lazy-load, warnings-only toggle, involved object surfaced), Namespaces (with drill-down + star + dim-when-empty), Nodes |
| Workloads | Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, Pods (with Overview/Logs/Describe tabs), HPAs |
| Network | Services, Ingresses (clickable URLs open in browser), NetworkPolicies |
| Storage | PVCs, StorageClasses (with `is-default-class` annotation) |
| Config & RBAC | ConfigMaps (expandable values), Secrets (click-to-reveal), ServiceAccounts, IRSA (filtered SA view showing `eks.amazonaws.com/role-arn`) |
| Service Mesh | Linkerd (detects `linkerd-proxy` sidecar; shows control-plane pods; mesh coverage per namespace) |
| AWS | Profiles (parsed from `~/.aws`; type, region, live expiry countdown, which contexts use each, Log in / Log out / editable login command) |
| Graph | Resource graph per namespace (ownership + Service/Ingress/HPA edges, pan/zoom, collapse large fan-outs) |

**Cross-cutting:**
- **Multi-cluster**: `ClusterManager` supervises a `ClusterStore` per active context; each has its own refresh loop. No kubeconfig mutation — every kubectl call uses `--context`. Active contexts and selection persist via `UserDefaults`.
- **The app's selection is its own, and must stay that way.** `kubectl config current-context` is read in exactly one place (`ClusterManager.swift:36`) and only to seed a first run. `bootstrap()` must call `persistActive()` before returning: it activates with `persist: false`, so without that call an untouched install never writes `kubeview.activeContexts`, falls into the seed branch on *every* launch, and silently follows whatever the terminal last switched to. That was a real bug — it hides as soon as the user adds or removes a cluster by hand, which is what makes it easy to misdiagnose.
- **Namespace filter** (`ClusterStore.namespaceFilter` + `NamespacePicker`): pop-up in the top bar between the cluster pills and the search box, always visible. `nil` = All Namespaces, which is the default. Selecting one scopes every namespaced list view — pods, all workload kinds, services, ingresses, network policies, PVCs, configmaps, secrets, service accounts/IRSA, HPAs, cluster events and the cross-resource search results — via `Collection.inNamespace(_:_:)`. Cluster-scoped kinds (nodes, storage classes, the Namespaces list) and the cluster-wide summaries (Overview stats/grid, Linkerd mesh coverage) are untouched by design.
- **Resource graph** (`ResourceGraph` + `NamespaceGraphView`): namespace drill-down renders its resources as a directed graph, Argo-CD style. **No new kubectl calls** — `metadata.uid` and `metadata.ownerReferences` were always in the JSON kubectl returns, `ObjectMeta` just didn't decode them; Service→Pod is client-side selector matching, Ingress→Service and HPA→target come from fields already decoded. Layout is a **static tier table + one barycenter pass**, not a layering algorithm: columns are then made *dense*, so a namespace with no Ingress doesn't render an empty gutter. Pods past `fanOutCap` (15) under one owner collapse into a "+N more" node, matching how NamespaceCard shows 3 unhealthy workloads then a count. Pan/zoom is applied **once at the container** (`scaleEffect`/`offset` on the whole content) — per-node transforms would re-lay-out every node each gesture frame. Nodes are chips rather than `ResourceCard`: the card's hover state and emoji picker are far too heavy a few hundred times over. An **empty selector matches nothing** (`matches(selector:labels:)`), or every headless/edge Service would draw an edge to every pod in the namespace. `ResourceGraph` is pure — no SwiftUI, no I/O — so its `selfCheck` asserts are the whole test story, and it is the one place in this codebase where testing is straightforward and expected.
- **Global search** (`SearchState` + `GlobalSearchBar`, ⌘F): top-of-window box, context-aware. On Overview it triggers `GlobalSearchResultsView` (groups hits across every resource kind, hides empty groups). On any list view it filters that view via `Collection.searchFiltered(_:_:)`.
- **Health detection** (`Pod.healthState`): ImagePullBackOff / CrashLoopBackOff / ErrImagePull / CreateContainerConfigError / etc. surface as "failing" even when `phase=Pending`. Deployment/StatefulSet/DaemonSet/ReplicaSet/Job also report isHealthy via ready-vs-desired.
- **Unhealthy surfaces**: Overview has an "Unhealthy" section listing pods + workloads with reasons. NamespaceCard shows a triangle badge and inline list of up to 3 unhealthy workloads.
- **Universal Describe**: any card with `kind.kubectlResource != nil` gets a right-click → Describe… sheet that runs `kubectl describe <kind> <name> -n <ns>`.
- **Emoji store** (`EmojiStore`): right-click any card → Set Emoji; opens the macOS system character palette via `NSApp.orderFrontCharacterPalette` (no custom popover). Saved emoji renders inline in the card title via `ResourceTitle`. Persisted in `UserDefaults` under `kubeview.emojiMap`.
- **Star + sort** (`StarStore`): star button on each `NamespaceCard` pins namespaces to top. `NamespaceSort.sorted` orders starred → non-empty → empty (alphabetical within each bucket). Empty namespaces (`podCount == 0`) render dimmed via `ResourceCard(dimmed: true)` (opacity 0.5 + saturation 0.3). Persisted in `UserDefaults` under `kubeview.starredNamespaces`.
- **Dynamic sidebar**: `NavSection.isVisible(store:)` hides sections that have nothing to show in the current context (Linkerd, IRSA, NetworkPolicies, PVCs, StatefulSets, Jobs, CronJobs, DaemonSets, ReplicaSets, ConfigMaps, HPAs).
- **Cards-first**: every list view starts as cards; `ViewModeToggle` switches to a table.
- **First-load placeholder** (`LoadingPlaceholder`): when a list is empty AND `store.isFirstLoad`, show a centered spinner + "Loading <label>…" instead of an empty grid. Background polling stays silent (no top progress bars or spinners).
- **Refresh errors** (`ErrorBanner`): mounted once in `ClusterContentView`, so a failure is visible from every view, not just Overview. `ClusterStore.isFirstLoad` is `lastRefresh == nil && lastError == nil` — the error half matters, because `lastRefresh` is only set on the success path and a cluster that never connects would otherwise leave every list spinning forever.
- **Feedback** (`FeedbackSheet` + `GitHubIssueTransport`): Diagnostics → Report Feedback… opens an issue on `omaksi/kubeview`. Rules this feature is built on, none of which are incidental:
  - **Redaction is not optional here.** The Copy/Save paths keep a toggle because they stay local; the GitHub path hard-codes `redacted: true`. A public issue is not somewhere to offer a foot-gun.
  - **No token ships in the binary.** A distributed app's secrets are extractable, so the token is user-supplied and lives in the **Keychain**, never `UserDefaults` (a plist is readable within the account and lands in backups). Without a token, Send fails cleanly and Copy Instead still works.
  - **What is previewed is what is sent.** The sheet renders `report.body` — the exact string transmitted — so review and payload can't drift.
  - **Sending is always explicit.** No background telemetry, ever.
  - Bodies are capped at 60k (GitHub's limit is 65536) by trimming the *log*, never the user's description, with the truncation stated in place.
- **Diagnostics** (`LogStore` + `DiagnosticsView`): 2000-entry in-memory ring buffer, never written to disk. Every kubectl call logs its command line, duration, byte count and stderr; every refresh cycle logs start/outcome. Sidebar → Diagnostics gives level filter, text filter, follow-tail, and Copy/Save/Report-Feedback. `LogStore.record` is `nonisolated` and hops to the main actor, so the `KubectlService` actor can call it directly.
  Redaction in `report(redacted:)` masks context names **word-bounded** (a context called `default` would otherwise rewrite kubectl's "defaulted container" into "cluster-2ed container"), plus hosts, IPs, bearer tokens, and the pod/namespace arguments of `describe`/`logs`/`-n`. Resource names reach the log only through kubectl argv, so that is where they are masked; text the *cluster* returns can still name things, and the feedback sheet says so rather than implying the report is safe by construction.
- **AWS profiles** (`AwsStore` + `AwsView`): read-only view of `~/.aws`, plus a login button. The app **never writes `~/.aws`** — `aws`/`saml2aws` write their own credentials; only the per-profile login command override goes to `UserDefaults` (`kubeview.awsLogin.<profile>`). Three sources are joined: `config` (profiles + `[sso-session]`), `credentials` (`x_security_token_expires`), `sso/cache/*.json` (`expiresAt`, matched to a session by `sso_start_url`). Context→profile comes from the kubeconfig exec blocks' `AWS_PROFILE`, so this pane and the cluster pills can't disagree about which credentials a cluster uses.
- **Cluster names** (`ClusterNameStore`): user-assigned aliases for contexts, persisted in `UserDefaults` under `kubeview.clusterNames`, edited in Settings → Clusters (⌘,). Purely a display layer over the cluster bar, menu bar and Add Cluster menus — the kubeconfig is never rewritten and every kubectl call still uses the real context name. Contexts are frequently full EKS ARNs that are identical for their first 40 characters, which is unreadable in a pill.
- **Sidebar is split by scope**: resource sections (Cluster / Workloads / Network / Storage / Config & RBAC / Service Mesh) are cluster-scoped and filtered by `isVisible(store:)`; the trailing **App** group (AWS Profiles, Diagnostics) is app-scoped and shows the same content whichever cluster is selected. Anything new that doesn't change with the selected cluster belongs in App.
- **Settings is tabbed** (`SettingsView` → `TabView`): General (appearance), Clusters (names), Feedback (GitHub token). macOS titles the Settings window after the active tab, which is the cheapest way to confirm a tab is live.
- **Inline re-login**: a cluster pill whose fault is `.notLoggedIn` grows a "Log in" button, resolved to an AWS profile via `AwsStore.profile(forContext:)`. It's the only fault the user can fix from the pill, so it's the only one that gets an inline action — the rest still route through the error banner. No profile resolves for a context that assumes a role without naming one (`--role` off `[default]`), and the button is simply absent there.
- **Menu bar**: `MenuBarExtra` with `.menuBarExtraStyle(.window)`; aggregates health across all active clusters, per-cluster summary rows with deactivate buttons.
- **Appearance** (`AppearanceMode`, ⌘,): System / Light / Dark via a `Settings` scene, persisted with `@AppStorage` under `kubeview.appearance`. `.system` maps to a nil `ColorScheme`, which is how SwiftUI spells follow-the-OS. Apply `preferredColorScheme` to **every** scene — the `MenuBarExtra` panel is its own window and won't inherit the `WindowGroup`'s.
- **Refresh cadence**: 5s for everything except secrets + configmaps which are on a 30s "slow cycle" (they're the largest payloads; `slowCycleRatio = 6` in `ClusterStore`). Metrics-server failures are swallowed so the rest keeps updating. Toolbar refresh button is always enabled (no disable-while-loading flicker).
- **Shared nav state** (`NavState`): `selected: NavSection?` + `path: [AppRoute]` live in an `@MainActor ObservableObject` injected at app level. Sidebar selection clears the nav path on change. `AppRoute` enum wraps `NamespaceRoute` / `PodRoute` so the stack is introspectable.

## Layout

```
Sources/KubeView/
├── KubeViewApp.swift             # @main — WindowGroup + MenuBarExtra, RootView (cluster pills + namespace picker + search row), ClusterContentView (@ObservedObject store + ErrorBanner), GlobalSearchBar, menu bar icon
├── ClusterManager.swift          # Supervisor: available contexts, active set, selected store
├── ClusterStore.swift            # Per-context store; @Published resources + derived state (precomputed in refresh); serverVersion lazy-fetched on first refresh; namespaceFilter + pickerOptions + Collection.inNamespace
├── EmojiStore.swift              # ResourceKind/ResourceRef + emoji map; StarStore (namespace pins); ClusterNameStore (context aliases)
├── SearchState.swift             # @MainActor ObservableObject — global search query, `Collection.searchFiltered` extension
├── AwsStore.swift                # ~/.aws INI + SSO-cache parsing, expiry join, login via `sh -c`, FSEvents watcher on ~/.aws
├── Services/
│   ├── Subprocess.swift          # Shared CLI runner: binary discovery, PATH for exec auth plugins, null stdin, watchdog kill. Every external tool goes through it
│   ├── KubectlService.swift      # actor: `kubectl --context <ctx> ... -o json`; all fetches + describe + logs + events + serverVersion
│   └── LgtmService.swift         # `kubectl-lgtm --json` wire format (LgtmReport/Component/Finding) + decode + selfCheck
├── Models/
│   ├── K8sModels.swift           # Codable structs for every resource; ResourceParser (CPU millicores, memory bytes); Pod.healthState
│   └── ResourceGraph.swift       # Pure graph builder: ownerReferences + selector/Ingress/HPA edges, tiered columns + barycenter ordering, fan-out cap; selfCheck
└── Views/
    ├── ContentView.swift         # NavigationSplitView + grouped sidebar (cluster-scoped groups + trailing App group); NavState; AppRoute; RefreshButton; ClusterBar/ClusterPill; NamespacePicker
    ├── CardChrome.swift          # ResourceCard (kind stripe + chevron + dim + system emoji picker via TextField+orderFrontCharacterPalette), ResourceTitle, DescribeSheet
    ├── ViewMode.swift            # ViewModeToggle, ViewHeader, LoadingPlaceholder, ErrorBanner
    ├── OverviewView.swift        # Stat cards (incl. k8s server version), Unhealthy section, Nodes usage bars, NamespaceCard grid + NamespaceSort
    ├── NamespacesView.swift      # List view (sorted via NamespaceSort); NamespaceCard defined in OverviewView
    ├── NamespaceDetailView.swift # Drill-down: pods/services/ingresses scoped to ns; PodCardBody/ServiceCardBody/IngressCardBody/IngressPathLink
    ├── NamespaceGraphView.swift  # Canvas edges + chip nodes, container-level pan/zoom, expand/collapse, tap-to-navigate
    ├── GlobalSearchResultsView.swift # Cross-resource grouped search hits shown on Overview when SearchState.isActive
    ├── PodsView.swift            # List view + PodCard.phaseColor helper
    ├── PodDetailView.swift       # Overview/Logs/Describe tabs; ContainerCard; EventRow (with involved-object link); PodEventsLoader
    ├── PodLogsDescribe.swift     # PodLogsView, PodDescribeView (+ their loaders)
    ├── NodesView.swift           # NodeCardBody with UsageBars when metrics-server available
    ├── ServicesView.swift, IngressesView.swift, NetworkPoliciesView.swift
    ├── SecretsView.swift         # Click-to-reveal per-key (base64 decoded on demand)
    ├── StorageViews.swift        # PVCs + StorageClasses
    ├── ServiceAccountsView.swift # Reused with irsaOnly: Bool for the IRSA nav entry
    ├── WorkloadsViews.swift      # Deployments, StatefulSets, ReplicaSets, Jobs, CronJobs + shared WorkloadCardBody
    ├── MoreViews.swift           # DaemonSets, ConfigMaps, HPAs, cluster Events (lazy-load)
    ├── LinkerdView.swift         # Control plane + meshed namespaces + meshed pods
    ├── LgtmView.swift            # Tab shell (Cluster/Metrics/Findings), LgtmStore two-pass loader, LgtmWindow, FindingCard, SeverityTag, Sparkline
    ├── LgtmClusterView.swift     # Cluster tab: live per-pod topology from ClusterStore, no metrics dependency
    ├── LgtmMetricsView.swift     # Metrics tab: per-pod history, headroom, coverage outliers
    ├── LgtmTopology.swift        # LGTM data-path model: per-product edges, lanes, cross-product Alloy/Grafana
    ├── LgtmGraphView.swift       # Data-flow graph renderer: Kahn tiering, cycle-safe, saturation + peak-replica mark
    ├── AwsView.swift             # Profile cards: kind, region, expiry countdown, contexts, Log in / Log out / Edit command
    └── MenuBarContent.swift      # Tray dropdown
Resources/
└── AppIcon.icns                  # slate→teal hexagon + binoculars (generated by scripts/make_icon.swift)
scripts/
├── bundle.sh                     # wraps SPM binary into KubeView.app (local dev); also builds kubectl-lgtm into Contents/MacOS if ../kubectl-lgtm exists
└── make_icon.swift               # Core Graphics → .iconset → iconutil → AppIcon.icns
.github/workflows/release.yml     # universal binary + icon gen + Developer ID sign + notarize + Release + tap bump
```

## Design rules

- **Cards are the default view**. Every list view shows cards first; tables are an
  opt-in toggle via `ViewModeToggle`. Do not introduce table-only views.
- **Navigable cards show a chevron.** Wrap in `NavigationLink(value:)` and pass
  `navigable: true` to `ResourceCard`. The chevron + hover tint come from the
  shared chrome — don't add manual chevrons in card bodies.
- **Kubectl only, no native client.** All cluster I/O goes through `KubectlService`.
  If it can't be expressed as `kubectl ... -o json` / `kubectl get --raw ...` /
  `kubectl describe` / `kubectl logs`, push back before adding it.
- **Context is per-service, not global.** Pass `--context` via `KubectlService(context:)`;
  never call `kubectl config use-context` (that mutates the user's kubeconfig
  and affects other terminals). `ClusterManager` is the sole owner of active contexts.
- **Optional resources fail soft.** `metrics-server`, `networkpolicies`, `ingresses`,
  workload types may not exist on every cluster. In `ClusterStore.refresh()`, wrap
  in `(try? await ...) ?? []` so one missing API doesn't tank the whole refresh.
  `metricsAvailable` gates "used" numbers in the UI.
- **Large payloads on slow cadence.** Secrets + ConfigMaps can be MBs on busy
  clusters. They're on `slowCycleRatio` (currently 6 → every 30s). Add any new
  expensive `--all-namespaces` fetch to the slow cycle.
- **Derived state computed in `refresh()`, not per render.** `namespaceSummaries`,
  `unhealthyWorkloads`, `unhealthyPods`, `nodeUsage` are `@Published private(set)`
  and recomputed once per refresh. Don't inline these into view bodies.
- **Refresh is polled, not watched.** Each `ClusterStore.start()` runs a 5s loop.
  Don't add watch streams — if you need push updates, we'd move to the native
  k8s Swift client (discuss first — it's a larger change).
- **Never let a kubectl call be unbounded.** `KubectlService.run` bounds every
  invocation with null stdin + `--request-timeout` + a kill watchdog. An
  unbounded call means `refresh()` never returns, so neither `lastRefresh` nor
  `lastError` is set and the UI spins forever with nothing to show.
  Measured, and the reason all three bounds exist:
  | Call | `--request-timeout` honoured? |
  |---|---|
  | `get --raw /version` | Yes — 5.2s for a 5s setting |
  | `get pods --all-namespaces` | **No** — 10s setting still running past 15s (API discovery runs first) |
  | any context with no credentials | Irrelevant — kubectl prompts on stdin; null stdin turns it into a 0.04s EOF failure |
- **Connection state is typed, not string-matched at call sites.**
  `ClusterStore.fault: ConnectionFault?` is set once by `classify`, and the
  pill, menu bar row, menu bar icon and error banner all read it. Adding a new
  surface means reading `fault`, never re-parsing `lastError`.
  `classify` matches kubectl's *real* wording — it never says "timed out":
  | Failure | kubectl says |
  |---|---|
  | black-holed | `Unable to connect to the server: context deadline exceeded` |
  | refused | `The connection to the server host:port was refused` |
  | bad DNS | `dial tcp: lookup host: no such host` |
  | no credentials | `Please enter Username: error: EOF` |
  Order matters: TLS and auth surface *through* a connection error
  (`Unable to connect to the server: x509: …`), so specific causes are tested
  before the generic connectivity patterns.
- **A disconnected cluster must never render as healthy.** The green dot used to
  mean "no unhealthy pods", which a cluster with *no* pods trivially satisfies —
  so an unreachable cluster showed green in the pill and a plain helm in the
  menu bar. Any new health surface checks `fault` first, then `lastRefresh ==
  nil` (grey, never contacted), then pod/workload health.
- **Preflight before fanning out.** `ClusterStore.preflight()` runs one
  `get --raw /version` (5s) before the ~18-call batch, and only while the
  cluster isn't known healthy. Unreachable now costs ~5s instead of ~22s,
  bad credentials ~0.04s, and we don't spawn 18 doomed processes. Errors go
  through `friendlyMessage` so the banner names the cause rather than echoing
  kubectl's stderr.
- **`run` is `nonisolated`.** It was actor-isolated and blocking, which silently
  serialised the whole `async let` batch in `refresh()` and pinned a cooperative
  thread per call. Keep the blocking reads on `DispatchQueue.global`.
- **`~/.aws` is read-only to this app.** Every AWS toolchain on the machine
  depends on those files; a buggy INI writer breaks all of them at once. Login
  is delegated to `aws`/`saml2aws`, which write their own credentials. If
  profile editing is ever added, it needs atomic write + timestamped backup +
  comment preservation — discuss first.
- **Only the SSO login command is derivable.** `aws sso login --sso-session <s>`
  falls out of `~/.aws/config`. Everything else (saml2aws, aws-vault, scripts)
  leaves no trace of its invocation on disk, so the command is a per-profile
  `UserDefaults` override seeded with a guess. `saml2aws` prompts for role
  selection on stdin when `--role` is omitted — with null stdin that fails fast
  instead of hanging, and the fix is to edit the command once.
- **Login runs through `sh -c` with the same three bounds as kubectl** (null
  stdin, timeout, kill). It is `nonisolated` and blocking, so call it from
  `Task.detached`, never the main actor.
- **The `~/.aws` watcher is debounced.** One `saml2aws` run rewrites the
  credentials file several times; without the 1s coalesce each write kicks a
  full cluster refresh. Note it watches `~/.aws` only — SSO writes land in
  `~/.aws/sso/cache` and don't touch that directory, so they're picked up by
  the login completion handler instead.
- **The namespace scope is the app's own, per context, and never written to
  the kubeconfig.** `ClusterStore.namespaceFilter` is `nil` for all namespaces
  and persists under `kubeview.namespaceFilter.<context>`. It is deliberately
  not `kubectl config set-context --current --namespace`: that rewrites the
  user's kubeconfig and follows them into every terminal, exactly the trap the
  `use-context` rule exists to avoid. Each cluster keeps its own scope, so
  switching pills switches scope with it.
- **Filtering happens per list view, not in `refresh()`.** Namespaced views
  chain `Collection.inNamespace(store.namespaceFilter, \.namespace)` before
  `searchFiltered`, the same way search is applied. Nothing about what is
  *fetched* changes — kubectl still reads `--all-namespaces`, so switching
  namespaces is instant and costs no calls. A new namespaced list view has to
  add that one chained call; cluster-scoped ones (nodes, storage classes, the
  Namespaces list) must not, they have no namespace to match on.
  Cluster-wide answers stay cluster-wide on purpose: Overview's stats and
  namespace grid, and Linkerd's mesh coverage, are statements about the whole
  cluster and would lie if scoped. Sidebar visibility (`isVisible(store:)`) is
  likewise unfiltered, so sections don't appear and vanish as the scope changes.
- **The namespace picker is a sibling of `ClusterBar`, not a child.** That bar
  is keyed on `manager.activeOrder` (below), so adding or removing a cluster
  rebuilds its entire subtree — a picker inside it would be torn down
  mid-interaction. It lives directly in `RootView`'s header `HStack`, between
  the cluster bar and the search box, and is on screen whenever a cluster is
  selected.
- **`ClusterBar` is keyed on `manager.activeOrder`.** `RootView` renders it in
  *both* branches of its `selectedStore` check and `bootstrap()` flips that
  branch asynchronously, after first layout. SwiftUI reuses the same
  `NSScrollView` across the switch and keeps the content size measured while
  the bar was empty, so pills exist with correct frames but go unpainted until
  a window resize. Accessibility reports them either way — a correct AX frame
  is not evidence that something is on screen. Don't remove the `.id`.
- **A login isn't done when the login process exits.** `aws sso login`
  returning means credentials exist, not that the cluster is reachable — that
  costs a preflight plus the ~18-call batch. `onCredentialsChanged` is `async`
  and `retryFaulted()` awaits its task group precisely so the pill keeps its
  spinner through the reconnect. Making either fire-and-forget again puts the
  UI back to going quiet at the slowest moment.
- **The toolbar refresh reloads lists, not just resources.** It calls
  `manager.reloadContexts()` + `aws.reload()` + `aws.loadContexts()` before
  `store.refresh()`. Before that it only refetched the selected cluster, so a
  kubeconfig context or AWS profile added after launch needed a restart —
  `bootstrap()` is the only other reader and it runs once from `init()`.
  It is also the one place a spinner belongs: the no-spinner rule exists for
  the silent 5s poll, and a user-initiated press with no visible response
  reads as a dead button.
- **The app inherits launchd's environment, not your shell's.** `KUBECONFIG`
  set in `~/.zshrc` is invisible to a GUI launch, so contexts merged that way
  won't appear even though `kubectl` finds them in a terminal. Only
  `~/.kube/config` is seen by default.
- **No `AnyView` in view chains.** `ViewHeader` is generic over its trailing view;
  keep it that way so SwiftUI can diff properly.
- **No emojis in source or UI** unless explicitly requested. The per-resource
  emojis the user sets at runtime are a separate thing (stored in `EmojiStore`).
- **Minimal comments.** Only non-obvious invariants / workarounds. No docstrings.
- **Window chrome is the system's.** Don't try to put breadcrumbs / custom
  controls inside the macOS title bar — `.toolbar` placements get pill-styled
  and toolbar scoping per stack level fights you. Keep custom UI in the
  content area (`RootView`'s VStack), not in `ToolbarItem`s.
- **Loading state is per-list, not global.** Use `LoadingPlaceholder` when the
  collection a view renders is empty and `store.isFirstLoad`. Don't add top
  progress bars or per-poll spinners — they show every 5s and feel broken.
  Background refresh is intentionally silent.
- **A spinner past ~2s must say what it's waiting for.** `LoadingPlaceholder`
  pulls `store.activity` / `activitySince` from the environment (no call site
  passes them), and after 2s adds the current phase plus a live elapsed count,
  after 8s a pointer to Diagnostics. Set phases via `setActivity` in
  `ClusterStore`, not by threading state through views.
- **Never gate a spinner on `lastRefresh` alone.** `refresh()` sets
  `lastRefresh` only on the success path, so an unreachable cluster leaves it
  nil forever. Gate on `store.isFirstLoad`, which also clears once `lastError`
  is set. Same trap for any future "have we loaded yet" check.
- **Errors surface globally, loading surfaces locally.** `ErrorBanner` is
  mounted once in `ClusterContentView`; don't add per-view error text, it
  double-reports. Note `ClusterContentView` takes the store as an
  `@ObservedObject` on purpose — `RootView` watches only `ClusterManager`, and
  `selectedStore` is computed, so reading `store.lastError` from `RootView`
  silently never updates.

## The LGTM view (helper-binary pattern)

The scaling analysis is **not** implemented in Swift. It lives in
`kubectl-lgtm` (a sibling Go repo at `~/GitHub/kubectl-lgtm`), which port-forwards
into the cluster's own Mimir/Prometheus, runs six PromQL queries per component
over a selectable lookback window, and applies a rule catalogue. KubeView shells out to
`kubectl-lgtm --json` exactly the way it shells out to `kubectl`, and renders the
result.

That split is the point, and it generalises: **this app's data layer is "run a
CLI, parse its output", so any analysis that already exists as a CLI should stay
one.** Reimplementing the rules here would have meant a second PromQL client and
a second copy of every threshold, drifting apart from the moment they were
written.

Rules that fall out of it:

- **The wire format is declared, not derived.** `kubectl-lgtm`'s
  `cmd/kubectl-lgtm/json.go` defines explicit structs rather than tagging the
  core Go types, so renaming an internal field can't silently break this app.
  `LgtmService.swift` mirrors them. Changes are additive-only.
- **`LgtmService.selfCheck()` guards the contract**, run from `LgtmStore.init`
  under `#if DEBUG`. It caught both real breakages: Go stamps `generatedAt` with
  nanoseconds, which `JSONDecoder.dateDecodingStrategy = .iso8601` rejects
  outright, and `warning` is absent (not null) on a single-cluster store.
- **The analysis is on-demand, never on the 5s cadence.** `LgtmStore` is cached
  per context so navigating away and back does not re-run it; only the refresh
  button and a window change do.
- **The binary is bundled** into `Contents/MacOS/kubectl-lgtm` by `bundle.sh`, so
  a released `.app` needs nothing installed. `LgtmService.binary` prefers the
  bundled copy, then Homebrew, then `~/go/bin` (for `swift run`). Host arch only,
  matching the SPM binary — make both universal together or neither.
- **Findings never tell you to run a command.** `kubectl-lgtm` invariant 3b: no flags, no shell. A health finding carries no snippet at all, and `FindingCard` offers **Show pods** instead — it sets the namespace filter, puts the workload name in the global search, and jumps to Pods, where Logs and Describe already live. That is the desktop equivalent of the three `kubectl` commands the tool used to print.
- **Sidebar visibility is a cheap name check** against workloads already in
  memory (`isLgtm` in ContentView.swift). Running the analyser to decide whether
  to draw a sidebar row would cost a port-forward.

### Three tabs, in debugging order

`LgtmView` is a shell around three tabs - what is true now, what has been true, what to do about it:

| Tab | File | Data | Survives Mimir being down |
|---|---|---|---|
| Cluster | `LgtmClusterView.swift` | `ClusterStore` live state + classification only | **yes** |
| Metrics | `LgtmMetricsView.swift` | per-pod usage history from Mimir | no |
| Findings | `LgtmView.swift` | rule output | no |

`LgtmTopology.swift` and `LgtmGraphView.swift` supply the data-flow graph both of the first two tabs draw.

**Two passes, because they fail independently and one of them is fast.** `LgtmStore.load()` runs `--no-metrics` first (~1.5s, Kubernetes API only, no port-forward) and paints the Cluster tab, then the full pass (~7s at 24h) fills Metrics and Findings. When the metrics pass fails the Cluster tab is already usable and the other two say so, rather than the window looking broken. That matters because a broken metrics store is exactly what someone opens this view to investigate - the original single-pass design showed nothing at all in that case.

**`LgtmView` must stay keyed on the context** - `.id(store.context)` at the call site in `ContentView`. `ContentView` keeps its SwiftUI identity when the selected cluster changes, so without the key the `@StateObject` is never rebuilt and the view goes on showing the previous cluster's report under the new cluster's name. That shipped once and cost an investigation.

**The lookback defaults to 24h** (`LgtmWindow`), persisted per context, as is the selected tab. Cost is not linear: 1d ~6s, 7d and 14d ~19s, **30d ~2m** - subquery resolution is a cost multiplier at a fixed step. And retention caps it anyway: the reference store holds about 8 days, so 14d and 30d return the same data and 30d merely takes two minutes to do it. `LgtmMetricsView` states the store's median coverage against the requested window rather than letting the picker imply a promise it cannot keep.

### The division of labour across the three tabs

This is the rule that governs every design decision in this view, and several bugs were only findable because it exists:

| Tab | Answers | May contain |
|---|---|---|
| Cluster | what **is** | every pod, real topology, observed state |
| Metrics | what was **measured** | every pod's actual numbers over the window |
| Findings | what it **means** | percentiles, thresholds, severity, recommendations |

**All interpretation belongs to Findings.** Tabs 1 and 2 report; they do not grade. Concretely, on those two tabs:

- **No chosen thresholds.** No "warn at 90%", no red/orange/green banding on bars, and no red-to-green ramp as a substitute - a ramp still says "red is bad", it only hides where the cutoff sits. `UsageBar` (OverviewView.swift) grades at 65%/85%, which is why the Cluster tab uses its own neutral `LgtmFactBar` instead.
- **Observed events may still stand out**, because they are measurements: over 100% of a configured limit, OOMKilled, throttled, restarted. "Approaching a limit" is a prediction and belongs to Findings.
- **`LgtmNodeLevel` on graph nodes** must be populated from observed events only, never from a saturation cutoff.
- **Encode magnitude, never encode a verdict.** Bar length is a measurement - draw it faithfully. A reference marker at 100% is pure fact and should stay: here is what someone configured, here is where reality sits against it.
- The failure mode to avoid is thirty identical grey bars. If a tab reads flat, fix it with ordering and grouping, not colour.

### Raw measurements travel to the renderer; only geometry clamps

**Producers pass raw ratios. Views clamp for drawing and never for text.** A value may legitimately exceed 1.0 - `mimir/store-gateway` runs at 198% of its CPU request, because that chart sets no CPU limit at all.

This is the single most productive bug class in this view; it appeared four times, and every instance produced a plausible-looking number rather than a visible failure:

- `saturationText` formatted the clamped `fillFraction`, so a node measured at 198% displayed **"100%"**.
- `typicalAndPeakSaturation` clamped its median before handing it over, so "typical" and "peak" both collapsed to 1.0 and the imbalance mark vanished on the one component that needed it.
- A doc comment reading "0...1 fill" is what *caused* the producer to clamp. The doc was the bug.
- On the Go side, a clamp-equivalent: collapsing per-pod restarts with `max` instead of `sum` silently moved a rule threshold.

`HeadroomBar` in `LgtmMetricsView` had it right from the start and is the reference: clamp the drawn width, keep the label honest about the overage. When adding any bar, gauge or chip here, clamp at the `frame(width:)` call and nowhere earlier.

### Per-pod is the unit, not the workload

The analyser reports per-pod measurements (`usage.replicas`, plus `usage.memorySpread`) alongside the component aggregates. Tabs 1 and 2 read per-pod; only Findings reads the aggregate, because sizing a limit genuinely needs the busiest replica.

Real spreads from the reference cluster over 24h, busiest replica over quietest: `mimir/querier` 1.99x, `mimir/query-scheduler` 1.66x, `alloy` 1.55x, against `mimir/ingester` at 1.02x. That variation is invisible in a single collapsed number, and "one replica carrying the load while its siblings idle" is exactly what people open this view to find.

Two traps:

- **Pods in the window outnumber replicas.** Almost the whole stack rolls within 24h - `mimir/distributor` showed 9 pods for 3 replicas across three ReplicaSet generations, and the Alloy DaemonSet showed 31 for 11 through node autoscaling. The Metrics tab shows measured history (so churn is included and must not be labelled as imbalance); the Cluster tab reads live pods (so it shows the current set). **The two tabs will legitimately disagree, and neither should claim to be the other.**
- **The Cluster tab must never read `usage.replicas`.** It is tempting now that per-pod history exists, and it would quietly reintroduce the dependency on the metrics store that the whole tab was designed to survive without.

### Gotcha: one Mimir, many clusters

The Innovatrics `lgtm-distributed` store holds metrics for five EKS clusters, so
every aggregation spans all of them and a max from a busier cluster reads as this
one's. `kubectl-lgtm` detects this and returns it in `report.warning`, which the
view renders as an orange banner. It is a caveat, not a fix — scoping needs
`--match 'cluster="..."'`, and picking the cluster automatically from the kube
context would be a guess whose failure is invisible.

## Build & run

```sh
swift build                          # debug
./scripts/bundle.sh debug            # wraps into build/KubeView.app
open build/KubeView.app              # launches with MenuBarExtra icon top-right
```

After editing, always rebuild the bundle — launching the SPM binary directly
works but MenuBarExtra only behaves correctly inside a `.app`.

The app talks to whatever cluster `kubectl config current-context` points at.
Switch contexts from the toolbar picker or tray menu, not by restarting.

## Release process

Versioning: semver, tags are `vX.Y.Z`.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The `release.yml` workflow on `macos-14`:

1. Builds universal binary (`arm64` + `x86_64`, merged via `lipo`).
2. Wraps into `KubeView.app` with `Info.plist` (version from tag).
3. **Signs** — Developer ID when `DEV_ID_CERT_P12` is set, ad-hoc otherwise
   (with a `::warning::`). See "Signing and notarization" below.
4. Zips as `KubeView-vX.Y.Z.zip` via `ditto -c -k --sequesterRsrc --keepParent`.
5. **Notarizes + staples** when signed with a Developer ID, then rebuilds the
   zip so it carries the ticket.
6. Checksums the final zip and creates a GitHub Release; the install snippet in
   the notes includes `--no-quarantine` only on unnotarized builds.
7. Clones `omaksi/homebrew-tap`, rewrites `Casks/kubeview.rb` with new
   version + SHA, commits and pushes. Requires `TAP_TOKEN` secret (PAT with
   `repo` scope on the tap repo).

### Workflow gotchas

- **`secrets` context is NOT usable in step-level `if:` conditions.** Map to a
  job-level env var first: `env: { HAS_TAP_TOKEN: ${{ secrets.TAP_TOKEN != '' && 'true' || 'false' }} }`,
  then check `if: env.HAS_TAP_TOKEN == 'true'`. Writing `if: ${{ secrets.X != '' }}`
  makes the whole workflow file invalid — it fails *before* any job starts, with
  no logs, and GitHub just says "workflow file issue."
- **Don't delete and recreate a tag** to retry a failed release. Tag forward to
  the next patch (`v0.1.1`) instead — preserves history and avoids surprising
  anyone who already saw the failed release.

### Signing and notarization

The workflow does both when these five secrets exist; with `DEV_ID_CERT_P12`
absent it silently degrades to ad-hoc signing, so the release still ships.

| Secret | What |
|---|---|
| `DEV_ID_CERT_P12` | Developer ID Application cert + key, exported as `.p12`, base64'd |
| `DEV_ID_CERT_PASSWORD` | Password set during the `.p12` export |
| `NOTARY_APPLE_ID` | Apple Account email on the developer team |
| `NOTARY_TEAM_ID` | 10-char team ID (top-right of the developer portal) |
| `NOTARY_PASSWORD` | App-specific password from account.apple.com — *not* the account password |

Export the cert once it's in the login keychain:

```sh
security find-identity -v -p codesigning          # confirm it's there
# Keychain Access → right-click the cert → Export → .p12
base64 -i DeveloperID.p12 | pbcopy                # paste into the GH secret
```

Notes on the pipeline:

- **Signing order matters.** Sign → zip → notarize → staple → **re-zip** →
  checksum. Stapling mutates the `.app`, so a checksum taken before it is wrong
  and the cask would fail verification.
- **`--options runtime` and `--timestamp` are mandatory.** Notarization rejects
  a signature missing either. Ad-hoc signing can't use hardened runtime.
- **The identity string is read back** from the imported keychain rather than
  hardcoded — it embeds the team ID and has to match the cert exactly.
- **`--deep` is only for the ad-hoc path.** Apple deprecated it for real
  signing; this bundle has no nested code, so plain `codesign` is correct.
- Notarization takes ~2-15 min. `--wait --timeout 30m` blocks the job; on
  rejection, `xcrun notarytool log <submission-id>` explains why.
- First notarized release was **v0.2.1** (2026-08-03), verified end to end:
  `spctl -a -vvv` reports `accepted / source=Notarized Developer ID`. Re-run that
  check on the published zip after any change to the signing steps — a green
  workflow only proves the commands exited 0.

### Homebrew tap (separate repo)

`omaksi/homebrew-tap` (the tap repo, renamed from `homebrew-kubeview`).
Users install with:

```sh
brew tap omaksi/tap
brew trust omaksi/tap
brew install --cask kubeview
```

**Homebrew 6+ gates third-party taps.** `Trust.require_trusted_cask!` fires on
*loading* the cask, so `install`, `upgrade`, `info` and `outdated` all fail with
"Refusing to load cask from untrusted tap" until the user runs `brew trust`.
Two consequences worth remembering when someone reports a stale install:

- A failed `install`/`upgrade` leaves the old app in place, so the symptom looks
  like a broken new release ("Apple could not verify it is free of malware")
  when it's really the previous build still sitting in `/Applications`.
- `brew upgrade` only touches brew-managed installs. An app dragged out of a zip
  is invisible to it — `brew list --cask` tells you which case you're in.

`HOMEBREW_NO_REQUIRE_TAP_TRUST=1` disables the check but is marked `odeprecated`
for removal — never put it in install docs.

The Cask formula is regenerated by the release workflow. Don't hand-edit
`Casks/kubeview.rb` unless changing schema (e.g., adding a new dependency).

## Common tasks

- **Add a new resource kind**:
  1. Codable model in `K8sModels.swift` (conform to `Identifiable`, `Hashable`)
  2. Fetch method in `KubectlService.swift` (`kubectl get <kind> --all-namespaces -o json`)
  3. `@Published var` on `ClusterStore` + `async let` in `refresh()` (use `(try? await …) ?? []` if the API may be missing)
  4. New case in `ResourceKind` (`EmojiStore.swift`) — accent color, SF Symbol, title, `kubectlResource` for describe
  5. New `NavSection` case + title + icon + `ContentView.currentRoot` switch + `isVisible(store:)` rule
  6. Add to the right `NavGroup` in `navGroups`
  7. Write the card body + list view; wrap cards in `ResourceCard(ref:navigable:)`; use `ResourceTitle` for the name (so emojis render inline); wrap list body in the empty + `store.isFirstLoad` → `LoadingPlaceholder` check
  8. If the kind is namespaced, chain `.inNamespace(store.namespaceFilter, \.namespace)` in the list view before `searchFiltered` — cluster-scoped kinds skip it
  9. If list views need to participate in global search, wire via `Collection.searchFiltered(search) { [..fields..] }`; for cross-resource hits on Overview, add a section to `GlobalSearchResultsView`
- **Expensive fetches** (all-namespaces secrets-sized): put inside the `if isSlowCycle { … }` block in `refresh()` instead of the concurrent batch.
- **Change refresh interval**: `ClusterStore.start()` — `5_000_000_000` ns for the fast cycle; `slowCycleRatio` for the slow-cycle divisor.
- **Menu bar indicator**: `KubeViewApp.menuIcon` — uses `manager.activeStores` aggregate health. Update when adding new "unhealthy" signals.
- **Tweak the icon**: edit gradient/hex size in `scripts/make_icon.swift`, run it from the repo root to regenerate `Resources/AppIcon.icns`. CI regenerates on every release.

## Don't

- Don't add a README bloat pass — keep it minimal, user-facing only.
- Don't write unit tests for the shell wrapper (mocking `Process` is not worth it
  for an MVP; tests against a kind cluster would be more valuable and belong in
  CI separately).
- Don't import heavy deps (Alamofire, Sparkle, etc.) without discussing first.
- Don't commit `build/`, `.build/`, `*.zip`, `*.dmg` (already in `.gitignore`).
