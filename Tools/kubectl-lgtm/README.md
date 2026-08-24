# kubectl-lgtm

A read-only terminal dashboard for scaling the LGTM stack (Loki, Grafana, Tempo, Mimir) on Kubernetes.

It shows current and historical resource usage per component and turns that into scaling recommendations, each with the PromQL behind it and a ready-to-paste `values.yaml` snippet.

**It never writes to the cluster.** The most destructive thing a keystroke can do is put YAML on your clipboard.

```
make demo                                   # no cluster needed
./bin/kubectl-lgtm --demo --demo-topology small
```

It adapts to how your stack is actually deployed — one namespace or five, microservices or a single binary — via selectors and classification rules you control.

## Why read-only

The tool runs as *you*, with your kubeconfig, so Kubernetes RBAC does the authorization. There is no ingress, no OIDC, no long-lived ServiceAccount with permission to scale production, and nothing to protect. It needs `get`/`list`/`watch` on `deployments`, `statefulsets`, `daemonsets` and `services`, plus `get` on `services/proxy` so it can reach the metrics store through the API server rather than asking you to port-forward. Pass `--prom-url` instead and the `services/proxy` grant is not needed at all.

Changes go through your normal GitOps review: read a finding, press `y`, paste into the values file, open the MR.

> **Status: v0.1.0, early.** Verified against synthetic fixtures only — it has not yet been run against a live LGTM stack. Metric names and Helm key paths may need adjusting for your deployment; see `config.example.yaml`. It cannot damage anything (read-only, `get`/`list`/`watch`), but it can be wrong.

## Install

```
brew install omaksi/tap/kubectl-lgtm
```

Or from source, from a clone of this monorepo:

```
cd Tools/kubectl-lgtm
make install       # go install into $GOPATH/bin
```

`go install github.com/omaksi/kubectl-lgtm/...@latest` does **not** work any
more. That module path still resolves to the standalone repo, which is archived
and frozen before `--json` - the command succeeds and silently installs the old
binary. Use Homebrew, or build from a clone as above.

Named `kubectl-lgtm`, so anywhere on `$PATH` it is also invocable as `kubectl lgtm`.

## Usage

```
kubectl lgtm                                     # pick a cluster, find its metrics store, go
kubectl lgtm --context stg-eks                   # skip the picker
kubectl lgtm -n mimir,loki,tempo                 # limit the search
kubectl lgtm --prom-url http://localhost:9090    # bypass discovery entirely
kubectl lgtm -l app.kubernetes.io/part-of=memberlist --window 7d
kubectl lgtm --demo
```

| Flag | Default | Notes |
|---|---|---|
| `-n, --namespace` | all namespaces | repeatable or comma-separated |
| `-l, --selector` | — | label selector for discovery |
| `--kinds` | Deployment, StatefulSet, DaemonSet | replaces the default set |
| `--pod-match` | `kind` | `kind` or `prefix` — see below |
| `--context` | — | kubeconfig context; omit it and the tool asks which cluster |
| `--prom-url` | discovered | Prometheus or Mimir query endpoint; set it to skip discovery |
| `--tenant` | — | Mimir tenant, sent as `X-Scope-OrgID` |
| `--match` | — | extra PromQL label matchers, e.g. `cluster="inno-shared-eks"` |
| `--window` | 14d | lookback for every recommendation |
| `--step` | `1h` | inner resolution of range queries — keep coarse |
| `--min-window` | `6h` | below this, no recommendations are produced |
| `--grafana-url` | — | enables the `g` key |
| `--all` | off | keep workloads that weren't recognised |
| `--config` | `~/.config/kubectl-lgtm/config.yaml` | see `config.example.yaml` |
| `--demo` | off | synthetic data, no cluster or Prometheus needed |
| `--demo-topology` | `large` | `large` (microservices) or `small` (single binary) |

### How it finds things

Run the bare binary and it works out what to do: reads every kubeconfig in `$KUBECONFIG` and `~/.kube/config` and asks which cluster; finds the namespaces that actually hold LGTM components and asks which one — but only when there is a real choice, so a stack in a single namespace is never a question; picks a query endpoint; then probes it with `vector(1)` to confirm it really speaks PromQL before adopting it.

On a central store that holds several clusters, the header says so and tells you to pass `--match`. Namespace and pod names repeat across clusters, so without a matcher a component's memory can come back as the max across all of them and look like a perfectly ordinary number.

Endpoint ranking is an allow-list — a Mimir gateway, then Thanos query, then Prometheus, then a Mimir query-frontend. The gateway outranks the query-frontend because it injects a default `X-Scope-OrgID`, so multi-tenant Mimir answers without `--tenant`. Anything unrecognised is never tried: an observability namespace is full of HTTP services that are not query APIs, and adopting the wrong one sends every rule silently to zero.

Queries reach the Service through the API server's proxy, so **no local port is opened** — nothing to allocate, collide, leak or clean up.

Point `--prom-url` at a **separate meta-monitoring** Prometheus if you have one. Querying the Mimir you are managing means the tool goes blind exactly when you need it.

## Fitting it to your stack

With no flags it searches every namespace you can list and keeps what it recognises, falling back to your kubeconfig namespace if a cluster-wide list is forbidden. That covers most deployments. For the rest, everything below is configurable — see `config.example.yaml`. Precedence is **defaults < config file < flags**.

### Discovery

`namespaces`, `selector` and `kinds` control what gets listed. A big cluster tends to want `namespaces: [mimir, loki, tempo]`; a shared namespace wants a `selector`.

