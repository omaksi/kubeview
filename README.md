# KubeView

Native macOS desktop apps for Kubernetes: **KubeView**, a multi-context cluster
browser, and **LgtmView**, an inspector for a Grafana LGTM stack.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 6.3+](https://img.shields.io/badge/Swift-6.3%2B-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Install

### Homebrew tap (recommended)

```sh
brew tap omaksi/tap
brew trust omaksi/tap
brew install --cask kubeview
open -a KubeView
```

`brew trust` is required by Homebrew 6+ for any third-party tap — installing a
cask evaluates Ruby from this repo, so Homebrew asks you to opt in once per
machine. Without it, `install` *and* `upgrade` both fail with "Refusing to load
cask from untrusted tap".

Releases from v0.2.1 on are signed with a Developer ID certificate and notarized
by Apple, so they launch without Gatekeeper warnings. Older releases were ad-hoc
signed and need `brew install --cask kubeview --no-quarantine`.

Upgrade to the latest release:

```sh
brew update && brew upgrade --cask kubeview
```

### LgtmView

This repo ships a second, separate app: **LgtmView**, a focused inspector for a
Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) running in a cluster.

```sh
brew tap omaksi/tap
brew trust omaksi/tap
brew install --cask lgtm-view
open -a LgtmView
```

LgtmView shells out to the `kubectl-lgtm` CLI rather than embedding it, so the
cask pulls in `omaksi/tap/kubectl-lgtm` as a dependency automatically. The two
apps share no state and no UI - installing or removing one does not affect the
other.

### Direct download

Grab `KubeView-vX.Y.Z.zip` from the [Releases](https://github.com/omaksi/kubeview/releases)
page, unzip, drag into `/Applications`, and open it — the notarization ticket is
stapled to the app, so it launches normally with no right-click workaround.

### Requirements

- macOS 14 (Sonoma) or newer — Apple Silicon or Intel
- `kubectl` on `PATH` (e.g. `brew install kubernetes-cli`)
- `metrics-server` installed in the cluster — **optional**; enables live CPU/memory

### Uninstall

```sh
brew uninstall --cask kubeview
brew untap omaksi/tap
```

## Usage

- **Cluster bar** (top of window): active contexts as pills; click to switch, × to
  remove, `+` to activate another. Switching doesn't mutate your kubeconfig — each
  context uses `--context` under the hood.
- **Menu bar icon**: aggregate health across active clusters + per-cluster summaries.
- **Sidebar**: grouped by Cluster / Workloads / Network / Storage / Config & RBAC /
  Service Mesh. Empty sections auto-hide.
- **Cards-first**: every list view starts as cards. Toggle to a table via the icon
  top-right.
- **Drill-downs**: namespace cards → pods/services/ingresses scoped to it. Pod cards
  → Overview / Logs / Describe tabs.
- **Right-click any card** → Set Emoji, or **Describe…** (runs `kubectl describe`).

## Featureset

| Category | Resources |
|---|---|
| Cluster | Namespaces, Nodes (with live CPU/mem), Events (lazy-load) |
| Workloads | Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, Pods, HPAs |
| Network | Services, Ingresses, NetworkPolicies |
| Storage | PVCs, StorageClasses |
| Config & RBAC | ConfigMaps, Secrets, ServiceAccounts, IRSA (filtered SA view) |
| Service Mesh | Linkerd (detects `linkerd-proxy` sidecar, lists meshed workloads) |

**Extras:**
- Multi-cluster simultaneous polling (one 5s loop per active context; secrets /
  configmaps on 30s cadence)
- Unhealthy detection: ImagePullBackOff, CrashLoopBackOff, failing Deployments,
  StatefulSets, DaemonSets surfaced in Overview + namespace cards
- Pod logs viewer: tail size (100/500/1k/5k), `--previous`, per-container picker,
  line filter, copy
- Universal Describe sheet for any resource
- Custom emoji per resource (persists via UserDefaults)
- Context-safe switching (no kubeconfig mutation)

## Build from source

Builds two apps from one package. `swift build` alone builds both; bundling is
per app:

```sh
swift build -c release

./scripts/bundle.sh release                       # -> build/KubeView.app
./scripts/bundle.sh --app-name LgtmView \
                    --bundle-id com.omaksi.lgtmview release   # -> build/LgtmView.app
```

Needs **Xcode 26 / Swift 6.3 or newer**. `Package.swift` still declares
`swift-tools-version: 5.9`, but that is the manifest format, not the compiler
requirement - the source does not build on Swift 5.10. CI runs on `macos-26`
for this reason.

Swift Package Manager executable; opens straight in Xcode too:

```sh
xed .
```

## License

MIT © 2026 Ondrej Maksi
