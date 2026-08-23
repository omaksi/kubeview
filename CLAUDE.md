# kubectl-lgtm

Read-only scaling analysis for the LGTM stack (Loki, Grafana, Tempo, Mimir) on Kubernetes. Go. Single binary, invocable as `kubectl lgtm`.

Two front ends over one core: a Bubble Tea TUI, and `--json` for machine consumers — today the KubeView macOS app (`~/GitHub/kubeview`), which bundles this binary and shells out to it the way it shells out to `kubectl`.

## Commands

```
make demo         # run against synthetic data — no cluster needed
make test         # all tests
make snapshot     # render the TUI to stdout (headless) — use to review layout changes
make build        # → bin/kubectl-lgtm
make install      # go install, puts it on $PATH for `kubectl lgtm`
make lint         # go vet + gofmt -l

go run ./cmd/kubectl-lgtm --demo --json | jq .    # the machine-readable front end
```

## Hard invariants

**1. The tool never writes to the cluster.** No code path from a keystroke to a mutation. The most destructive key is `y` (clipboard). This is the security model — it runs as the user, with their kubeconfig, so k8s RBAC does the authorization and there is no privileged identity to protect. Do not add write paths without an explicit decision to change this.

**2. Thin data produces silence, not guesses.** `Engine.Analyze` suppresses rules that reason about the metrics window when `Usage.Coverage < Cfg.MinWindow` (6h), with a `Note` explaining why. A rule reading only cluster state opts out via `NeedsHistory() bool` — "0/3 replicas ready" is a fact from the API server, and hiding it because metrics are sparse conceals the thing the operator opened the tool to see. One confidently wrong number makes an operator stop reading the tool. Tested in `TestInsufficientHistoryProducesNoRecommendations`.

**3. Every recommendation carries `Evidence`; only a recommendation that proposes a change carries `Suggested` and a `Snippet`.** Enforced by `TestEveryRecommendationCarriesEvidenceAndSnippet`, in both directions: a finding with a `Suggested` value must ship the values.yaml fragment that applies it, and a finding with no change to propose must carry no snippet. A health finding ("0/3 ready") reports a fact - its guidance goes in `Rationale`, and where to look next is the front end's job. Never fabricate YAML for a finding whose fix is not a resource change, and never put prose in `Suggested`: a front end renders it as `current -> new value`, so a sentence there draws as a broken control.

**3b. Nothing the user reads may name a flag or a shell command.** Not a warning, not an error, not a rationale, not a snippet. This output is rendered in a desktop app as often as in a terminal, and "pass `--match cluster=...`" is not something a window can act on - it reads as a dead end, which is exactly how it was reported. State the condition and its consequence; let each front end supply the remedy it can actually perform. The CLI's own `--help` is the one place flags belong. Grep before shipping: `grep -rn -e '"--' -e 'kubectl ' internal/` over non-test, non-comment lines must come back empty.

**4. Dependency direction is one-way.** `k8s`, `metrics`, `scaling` must not import `tui`. This has already paid off once: the macOS app is a second front end over the same core rather than a Swift rewrite of the rules. `scaling.Run` is the whole analysis (list, fan out usage queries, apply rules, sort worst first); a front end calls it and renders. Never reimplement that fan-out in a front end.

**5. Deployment shape is configuration, not an assumption.** The tool must work on a five-pod single-binary stack and a fifty-pod microservices one. Namespaces, label selector, kinds, pod matching, products, roles and classification overrides all live in `internal/config` and are settable by flag or YAML file. Precedence is defaults < file < flags, implemented with `fs.Visit`. Never hardcode a namespace, a role list, or a pod naming convention.

