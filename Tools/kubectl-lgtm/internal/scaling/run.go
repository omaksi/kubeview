package scaling

import (
	"context"
	"sort"
	"sync"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
	"github.com/omaksi/kubectl-lgtm/internal/metrics"
)

// Source lists the components to analyse. Both the live cluster client and the
// demo fixtures satisfy it, which is the whole of the --demo implementation.
type Source interface {
	ListComponents(ctx context.Context) ([]k8s.Component, error)
	// Describe reports the scope actually searched. It is not always the scope
	// requested — a cluster-wide list can fall back to one namespace — so
	// callers show what happened rather than what was asked for.
	Describe() string
}

// maxConcurrentQueries bounds the fan-out against Prometheus. Each component
// issues six queries, and a 40-component stack would otherwise open 240 at once.
const maxConcurrentQueries = 8

// Run is the whole analysis: list components, fetch each one's usage, apply the
// rules, sort worst first.
//
// It lives here rather than in a front end because it IS the product. The TUI
// and the --json encoder are two renderings of this one result set, and a third
// front end should not have to reimplement the fan-out to get them.
func Run(ctx context.Context, cfg config.Config, src Source, prov metrics.Provider, e *Engine) ([]Result, error) {
	comps, err := src.ListComponents(ctx)
	if err != nil {
		return nil, err
	}

	results := make([]Result, len(comps))
	sem := make(chan struct{}, maxConcurrentQueries)
	var wg sync.WaitGroup

	for i, c := range comps {
		wg.Add(1)
		go func(i int, c k8s.Component) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			usage, uerr := prov.Usage(ctx, metrics.Target{
				Namespace:  c.Namespace,
				Name:       c.Name,
				PodPattern: c.PodPattern,
			})
			res := e.Analyze(Input{Component: c, Usage: usage, Cfg: cfg})
			if uerr != nil {
				// Without usage data there is nothing to recommend, and saying
				// so beats presenting an empty row as healthy.
				res.Recs = nil
				res.Note = "metrics unavailable: " + uerr.Error()
			}
			results[i] = res
		}(i, c)
	}
	wg.Wait()

	sortWorstFirst(results)
	return results, nil
}

// RunNoMetrics is Run without the metrics half: it lists and classifies
// components the same way, but never discovers an endpoint or issues a
// query. That is what makes it fast enough to be a first paint, and safe to
// call when the metrics store is down or slow to reach.
//
// It still applies the rules that read only cluster state — see
// Engine.AnalyzeNoMetrics — because "0/3 replicas ready" comes from the API
// server, not from history, and is the single most useful thing to show
// exactly when the metrics store is unavailable.
func RunNoMetrics(ctx context.Context, cfg config.Config, src Source, e *Engine) ([]Result, error) {
	comps, err := src.ListComponents(ctx)
	if err != nil {
		return nil, err
	}

	results := make([]Result, len(comps))
	for i, c := range comps {
		results[i] = e.AnalyzeNoMetrics(c, cfg)
	}

	sortWorstFirst(results)
	return results, nil
}

// sortWorstFirst orders results by their worst finding. In the TUI the
// severity column cannot carry colour (see severityBadge), so ordering is
// what makes the rows that matter findable without reading every line.
func sortWorstFirst(results []Result) {
	sort.SliceStable(results, func(i, j int) bool {
		si, anyI := results[i].Worst()
		sj, anyJ := results[j].Worst()
		if anyI != anyJ {
			return anyI
		}
		return si > sj
	})
}
