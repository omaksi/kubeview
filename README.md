# KubeView

Native macOS desktop app for viewing Kubernetes clusters.

## Install

Via Homebrew tap:

```sh
brew tap omaksi/kubeview
brew install --cask kubeview --no-quarantine
```

The `--no-quarantine` flag is required because the app is ad-hoc signed (not notarized).
Alternatively, after install: `xattr -dr com.apple.quarantine /Applications/KubeView.app`

Or download the `.zip` directly from the [Releases](https://github.com/omaksi/kubeview/releases)
page. First launch: right-click → Open.

## Features

- Overview: cluster stats, node CPU/memory usage, per-namespace summary cards
- Namespaces: pod counts, failing pods, resource requests/usage, ingress counts
- Pods: filterable table with status, restarts, node
- Nodes: conditions, kubelet version, OS
- Ingresses: hosts, paths, backend services, TLS status
- Menu bar indicator: summary + context switcher

Requires `kubectl` on `PATH`. `metrics-server` is optional (enables live CPU/mem).

## Build from source

```sh
swift build -c release
./scripts/bundle.sh release
open build/KubeView.app
```

Requires macOS 14+, Swift 5.9+.

## License

MIT