**6. No two components in one report may share a title.** `Title()` is the only label a front end shows, so a collision makes two workloads indistinguishable - and it silently corrupts the output rather than failing. It shipped twice: three alloy workloads all read `alloy` (role-less case), then four memcached-backed caches all read `mimir/memcached` (roled case, because mimir-distributed labels every cache `app.kubernetes.io/component: memcached` and the label wins in `Classify()`, so the role appears in none of their names). The second collision put "over its limit" and "over-provisioned" on screen as apparently contradictory advice about one component - they were `chunks-cache` and `index-cache`. Enforced by `TestNoTwoComponentsShareATitle`, which runs both demo topologies through `ListComponents` and detects collisions by map insertion rather than against a list of known names. The demo fixtures carry the memcached scenario on purpose: without it that test passes vacuously. A per-name test is what let this survive the first fix - do not replace the invariant with one.


**7. Surfacing detail must never change what an aggregate means.** Every rule in the catalogue reads the scalars on `Usage`, so a change to how they are computed silently moves every threshold that depends on them. When per-pod values were added, `Restarts` was switched to `sum by (pod)` and collapsed with `max` - turning a total across replicas into the busiest replica's count, and quietly moving `flappingRestarts >= 5`. Nothing failed; the numbers just became different numbers. The collapse is per metric and deliberate: **memory and CPU collapse with `max`** (they size a per-container limit, so the busiest replica is what must be covered), **restarts and OOM kills collapse with `sum`** (they are event counts across the workload), and **the throttle ratio keeps its own pooled query** (a max of per-pod ratios reads higher than the pooled figure). Verified by diffing every component's aggregates before and after against a live cluster. Do that diff again for any future change to this layer.

**8. Only the primary query may introduce a pod.** kube-state-metrics retains a series after cAdvisor has stopped reporting a pod, so a restart count arrives for pods with no memory data at all. Letting any query create a `PodUsage` entry manufactured 141 phantom replicas on a 30-component cluster, each rendering as `0Mi` - which reads as "this replica used nothing" when the truth is "we have no measurement". `vectorAgg`'s `seeds` parameter is what enforces this: the memory p99 query seeds, everything else can only fill in pods already known. A zero in this data should be treated as suspicious, never as a measurement.

## Architecture

```
cmd/kubectl-lgtm/     flags, wire(); json.go = the --json wire format; runJSON + --no-metrics
internal/k8s/         client-go: list + classify workloads (read-only)
internal/metrics/     PromQL against Prometheus/Mimir; per-pod + aggregates; discovery (discover.go)
internal/scaling/     the rule catalogue — this is the product; run.go = Run + RunNoMetrics
internal/tui/         Bubble Tea: table, detail pane, sparklines
internal/demo/        synthetic clusters + history behind --demo (large | small)
internal/format/      byte/CPU/duration rendering
internal/clipboard/   pbcopy/wl-copy/xclip, OSC 52 fallback
internal/config/      all tunables, including every metric name
```

`--demo` is implemented **solely** by swapping two interfaces in `main.wire()`:

- `tui.Source` — `k8s.Client` or `demo.Source`
- `metrics.Provider` — `metrics.Prometheus` or `demo.Provider`

Do not branch on `cfg.Demo` anywhere else. If a new data need appears, extend those interfaces so demo stays in lockstep.

## Adding a rule

Implement `scaling.Rule`, append to `scaling.DefaultRules()`. Nothing else to wire.

```go
type Rule interface {
    Name() string
    Eval(Input) []Recommendation
}
```

The engine fills in `Rule`, `Component`, `Window` and `Confidence` — a rule must not set them. Severity ordering drives read order, so pick it carefully: `Critical` is reserved for things that measurably happened (OOMKill, heavy throttling), not for inferences.

Add the fixture data to `internal/demo` at the same time, plus an expectation in `TestRulesFireOnExpectedComponents`. A rule with no fixture is untested.

Rules must read the deployment mode rather than assuming microservices. `Component.Monolithic()`, `Component.Stateful()` and `Kind == "DaemonSet"` all change what advice is correct — replicas are not a lever on a DaemonSet, and on a single binary they scale every target at once.

## Gotchas discovered the hard way

