# CLAUDE.md — KubeView

Instructions for Claude Code when working in this repo.

## What this is

Native macOS desktop app for viewing Kubernetes clusters. SwiftUI, SPM executable,
macOS 14+. Shells out to `kubectl` (no native k8s client) — intentional for MVP.

## Featureset (as of v0.2.0)

| Category | Resources |
|---|---|
| Cluster | Overview (k8s server version, stats, unhealthy, nodes, namespaces grid), Events (lazy-load, warnings-only toggle, involved object surfaced), Namespaces (with drill-down + star + dim-when-empty), Nodes |
| Workloads | Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, Pods (with Overview/Logs/Describe tabs), HPAs |
| Network | Services, Ingresses (clickable URLs open in browser), NetworkPolicies |
| Storage | PVCs, StorageClasses (with `is-default-class` annotation) |
| Config & RBAC | ConfigMaps (expandable values), Secrets (click-to-reveal), ServiceAccounts, IRSA (filtered SA view showing `eks.amazonaws.com/role-arn`) |
| Service Mesh | Linkerd (detects `linkerd-proxy` sidecar; shows control-plane pods; mesh coverage per namespace) |

**Cross-cutting:**
- **Multi-cluster**: `ClusterManager` supervises a `ClusterStore` per active context; each has its own refresh loop. No kubeconfig mutation — every kubectl call uses `--context`. Active contexts and selection persist via `UserDefaults`.
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
- **Menu bar**: `MenuBarExtra` with `.menuBarExtraStyle(.window)`; aggregates health across all active clusters, per-cluster summary rows with deactivate buttons.
- **Refresh cadence**: 5s for everything except secrets + configmaps which are on a 30s "slow cycle" (they're the largest payloads; `slowCycleRatio = 6` in `ClusterStore`). Metrics-server failures are swallowed so the rest keeps updating. Toolbar refresh button is always enabled (no disable-while-loading flicker).
- **Shared nav state** (`NavState`): `selected: NavSection?` + `path: [AppRoute]` live in an `@MainActor ObservableObject` injected at app level. Sidebar selection clears the nav path on change. `AppRoute` enum wraps `NamespaceRoute` / `PodRoute` so the stack is introspectable.

## Layout

```
Sources/KubeView/
├── KubeViewApp.swift             # @main — WindowGroup + MenuBarExtra, RootView (cluster pills + search row), ClusterContentView (@ObservedObject store + ErrorBanner), GlobalSearchBar, menu bar icon
├── ClusterManager.swift          # Supervisor: available contexts, active set, selected store
├── ClusterStore.swift            # Per-context store; @Published resources + derived state (precomputed in refresh); serverVersion lazy-fetched on first refresh
├── EmojiStore.swift              # ResourceKind/ResourceRef + UserDefaults-backed emoji map; StarStore for namespace pins
├── SearchState.swift             # @MainActor ObservableObject — global search query, `Collection.searchFiltered` extension
├── Services/
│   └── KubectlService.swift      # actor: `kubectl --context <ctx> ... -o json` subprocess wrapper; all fetches + describe + logs + events + serverVersion
├── Models/
│   └── K8sModels.swift           # Codable structs for every resource; ResourceParser (CPU millicores, memory bytes); Pod.healthState
└── Views/
    ├── ContentView.swift         # NavigationSplitView + grouped sidebar (nav groups auto-filtered by isVisible); NavState; AppRoute enum
    ├── CardChrome.swift          # ResourceCard (kind stripe + chevron + dim + system emoji picker via TextField+orderFrontCharacterPalette), ResourceTitle, DescribeSheet
    ├── ViewMode.swift            # ViewModeToggle, ViewHeader, LoadingPlaceholder, ErrorBanner
    ├── OverviewView.swift        # Stat cards (incl. k8s server version), Unhealthy section, Nodes usage bars, NamespaceCard grid + NamespaceSort
    ├── NamespacesView.swift      # List view (sorted via NamespaceSort); NamespaceCard defined in OverviewView
    ├── NamespaceDetailView.swift # Drill-down: pods/services/ingresses scoped to ns; PodCardBody/ServiceCardBody/IngressCardBody/IngressPathLink
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
    └── MenuBarContent.swift      # Tray dropdown
Resources/
└── AppIcon.icns                  # slate→teal hexagon + binoculars (generated by scripts/make_icon.swift)
scripts/
├── bundle.sh                     # wraps SPM binary into KubeView.app (local dev)
└── make_icon.swift               # Core Graphics → .iconset → iconutil → AppIcon.icns
.github/workflows/release.yml     # universal binary + icon gen + ad-hoc sign + zip + Release + tap bump
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
3. **Ad-hoc signs** — `codesign --sign -`. Not notarized. Users must install
   via `brew --no-quarantine` or right-click → Open first time.
4. Zips as `KubeView-vX.Y.Z.zip` via `ditto -c -k --sequesterRsrc --keepParent`.
5. Creates GitHub Release with SHA256 in the notes.
6. Clones `omaksi/homebrew-kubeview`, rewrites `Casks/kubeview.rb` with new
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

### Upgrading to notarization

When an Apple Developer account is available:

- Add secrets: `DEV_ID_CERT_P12` (base64), `DEV_ID_CERT_PASSWORD`,
  `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` (app-specific).
- Replace `codesign --sign -` with `codesign --deep --options runtime --sign "Developer ID Application: <Name>"`.
- After zipping: `xcrun notarytool submit ... --wait` → `xcrun stapler staple KubeView.app` → rezip.
- Drop `--no-quarantine` from README and the tap's install instructions.

### Homebrew tap (separate repo)

`omaksi/homebrew-kubeview` lives at `~/Documents/GitHub/homebrew-kubeview/`.
Users install with:

```sh
brew tap omaksi/kubeview
brew install --cask kubeview --no-quarantine
```

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
  8. If list views need to participate in global search, wire via `Collection.searchFiltered(search) { [..fields..] }`; for cross-resource hits on Overview, add a section to `GlobalSearchResultsView`
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
