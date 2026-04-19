# KubeView

Native macOS desktop app for viewing Kubernetes clusters across multiple contexts.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Install

### Homebrew tap (recommended)

```sh
brew tap omaksi/kubeview
brew install --cask kubeview --no-quarantine
open -a KubeView
```

`--no-quarantine` is required because the app is ad-hoc signed (not notarized).
Alternatively, after install: `xattr -dr com.apple.quarantine /Applications/KubeView.app`.

Upgrade to the latest release:

```sh
brew update && brew upgrade --cask kubeview
```

### Direct download

Grab `KubeView-vX.Y.Z.zip` from the [Releases](https://github.com/omaksi/kubeview/releases)
page, unzip, drag into `/Applications`. First launch: right-click the app → **Open**
(Gatekeeper prompts once; subsequent launches don't).

### Requirements

- macOS 14 (Sonoma) or newer — Apple Silicon or Intel
- `kubectl` on `PATH` (e.g. `brew install kubernetes-cli`)
- `metrics-server` installed in the cluster — **optional**; enables live CPU/memory

### Uninstall

```sh
brew uninstall --cask kubeview
brew untap omaksi/kubeview
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

```sh
swift build -c release
./scripts/bundle.sh release
open build/KubeView.app
```

Swift Package Manager executable; opens straight in Xcode too:

```sh
xed .
```

## License

MIT © 2026 Ondrej Maksi