**Never return `NaN` from `metrics`.** Rules guard with `if x <= 0 { return nil }`, and every comparison against `NaN` is false — a `NaN` sails straight past the guard into the arithmetic. `queryScalar` failures return `0`.

**`bubbles`' `table.SetRows` drives the cursor to `-1`** when handed an empty set, and never restores it once rows arrive. The first `layout()` runs on the window-size message, before results exist. `layout()` re-clamps it; see `TestSelectionIsValidOnFirstPaint`. Do not remove that block.

**PromQL rejects Go's duration format.** `14*24*time.Hour` prints as `336h0m0s`. Use `promDuration()`.

**Subquery resolution is a cost multiplier.** `quantile_over_time(...)[window:step]` evaluates `window/step` samples *per pod per query*. 14d at 5m is 4032; the default step is deliberately `1h`. Don't lower it without measuring.

**The OOM metric is a gauge, not a counter.** `kube_pod_container_status_last_terminated_reason` describes the *last* termination, so the rule counts containers that OOMed at least once, not total OOM events. It undercounts repeated kills; the restart count is paired with it to compensate. Don't wrap it in `increase()`.

**Metric names are config, never constants.** cAdvisor, kube-state-metrics and the Grafana charts rename series between releases. They all live in `config.MetricNames`. A typo'd metric name renders exactly like a healthy stack — this is the most likely way the tool lies.

**The table must shed columns as the terminal narrows.** Otherwise it overflows its pane, lipgloss wraps every row, and the whole frame shears. `visibleSpecs()` drops by `dropOrder`; `rows()` and `columns()` both derive from it so headers can't drift from cells. `TestViewNeverExceedsTerminalWidth` covers 80/100/150/220.

**Endpoint discovery is an allow-list, never a deny-list.** `matchers` in `discover.go` names the services that speak PromQL; everything else is ignored. An observability namespace is full of HTTP services that are not query APIs — a Loki gateway looks similar and 404s on `/api/v1/query` — and adopting the wrong one returns zero for every rule, which renders identically to a healthy stack. The gateway must stay ranked above the query-frontend: it injects a default `X-Scope-OrgID` and the query-frontend does not, so demoting it breaks multi-tenant Mimir. Every candidate is probed with `vector(1)` before adoption; do not drop that.

**A duration flag will not accept `14d`, and the failure is silent until it isn't.** `flag.DurationVar` is backed by stdlib `time.ParseDuration`, which rejects a bare `d` unit outright. `config.ParseDuration` (which understands `14d` and `2w`) existed from the start but was wired only into the YAML file path, so `window: 14d` worked from a config file and `--window 14d` did not. It went unnoticed because the default is set in code and nobody passed the flag - until the macOS app started sending `--window 14d` on every call, at which point every request would have failed. `--window`, `--step` and `--min-window` now go through a `durationValue` flag.Value wrapper. `TestWindowFlagAcceptsDayUnits` covers the FLAG layer specifically; the pre-existing `TestParseDuration` only ever tested the parser, which was never where the bug was. Test the wiring, not just the function.

**`--no-metrics` must not reach `Engine.Analyze` with a zero-value Usage.** The thin-data gate is `Coverage > 0 && Coverage < MinWindow`, so a zero Coverage *fails* it: `thin` comes out false and every rule runs, staying silent only by accident through each rule's own `x <= 0` guards. `Engine.AnalyzeNoMetrics` filters explicitly on `NeedsHistory() == false` instead, so only `Unhealthy` can fire. The difference between silent-by-design and silent-by-luck is one added rule that forgot its guard.

**Reaching the metrics store uses a port-forward, not the API-server proxy.** The proxy (`/api/v1/namespaces/../services/name:port/proxy`) is the tidier design — no local port, no goroutine, only a `get` on `services/proxy` — and it was the original implementation. **It does not work on our EKS clusters.** Verified live: `kubectl auth can-i get services/proxy` returns yes, but `kubectl get --raw .../proxy/...` hangs for 45s+ against any pod-backed service (the control plane cannot route to the pod network), while a port-forward answers in 0.3s. The failure signature is distinctive: endpoint-less services 503 immediately, real ones time out. `forward.go` uses `spdy` + `portforward.New` with local port 0. This costs `create` on `pods/portforward` — a create verb on a read-only tool, which `explain()` in main.go calls out by name when it is missing. `--prom-url` bypasses discovery entirely; keep that escape hatch working.

