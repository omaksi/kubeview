# Handoff

Running state between sessions. Update the date and the sections below when you finish a chunk of work.

**Last updated:** 2026-08-04

---

## Status

Scaffold complete and green: `go build ./...`, `go vet ./...`, `gofmt -l` clean, 16 tests passing.

**Never run against a real cluster.** Everything below is verified against `internal/demo` fixtures only. The `default` kube context has no LGTM stack — no `monitoring`, `mimir`, `loki` or `observability` namespace exists. That is the single biggest caveat in this repo.

## What exists

| Package | State |
|---|---|
| `internal/config` | Flags + optional YAML file. Precedence defaults < file < flags, via `fs.Visit`. Durations accept `d`/`w`. |
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
| No autoscaling, no ingester scale-down logic | KEDA and `grafana/rollout-operator` already solve those. This tool is the cockpit over them. |
| Own sparkline instead of `ntcharts` | ~60 lines, no dependency, exact-width guarantee. Revisit if the detail pane wants a real chart. |
| Own clipboard instead of `atotto/clipboard` | Native tool + OSC 52 fallback works over SSH, which a native-only dep does not. |

## Next up

Roughly in value order.

1. **Validate against a real stack.** Nothing here has met real data. Deploy `mimir-distributed` (or point at an existing cluster) and check three things specifically:
   - do the `app.kubernetes.io/*` labels classify correctly, or does it fall through to name parsing?
   - do the metric names in `config.Default()` match the deployed chart's series?
   - is the p99 subquery fast enough at `--step 1h`, or does it time out?
2. **PVC days-until-full** — `predict_linear()` over `kubelet_volume_stats_available_bytes`. Highest-value missing rule. Needs PVC listing added to `internal/k8s`.
3. **Ingester series pressure** — `cortex_ingester_memory_series` vs the per-ingester target. The real scaling axis for Mimir and the thing a generic k8s tool cannot know.
4. **Querier queue backlog** — `cortex_query_scheduler_queue_length`.
5. **Zone imbalance** — replicas not divisible by zone count. Pure k8s data, no PromQL, cheap to add. `Component.Zone` is already populated.

## Known limitations

- **Chart key paths in snippets are a guess.** `chartKey()` maps roles to snake_case for Mimir, camelCase for Loki/Tempo, and keys collapsed targets off the product (`mimir:`) except Loki's real `singleBinary:` section. Every snippet carries a "verify the key path" comment for exactly this reason. Confirm against real charts and tighten.
- **Pod matching assumes standard Kubernetes pod naming.** `kind` mode is exact for anything the built-in controllers name, but a workload whose pods are created some other way needs `podMatch: prefix` or a `podMatchOverrides` entry. A `kube_pod_owner` join would be exact in all cases; it was skipped because it adds a kube-state-metrics dependency to every query.
- **`Primary()` container selection is heuristic** — matches the container name against product/role/workload name, else takes the first. Sidecars could be judged instead of the app.
- **OOM count is presence-based**, so repeated kills on the same container count once. See CLAUDE.md.
- **No watch/streaming.** `r` refreshes manually; there is no informer. Fine for a triage tool, wrong for a wall display.

## Open questions for the user

- Where will the LGTM stack actually live — this K3s cluster, or somewhere else? Affects whether `--prom-url` defaults are useful.
- Is there (or will there be) a **separate meta-monitoring** Prometheus? Querying the Mimir being managed means the tool goes blind exactly when it is needed.
- Repo is `git init`'d but **has no commits yet**, and no GitHub remote. Not added to the parent `GitHub/CLAUDE.md` repo list either.
