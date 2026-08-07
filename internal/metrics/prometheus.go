package metrics

import (
	"context"
	"fmt"
	"math"
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
}

// NewPrometheus dials the query endpoint. It does not verify reachability;
// the first query surfaces any connection error, which keeps startup fast.
func NewPrometheus(cfg config.Config) (*Prometheus, error) {
	c, err := promapi.NewClient(promapi.Config{Address: cfg.PromURL})
	if err != nil {
		return nil, fmt.Errorf("prometheus client for %q: %w", cfg.PromURL, err)
	}
	return &Prometheus{api: promv1.NewAPI(c), cfg: cfg}, nil
}

func (p *Prometheus) Describe() string { return p.cfg.PromURL }

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

	u.MemP99Bytes = scalar(fmt.Sprintf(
		`max(quantile_over_time(0.99, max by (pod) (%s{%s})[%s:%s]))`,
		m.MemWorkingSet, sel, win, step))

	u.MemMaxBytes = scalar(fmt.Sprintf(
		`max(max_over_time(max by (pod) (%s{%s})[%s:%s]))`,
		m.MemWorkingSet, sel, win, step))

	u.CPUP99Millis = scalar(fmt.Sprintf(
		`max(quantile_over_time(0.99, sum by (pod) (rate(%s{%s}[5m]))[%s:%s])) * 1000`,
		m.CPUUsage, sel, win, step))

	u.ThrottleRatio = scalar(fmt.Sprintf(
		`sum(increase(%s{%s}[%s])) / clamp_min(sum(increase(%s{%s}[%s])), 1)`,
		m.ThrottledPeriods, sel, win, m.TotalPeriods, sel, win))

	// Presence-based, not a counter: this metric is a gauge describing the last
	// termination reason, so it counts containers that OOMed at least once, not
	// total OOM events. Paired with the restart count below it is enough to act.
	u.OOMContainers = scalar(fmt.Sprintf(
		`count(max_over_time(%s{%s,reason="OOMKilled"}[%s]) > 0) or vector(0)`,
		m.LastTermReason, p.podSelector(t), win))

	u.Restarts = scalar(fmt.Sprintf(
		`sum(increase(%s{%s}[%s])) or vector(0)`,
		m.Restarts, p.podSelector(t), win))

	series, coverage, err := p.series(ctx, sel, now)
	if err == nil {
		ok++
		u.Series = series
		u.Coverage = coverage
	}
	attempted++

	if ok == 0 {
		return Usage{}, fmt.Errorf("no data from %s for %s/%s (%d queries, none answered)",
			p.cfg.PromURL, t.Namespace, t.Name, attempted)
	}
	return u, nil
}

// selector matches the containers of a workload's pods, excluding the pause
// container and any sidecar-free aggregate series.
func (p *Prometheus) selector(t Target) string {
	return fmt.Sprintf(`namespace=%q,pod=~%q,container!="",container!="POD"`,
		t.Namespace, t.PodPattern)
}

// podSelector is the same match without the container filter, for
// kube-state-metrics series that are labelled per pod.
func (p *Prometheus) podSelector(t Target) string {
	return fmt.Sprintf(`namespace=%q,pod=~%q`, t.Namespace, t.PodPattern)
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
