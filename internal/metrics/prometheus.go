package metrics

import (
	"context"
	"fmt"
	"math"
	"sort"
	"time"

	promapi "github.com/prometheus/client_golang/api"
	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"
	"github.com/prometheus/common/model"

	"github.com/omaksi/kubectl-lgtm/internal/config"
)

// Prometheus reads usage from a Prometheus-compatible query API. Mimir's
// /prometheus endpoint works unchanged.
type Prometheus struct {
	api promv1.API
	cfg config.Config
	// desc names the endpoint for the status bar. A discovered endpoint has no
	// URL the operator ever typed, so it needs saying where it came from.
	desc string
	// warn is a caveat about the store itself, kept apart from desc so a front
	// end can give it the prominence it needs. Gluing it onto the description
	// was how the TUI came to hide it: the combined string outgrew the header
	// and the layout silently dropped to a shorter tier.
	warn string
}

// NewPrometheus dials the query endpoint. It does not verify reachability;
// the first query surfaces any connection error, which keeps startup fast.
func NewPrometheus(cfg config.Config) (*Prometheus, error) {
	c, err := promapi.NewClient(promapi.Config{Address: cfg.PromURL})
	if err != nil {
		return nil, fmt.Errorf("prometheus client for %q: %w", cfg.PromURL, err)
	}
	return &Prometheus{api: promv1.NewAPI(c), cfg: cfg, desc: cfg.PromURL}, nil
}

func (p *Prometheus) Describe() string { return p.desc }

// Warning reports a caveat about the store, or "" when there is none.
func (p *Prometheus) Warning() string { return p.warn }

