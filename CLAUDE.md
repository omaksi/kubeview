# kubectl-lgtm

Read-only TUI for scaling the LGTM stack (Loki, Grafana, Tempo, Mimir) on Kubernetes. Go + Bubble Tea. Single binary, invocable as `kubectl lgtm`.

## Commands

```
make demo         # run against synthetic data — no cluster needed
make test         # all tests
make snapshot     # render the TUI to stdout (headless) — use to review layout changes
make build        # → bin/kubectl-lgtm
make install      # go install, puts it on $PATH for `kubectl lgtm`
make lint         # go vet + gofmt -l
```

## Hard invariants

**1. The tool never writes to the cluster.** No code path from a keystroke to a mutation. The most destructive key is `y` (clipboard). This is the security model — it runs as the user, with their kubeconfig, so k8s RBAC does the authorization and there is no privileged identity to protect. Do not add write paths without an explicit decision to change this.

**2. Thin data produces silence, not guesses.** `Engine.Analyze` returns zero recommendations when `Usage.Coverage < Cfg.MinWindow` (6h), with a `Note` explaining why. One confidently wrong number makes an operator stop reading the tool. Tested in `TestInsufficientHistoryProducesNoRecommendations`.

**3. Every recommendation carries `Evidence` and a `Snippet`.** Enforced by `TestEveryRecommendationCarriesEvidenceAndSnippet`. A finding without the query and the number behind it gets ignored in practice.

**4. Dependency direction is one-way.** `k8s`, `metrics`, `scaling` must not import `tui`. A headless job or web view later should be a new front end over the same core, not a rewrite.

**5. Deployment shape is configuration, not an assumption.** The tool must work on a five-pod single-binary stack and a fifty-pod microservices one. Namespaces, label selector, kinds, pod matching, products, roles and classification overrides all live in `internal/config` and are settable by flag or YAML file. Precedence is defaults < file < flags, implemented with `fs.Visit`. Never hardcode a namespace, a role list, or a pod naming convention.

## Architecture

```
cmd/kubectl-lgtm/     flags, wire()
internal/k8s/         client-go: list + classify workloads (read-only)
internal/metrics/     PromQL against Prometheus/Mimir
internal/scaling/     the rule catalogue — this is the product
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
