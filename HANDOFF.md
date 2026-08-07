# Handoff

Running state between sessions. Update the date and the sections below when you finish a chunk of work.

**Last updated:** 2026-08-07

---

## Status

Published and installable. `go build`, `go vet`, `gofmt -l` clean, **35 tests passing**.

```
brew install omaksi/tap/kubectl-lgtm
kubectl lgtm --demo
```

**Still never run against a real cluster.** Everything is verified against `internal/demo` fixtures only. The `default` kube context has no LGTM stack and no Prometheus — no `monitoring`, `mimir`, `loki` or `observability` namespace exists. That is the single biggest caveat in this repo and the reason v0.1.0's README leads with a status warning.

## Where things live

| Repo | Role |
|---|---|
| [omaksi/kubectl-lgtm](https://github.com/omaksi/kubectl-lgtm) | this repo — public, MIT, tagged **v0.1.0** |
| [omaksi/homebrew-tap](https://github.com/omaksi/homebrew-tap) | `brew tap omaksi/tap` — holds `Formula/kubectl-lgtm.rb` and `Casks/kubeview.rb` |
| omaksi/homebrew-kubeview | deprecated; cask removed, README redirects to the new tap |
| omaksi/kubeview | its `release.yml` was retargeted to push the cask to `homebrew-tap` |

Cutting a new version is currently **manual**: tag, `gh release create`, `shasum -a 256` the GitHub source tarball, then bump `url` and `sha256` in the tap's formula. KubeView already automates this in its own `release.yml`; the same pattern would work here. Worth doing once versions start moving.

## What exists

| Package | State |
|---|---|
| `internal/config` | Flags + optional YAML file. Precedence defaults < file < flags, via `fs.Visit`. Durations accept `d`/`w`. Config path is `~/.config/kubectl-lgtm/config.yaml` (not `os.UserConfigDir`, which is wrong on macOS for CLIs). |
| `internal/k8s` | Multi-namespace discovery with label selector and kind filter; falls back to the kubeconfig namespace when a cluster-wide list is forbidden. Config-driven `Classifier`. Untested against real labels. |
| `internal/metrics` | 6 PromQL scalars + 1 range query per component, against a `Target` carrying the pod regex. Per-query failures degrade gracefully; total failure returns an error the TUI surfaces per row. Never executed against a real Prometheus. |
| `internal/scaling` | 4 rules (below). Engine handles gating, confidence, severity sort. Advice and snippet keys vary by deployment mode. |
| `internal/tui` | Table + scrollable detail pane, sparklines, `y` copy, `g` Grafana Explore, `r` refresh, `?` help. Responsive 80→220 cols; namespace column appears only when results span several. |
| `internal/demo` | Two synthetic topologies — `large` (15 components, 4 namespaces, microservices) and `small` (5 components, one namespace, single binaries + DaemonSet). |

### Rules shipped

| Rule | Fires on | Severity |
|---|---|---|
| `oom-killed` | any container OOMKilled in window | Critical |
| `memory-near-limit` | p99 ≥85% of limit | Warn, Critical ≥95% |
| `cpu-throttling` | ≥20% CFS periods throttled | Warn, Critical ≥40% |
| `memory-over-provisioned` | requests ≥1.5× p99, wasting ≥512Mi | Info, Warn ≥2.5× |

Thresholds are named constants at the top of each `rule_*.go`. They were picked by judgement, not measurement — expect to tune them once real data exists.

## Decisions made (don't re-litigate without a reason)

| Decision | Why |
|---|---|
| App, not an operator | The hard problem is usage analysis and recommendation UX, not reconciliation. An operator owning replicas/resources would also fight ArgoCD `selfHeal` in this cluster. |
| TUI, not web | Deletes auth entirely — runs as the user, k8s RBAC authorizes. No ingress, no cert, no OIDC, no privileged ServiceAccount that can scale prod. |
| Read-only, no MR flow | User's explicit call. Display recommendations only; `y` copies the snippet instead. The `Snippet` field is already shaped so a PR path can be added later without touching the rules. |
| Don't render full time series in the terminal | Sparklines for triage, `g` opens Grafana Explore for analysis. Grafana is better at this than any TUI. |
| Discovery defaults to all namespaces | A stack is as likely to be split across mimir/loki/tempo namespaces as it is to sit in one. Falls back to the kubeconfig namespace on a forbidden cluster-wide list, and says so in the header. |
| Kind-aware pod regex over a `kube_pod_owner` join | Exact for anything the built-in controllers name, at zero query cost. The join would be exact in all cases but adds a kube-state-metrics dependency to every query. |
| Classification is data, not code | Products, roles, label keys and overrides all live in config, so a vendored or oddly-named deployment is a config change rather than a patch. |
| Build-from-source formula, not GoReleaser | ~20 lines, no CI, works on every arch, installs in 22s. Third-party taps get no bottles for free anyway. Revisit if install time becomes a complaint. |
| One generic tap, not one per app | `omaksi/tap` reads correctly for any tool. A tap named after a product forces a second tap for the next one. |
| No autoscaling, no ingester scale-down logic | KEDA and `grafana/rollout-operator` already solve those. This tool is the cockpit over them. |
| Own sparkline instead of `ntcharts` | ~60 lines, no dependency, exact-width guarantee. Revisit if the detail pane wants a real chart. |
| Own clipboard instead of `atotto/clipboard` | Native tool + OSC 52 fallback works over SSH, which a native-only dep does not. |

## Next up

### 1. Run it against a real stack — everything else is guesswork until this happens

On a machine with kubeconfig access to a live LGTM cluster:

```sh
brew install omaksi/tap/kubectl-lgtm
kubectl lgtm --all                          # discovery only; confirms auth, RBAC, classification
kubectl lgtm --window 30m --min-window 5m   # rules fire without waiting 6h for history
```

The short window matters: with the defaults, a freshly-observed stack has no history and the confidence gate correctly suppresses everything, which looks identical to the tool being broken.

Check specifically:
- do the `app.kubernetes.io/*` labels classify correctly, or does it fall through to name parsing?
- do the metric names in `config.Default()` match the deployed charts' series?
- does the p99 subquery complete at `--step 1h`, or time out?
- does `--all` misclassify anything unrelated as part of the stack?

For a local throwaway instead: `kind create cluster`, then helm-install `kube-prometheus-stack` plus `mimir-distributed`, and port-forward Prometheus to 9090. Do not install kube-prometheus-stack into the production K3s — single node, and the stack is not small.

### 2. A `--print` / non-interactive mode

Dump findings as text or JSON instead of starting the TUI. Roughly 80 lines. Unblocks three things at once: CI coverage of the full pipeline, capturing results from a remote machine to share, and the eventual headless "weekly recommendations" job. Proposed but not built.

### 3. More rules, in value order

1. **PVC days-until-full** — `predict_linear()` over `kubelet_volume_stats_available_bytes`. Highest-value missing rule. Needs PVC listing added to `internal/k8s`.
2. **Ingester series pressure** — `cortex_ingester_memory_series` vs the per-ingester target. The real scaling axis for Mimir and the thing a generic k8s tool cannot know.
3. **Querier queue backlog** — `cortex_query_scheduler_queue_length`.
4. **Zone imbalance** — replicas not divisible by zone count. Pure k8s data, no PromQL, cheap. `Component.Zone` is already populated.

### 4. Automate the release

Tag → build → release → formula bump, so a version is one command rather than four manual steps and a hand-computed checksum.

## Known limitations

- **Chart key paths in snippets are a guess.** `chartKey()` maps roles to snake_case for Mimir, camelCase for Loki/Tempo, and keys collapsed targets off the product (`mimir:`) except Loki's real `singleBinary:` section. Every snippet carries a "verify the key path" comment for exactly this reason. Confirm against real charts and tighten.
- **Pod matching assumes standard Kubernetes pod naming.** `kind` mode is exact for anything the built-in controllers name, but a workload whose pods are created some other way needs `podMatch: prefix` or a `podMatchOverrides` entry.
- **`Primary()` container selection is heuristic** — matches the container name against product/role/workload name, else takes the first. Sidecars could be judged instead of the app.
- **OOM count is presence-based**, so repeated kills on the same container count once. See CLAUDE.md.
- **No watch/streaming.** `r` refreshes manually; there is no informer. Fine for a triage tool, wrong for a wall display.

## Open questions for the user

- **Does `TAP_TOKEN` in `omaksi/kubeview` have write access to `omaksi/homebrew-tap`?** Its `release.yml` now pushes there instead of `homebrew-kubeview`. If that secret is a fine-grained PAT scoped to the old repo, the next KubeView release will 403 on the tap-update step. Cannot be verified without cutting a release or inspecting the token.
- Where will the LGTM stack actually live — a K3s cluster, or somewhere else? Affects whether the `--prom-url` default is worth changing.
- Is there (or will there be) a **separate meta-monitoring** Prometheus? Querying the Mimir being managed means the tool goes blind exactly when it is needed.
- `kubectl-lgtm` is not in the parent `GitHub/CLAUDE.md` repo list yet.
- Should `omaksi/homebrew-kubeview` be archived on GitHub, or left as a live redirect?