// Usage runs the full query set for one workload. Individual query failures are
// tolerated — a missing kube-state-metrics should degrade the OOM rule, not
// blank the whole row.
func (p *Prometheus) Usage(ctx context.Context, t Target) (Usage, error) {
	sel := p.selector(t)
	win := promDuration(p.cfg.Window)
	step := promDuration(p.cfg.Step)
	m := p.cfg.Metrics

	u := Usage{}
	now := time.Now()

	// Failures are counted rather than propagated: a missing kube-state-metrics
	// should silence the OOM rule, not blank the whole row. Only a total
	// failure — nothing answered at all — is reported as an error.
	var attempted, ok int
	scalar := func(expr string) float64 {
		attempted++
		v, err := p.queryScalar(ctx, expr, now)
		if err != nil {
			// Zero, not NaN: rules guard with `<= 0`, and every NaN comparison
			// is false, so a NaN would slip past the guard into the arithmetic.
			u.Queries = append(u.Queries, Sample{Expr: expr, Value: 0})
			return 0
		}
		ok++
		u.Queries = append(u.Queries, Sample{Expr: expr, Value: v})
		return v
	}

	// Per-pod, not per-workload. These expressions already compute `max by
	// (pod)`; the previous version wrapped each in `max(...)` and threw the
	// replicas away. Reporting them costs nothing extra and is the only way to
	// see one replica carrying a workload while its siblings idle.
	perPod := map[string]*PodUsage{}
	pod := func(name string) *PodUsage {
		if p, ok := perPod[name]; ok {
			return p
		}
		p := &PodUsage{Pod: name}
		perPod[name] = p
		return p
	}

	// seeds reports whether this query may introduce pods. Only the first one
	// does: kube-state-metrics retains a series for a pod after cAdvisor has
	// stopped reporting it, so a restart count can arrive for a pod with no
	// memory data at all. Letting that create an entry renders as "0Mi", which
	// reads as "this replica used nothing" rather than "we have no measurement".
	vectorAgg := func(expr string, seeds bool, agg func(map[string]float64) float64,
		assign func(*PodUsage, float64)) float64 {
		attempted++
		vals, err := p.queryVector(ctx, expr, now)
		if err != nil {
			u.Queries = append(u.Queries, Sample{Expr: expr, Value: 0})
			return 0
		}
		ok++
		for name, v := range vals {
			if !seeds {
				if existing, known := perPod[name]; known {
					assign(existing, v)
				}
				continue
			}
			assign(pod(name), v)
		}
		total := agg(vals)
		u.Queries = append(u.Queries, Sample{Expr: expr, Value: total})
		return total
	}

	// The aggregate each rule already reasons about must not change meaning just
	// because the per-pod values became visible. Memory and CPU size a limit, so
	// they collapse with max - the busiest replica is what a per-container limit
	// has to cover. Restarts and OOM kills are counts of events across the
	// workload, so they collapse with sum. Getting this backwards would silently
	// move every threshold in the rule catalogue.
	vector := func(expr string, seeds bool, assign func(*PodUsage, float64)) float64 {
		return vectorAgg(expr, seeds, maxOf, assign)
	}

	u.MemP99Bytes = vector(fmt.Sprintf(
		`quantile_over_time(0.99, max by (pod) (%s{%s})[%s:%s])`,
		m.MemWorkingSet, sel, win, step), true,
		func(p *PodUsage, v float64) { p.MemP99Bytes = v })

	u.MemMaxBytes = vector(fmt.Sprintf(
		`max_over_time(max by (pod) (%s{%s})[%s:%s])`,
		m.MemWorkingSet, sel, win, step), false,
		func(p *PodUsage, v float64) { p.MemMaxBytes = v })

	u.CPUP99Millis = vector(fmt.Sprintf(
		`quantile_over_time(0.99, sum by (pod) (rate(%s{%s}[5m]))[%s:%s]) * 1000`,
		m.CPUUsage, sel, win, step), false,
		func(p *PodUsage, v float64) { p.CPUP99Millis = v })
	// Pooled across the workload for the aggregate, because that is what the
	// rule compares against - a per-pod ratio maxed would read higher and move
	// the threshold. The per-pod ratios come from the same expression grouped by
	// pod, so one replica being throttled while its siblings are not is visible
	// without changing what the rule sees.
	u.ThrottleRatio = scalar(fmt.Sprintf(
		`sum(increase(%s{%s}[%s])) / clamp_min(sum(increase(%s{%s}[%s])), 1)`,
		m.ThrottledPeriods, sel, win, m.TotalPeriods, sel, win))

	vectorAgg(fmt.Sprintf(
		`sum by (pod) (increase(%s{%s}[%s])) / clamp_min(sum by (pod) (increase(%s{%s}[%s])), 1)`,
		m.ThrottledPeriods, sel, win, m.TotalPeriods, sel, win), false, maxOf,
		func(p *PodUsage, v float64) { p.ThrottleRatio = v })

	// Presence-based, not a counter: this metric is a gauge describing the last
	// termination reason, so it counts containers that OOMed at least once, not
	// total OOM events. Paired with the restart count below it is enough to act.
	u.OOMContainers = vectorAgg(fmt.Sprintf(
		`count by (pod) (max_over_time(%s{%s,reason="OOMKilled"}[%s]) > 0)`,
		m.LastTermReason, p.podSelector(t), win), false, sumOf,
		func(p *PodUsage, v float64) { p.OOMContainers = v })

	u.Restarts = vectorAgg(fmt.Sprintf(
		`sum by (pod) (increase(%s{%s}[%s]))`,
		m.Restarts, p.podSelector(t), win), false, sumOf,
		func(p *PodUsage, v float64) { p.Restarts = v })

	// Stable order so a redraw does not reshuffle the replicas under the reader.
	// StatefulSet pods sort naturally by ordinal; the hashed names of a
	// Deployment have no meaningful order, so alphabetical is as good as any.
	u.Pods = make([]PodUsage, 0, len(perPod))
	for _, pu := range perPod {
		u.Pods = append(u.Pods, *pu)
	}
	sort.Slice(u.Pods, func(i, j int) bool { return u.Pods[i].Pod < u.Pods[j].Pod })

	series, coverage, err := p.series(ctx, sel, now)
	if err == nil {
		ok++
		u.Series = series
		u.Coverage = coverage
	}
	attempted++

	if ok == 0 {
		return Usage{}, fmt.Errorf("no data from %s for %s/%s (%d queries, none answered)",
			p.desc, t.Namespace, t.Name, attempted)
	}
	return u, nil
}

// selector matches the containers of a workload's pods, excluding the pause
// container and any sidecar-free aggregate series.
func (p *Prometheus) selector(t Target) string {
	return fmt.Sprintf(`namespace=%q,pod=~%q,container!="",container!="POD"%s`,
		t.Namespace, t.PodPattern, p.extra())
}