### Deployment mode

Both shapes classify out of the box. Microservices roles (`ingester`, `query-frontend`, `store-gateway`…) and collapsed ones (`all`, `single-binary`, `read`, `write`, `backend`) are all recognised, from `app.kubernetes.io/*` labels where present and from the workload name otherwise.

Mode changes the advice, not just the label. A memory ceiling on a stateless `querier` suggests adding replicas; on a `single-binary` it doesn't, because replicas there scale every target at once. Snippets follow suit — a Loki single binary keys off `singleBinary:`, a Mimir `all` target off `mimir:`.

Name matching is on **whole dash-separated segments**, so `all` matches `mimir-all` but not `mimir-smallish`. Where two roles match, the longer one wins.

### Pod matching

The trickiest part, because cAdvisor series carry `pod`, not your app labels.

| Mode | Pattern | Use when |
|---|---|---|
| `kind` (default) | `<sts>-<ordinal>`, `<deploy>-<hash>-<hash>`, `<ds>-<suffix>` | almost always |
| `prefix` | `<workload>-.*` | pods named unusually |

`kind` matters more than it sounds. PromQL anchors regex matchers, so `loki-ingester-[0-9]+` cannot absorb `loki-ingester-zone-a-0` — the loose prefix form can, and would silently inflate one workload's numbers with another's. The detail pane prints the pattern in use, because a wrong one looks exactly like no data. `podMatchOverrides` is the escape hatch.

### Classification

`classify.products` adds aliases (a vendored distribution, `cortex` for older Mimir), `classify.roles` adds role names, and `classify.overrides` forces the answer for workloads no convention covers:

```yaml
classify:
  overrides:
    - namespace: observability
      name: "^lgtm-.*"
      product: mimir
      role: all
```

### Keys

| Key | Action |
|---|---|
| `↑`/`↓`, `k`/`j` | move between components |
| `tab` | focus the detail pane and scroll it |
| `y` | copy every `values.yaml` snippet for the selected component |
| `g` | open the component's memory query in Grafana Explore |
| `r` | refresh |
| `?` | expand help |
| `q` | quit |

`y` uses `pbcopy`/`wl-copy`/`xclip` when present, and falls back to OSC 52 so it works over SSH. In tmux that needs `set -g set-clipboard on`.

## Rules

| Rule | Fires on | Severity |
|---|---|---|
| `oom-killed` | any container OOMKilled in the window | Critical |
| `memory-near-limit` | p99 working set ≥85% of the limit | Warn, Critical ≥95% |
| `cpu-throttling` | ≥20% of CFS periods throttled | Warn, Critical ≥40% |
| `memory-over-provisioned` | requests ≥1.5× p99 usage, wasting ≥512Mi | Info, Warn ≥2.5× |

Two properties are deliberate and worth preserving as the catalogue grows:

**Every recommendation carries its evidence.** "Scale down the ingesters" gets ignored; the same claim with the expression, the number and the window gets acted on — and stays debuggable when it is wrong.

**Thin data produces silence, not guesses.** A component with less than `--window`'s worth of history (floor: 6h) yields no recommendations at all, and says why. One confidently wrong number is enough to make an operator stop reading the tool.

### Adding a rule

Implement `scaling.Rule`, append it to `DefaultRules()`. The rule sees the component's pod spec and its usage history, and returns recommendations with evidence and a snippet — nothing else is wired up.

```go
type Rule interface {
    Name() string
    Eval(Input) []Recommendation
}
```

Worth adding next, roughly in order of value:

- **PVC days-until-full** — `predict_linear()` over `kubelet_volume_stats_available_bytes`. The one that saves your weekend.
- **Ingester series pressure** — `cortex_ingester_memory_series` against the per-ingester target. The real scaling axis for Mimir, and the one a generic tool can't know about.
- **Querier queue backlog** — `cortex_query_scheduler_queue_length`.
- **Zone imbalance** — replicas not divisible by the zone count; a silent replication risk, and pure Kubernetes data with no PromQL needed.

## Metric names

cAdvisor, kube-state-metrics and the Mimir/Loki/Tempo charts rename series between releases, so every metric name lives in `config.MetricNames` rather than in a rule. Verify them against your deployment before trusting a quiet screen — a typo'd metric name looks exactly like a healthy stack.

## Architecture

```
cmd/kubectl-lgtm/     flag parsing, wiring
internal/k8s/         client-go: list + classify workloads (read-only)
internal/metrics/     PromQL against Prometheus/Mimir
internal/scaling/     the rule catalogue — this is the product
internal/tui/         Bubble Tea: table, detail pane, sparklines
internal/demo/        synthetic cluster + history for --demo
internal/format/      byte/CPU/duration rendering
internal/clipboard/   pbcopy/wl-copy/xclip, OSC 52 fallback
```

`k8s`, `metrics` and `scaling` know nothing about the TUI. If a shared web dashboard or a headless "weekly recommendations" job is wanted later, it is a new front end over the same core, not a rewrite.

`--demo` is implemented purely by swapping the two interfaces (`tui.Source`, `metrics.Provider`) for fixtures — no branching anywhere else.

## Not doing (yet)

- Writing to the cluster or opening MRs
- Autoscaling — use [KEDA](https://keda.sh); Mimir ships reference ScaledObjects
- Safe ingester scale-down — use [`grafana/rollout-operator`](https://github.com/grafana/rollout-operator), which already solves the dangerous part
- Full time-series analysis — press `g`; Grafana is better at it than any terminal