**One Mimir can hold several clusters, and nothing in the data says so.** Namespace and pod names repeat across clusters, so every aggregation silently spans them and a max from a busier cluster is indistinguishable from a legitimate number. `clusterWarning()` detects it via `LabelValues("cluster", ...)` and the provider exposes it as `Warning() string`, kept **separate** from `Describe()`. It used to be concatenated onto the description, which is how it came to be invisible: the combined string outgrew the TUI header and `header()`'s tier fallback silently dropped to a shorter line, hiding the very warning that caused the overflow. Query `cfg.Metrics.MemWorkingSet`, never `up` — on a Mimir fed by Grafana Alloy the `up` series carries no `cluster` label at all, so the check returns nothing and never fires.

**The `--json` wire format is declared, not derived.** `cmd/kubectl-lgtm/json.go` defines its own structs instead of tagging the core types, so renaming an internal field cannot silently break a consumer. Changes must be additive — the macOS app decodes this. Two things bite: Go marshals `time.Time` with nanoseconds, which Swift's `JSONDecoder.dateDecodingStrategy = .iso8601` rejects outright, and `omitempty` means an absent field, not null. `--json` also implies non-interactive: no context picker, no namespace picker (`wire(cfg, quiet)` auto-picks only when there is exactly one product namespace), progress to stderr, nothing but the object on stdout.

**Table cells must never contain ANSI.** `severityBadge` returns plain text on purpose. bubbles renders every cell through `runewidth.Truncate(value, col.Width, "…")`, which counts escape bytes as visible runes: a styled `"CRIT"` is ~25 runes against a width of 5 and gets cut mid-escape, so the terminal swallows the rest of the row. Colour belongs in the detail pane, where nothing truncates it; the table conveys severity by worst-first ordering instead. This shipped broken in v0.1.0 because **headless tests cannot see it** — lipgloss uses a no-colour profile without a TTY, where the badge really is 4 runes. `internal/tui/color_test.go` forces `termenv.TrueColor` for exactly this; do not delete it.

**Use `lipgloss.Width()`, not `len()`,** for anything styled — ANSI sequences and the sparkline's multi-byte block runes both break byte counting.

**Classification matches whole dash-separated segments, never substrings.** Short roles like `all` and `read` occur inside unrelated words, and a mis-detected role changes both the scaling advice and the values.yaml key in the snippet. Roles are sorted longest-first at construction, so configured order does not matter and `query-frontend` always beats `querier`.

**Pod matching is kind-aware for a reason.** PromQL anchors regex matchers, so `loki-ingester-[0-9]+` cannot absorb `loki-ingester-zone-a-0`. The old loose `<name>-.*` form could, and would silently inflate one workload's numbers with another's. `prefix` mode still exists for unusual pod naming, but do not make it the default again.

**A slice flag replaces its default on first Set.** `--kinds Deployment` means "only Deployments", not "the defaults plus". The long and short forms share one `stringSlice` instance so `-n a --namespace b` accumulates.

## Testing

Tests run headless — no TTY needed. `renderDemo()` in `internal/tui/render_test.go` drives the model through a real `Init` → `WindowSizeMsg` → `resultsMsg` cycle and returns the rendered frame, so layout is assertable and `go test -v` prints the screen. Prefer extending that over manual checking.

Layout regressions are caught by width/height assertions across several terminal sizes. Keep them.

## Conventions

Commit messages: single line, no `Co-Authored-By` trailer (inherited from the parent repo's CLAUDE.md).

Keep `HANDOFF.md` current — it carries state between sessions.