// extra appends the configured label matchers. On a store that aggregates
// several clusters the namespace and pod names repeat in each of them, so
// without a cluster matcher every aggregation quietly spans clusters.
func (p *Prometheus) extra() string {
	if p.cfg.Match == "" {
		return ""
	}
	return "," + p.cfg.Match
}

// podSelector is the same match without the container filter, for
// kube-state-metrics series that are labelled per pod.
func (p *Prometheus) podSelector(t Target) string {
	return fmt.Sprintf(`namespace=%q,pod=~%q%s`, t.Namespace, t.PodPattern, p.extra())
}

func (p *Prometheus) queryScalar(ctx context.Context, expr string, at time.Time) (float64, error) {
	val, _, err := p.api.Query(ctx, expr, at)
	if err != nil {
		return 0, err
	}
	vec, ok := val.(model.Vector)
	if !ok || len(vec) == 0 {
		return 0, fmt.Errorf("no data for %s", expr)
	}
	f := float64(vec[0].Value)
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return 0, fmt.Errorf("non-finite result for %s", expr)
	}
	return f, nil
}

// queryVector runs an expression that keeps its `pod` label and returns one
// value per pod.
//
// This is the same query queryScalar runs, minus the outer aggregation: the
// expressions already compute `max by (pod)`, so the per-replica values exist
// and were simply being discarded. Keeping them costs no extra query.
func (p *Prometheus) queryVector(ctx context.Context, expr string, at time.Time) (map[string]float64, error) {
	val, _, err := p.api.Query(ctx, expr, at)
	if err != nil {
		return nil, err
	}
	vec, ok := val.(model.Vector)
	if !ok || len(vec) == 0 {
		return nil, fmt.Errorf("no data for %s", expr)
	}
	out := make(map[string]float64, len(vec))
	for _, s := range vec {
		f := float64(s.Value)
		if math.IsNaN(f) || math.IsInf(f, 0) {
			continue
		}
		pod := string(s.Metric["pod"])
		if pod == "" {
			continue
		}
		// A pod can appear more than once if the expression leaves another
		// label in place; keep the larger rather than letting map order decide.
		if prev, seen := out[pod]; !seen || f > prev {
			out[pod] = f
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no pod-labelled results for %s", expr)
	}
	return out, nil
}

// sumOf totals a per-pod map, for counts of events rather than levels.
func sumOf(m map[string]float64) float64 {
	var out float64
	for _, v := range m {
		out += v
	}
	return out
}

// maxOf collapses a per-pod map to the single worst value. Sizing a limit needs
// the busiest replica, because a limit is enforced per container - the average
// would OOM-kill whichever pod is above it.
func maxOf(m map[string]float64) float64 {
	var out float64
	for _, v := range m {
		if v > out {
			out = v
		}
	}
	return out
}

// series fetches the memory sparkline and reports how much of the requested
// window actually contained data.
func (p *Prometheus) series(ctx context.Context, sel string, now time.Time) ([]float64, time.Duration, error) {
	points := p.cfg.SparkPoints
	if points < 2 {
		points = 2
	}
	step := p.cfg.Window / time.Duration(points)
	expr := fmt.Sprintf(`max(%s{%s})`, p.cfg.Metrics.MemWorkingSet, sel)

	val, _, err := p.api.QueryRange(ctx, expr, promv1.Range{
		Start: now.Add(-p.cfg.Window),
		End:   now,
		Step:  step,
	})
	if err != nil {
		return nil, 0, err
	}
	matrix, ok := val.(model.Matrix)
	if !ok || len(matrix) == 0 {
		return nil, 0, fmt.Errorf("no range data")
	}

	out := make([]float64, 0, len(matrix[0].Values))
	for _, pair := range matrix[0].Values {
		out = append(out, float64(pair.Value))
	}
	coverage := time.Duration(len(out)) * step
	if coverage > p.cfg.Window {
		coverage = p.cfg.Window
	}
	return out, coverage, nil
}

// promDuration renders a Go duration in PromQL's duration syntax. Go prints
// 336h0m0s for 14 days, which PromQL rejects.
func promDuration(d time.Duration) string {
	switch {
	case d%(24*time.Hour) == 0:
		return fmt.Sprintf("%dd", int(d.Hours())/24)
	case d%time.Hour == 0:
		return fmt.Sprintf("%dh", int(d.Hours()))
	case d%time.Minute == 0:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	default:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
}
