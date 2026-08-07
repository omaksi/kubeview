// Package demo provides synthetic clusters and usage history so the TUI can be
// developed and demonstrated without a running LGTM stack.
//
// Two topologies are modelled, because they are the two shapes the tool has to
// cope with:
//
//   - large — microservices mode, every role split out, spread across four
//     namespaces, zone-aware ingesters
//   - small — collapsed targets: Loki as a single binary, Mimir as `all`,
//     Tempo monolithic, plus a DaemonSet collector
//
// The fixtures are deliberately imperfect. Several components are
// over-provisioned, one is being OOMKilled, one is CPU-throttled, and one was
// deployed too recently to judge, so every rule has something to say.
package demo

import (
	"context"
	"fmt"
	"math"
	"math/rand"
	"time"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
	"github.com/omaksi/kubectl-lgtm/internal/metrics"
)

const (
	Mi = 1024 * 1024
	Gi = 1024 * Mi
)

type fixture struct {
	name      string
	namespace string
	kind      string
	labels    map[string]string
	replicas  int32
	ready     int32
	cpuReq    int64 // millicores
	cpuLim    int64
	memReq    int64 // bytes
	memLim    int64

	memP99   float64
	memMax   float64
	cpuP99   float64
	throttle float64
	ooms     float64
	restarts float64
	coverage time.Duration
}

const fullWindow = 14 * 24 * time.Hour

func lbl(name, component string) map[string]string {
	l := map[string]string{"app.kubernetes.io/name": name}
	if component != "" {
		l["app.kubernetes.io/component"] = component
	}
	return l
}

// largeFixtures model a microservices deployment split across namespaces.
var largeFixtures = []fixture{
	{"mimir-distributor", "mimir", "Deployment", lbl("mimir", "distributor"), 3, 3, 1000, 2000, 2 * Gi, 3 * Gi,
		1.1 * Gi, 1.4 * Gi, 620, 0.02, 0, 0, fullWindow},
	{"mimir-ingester-zone-a", "mimir", "StatefulSet", lbl("mimir", "ingester-zone-a"), 3, 3, 2000, 4000, 12 * Gi, 16 * Gi,
		4.8 * Gi, 5.6 * Gi, 1450, 0.01, 0, 0, fullWindow},
	{"mimir-ingester-zone-b", "mimir", "StatefulSet", lbl("mimir", "ingester-zone-b"), 3, 3, 2000, 4000, 12 * Gi, 16 * Gi,
		5.1 * Gi, 5.9 * Gi, 1520, 0.01, 0, 0, fullWindow},
	{"mimir-ingester-zone-c", "mimir", "StatefulSet", lbl("mimir", "ingester-zone-c"), 2, 2, 2000, 4000, 12 * Gi, 16 * Gi,
		5.0 * Gi, 5.7 * Gi, 1490, 0.01, 0, 0, fullWindow},
	{"mimir-querier", "mimir", "Deployment", lbl("mimir", "querier"), 6, 6, 1000, 1500, 4 * Gi, 6 * Gi,
		3.6 * Gi, 4.1 * Gi, 1380, 0.31, 0, 0, fullWindow},
	{"mimir-query-frontend", "mimir", "Deployment", lbl("mimir", "query-frontend"), 2, 2, 500, 1000, 1 * Gi, 2 * Gi,
		420 * Mi, 610 * Mi, 210, 0.04, 0, 0, fullWindow},
	{"mimir-store-gateway", "mimir", "StatefulSet", lbl("mimir", "store-gateway"), 3, 2, 1500, 3000, 8 * Gi, 8 * Gi,
		7.4 * Gi, 7.9 * Gi, 940, 0.08, 2, 7, fullWindow},
	{"mimir-compactor", "mimir", "StatefulSet", lbl("mimir", "compactor"), 1, 1, 2000, 4000, 16 * Gi, 24 * Gi,
		11.8 * Gi, 13.2 * Gi, 1900, 0.03, 0, 0, fullWindow},

	{"loki-ingester", "loki", "StatefulSet", lbl("loki", "ingester"), 3, 3, 1500, 3000, 6 * Gi, 8 * Gi,
		5.2 * Gi, 5.8 * Gi, 1120, 0.05, 0, 1, fullWindow},
	{"loki-querier", "loki", "Deployment", lbl("loki", "querier"), 4, 4, 1000, 2000, 3 * Gi, 4 * Gi,
		910 * Mi, 1.2 * Gi, 380, 0.01, 0, 0, fullWindow},
	{"loki-distributor", "loki", "Deployment", lbl("loki", "distributor"), 2, 2, 500, 1000, 1 * Gi, 2 * Gi,
		740 * Mi, 880 * Mi, 410, 0.02, 0, 0, fullWindow},

	{"tempo-distributor", "tempo", "Deployment", lbl("tempo", "distributor"), 2, 2, 500, 1000, 2 * Gi, 3 * Gi,
		690 * Mi, 820 * Mi, 260, 0.01, 0, 0, fullWindow},
	{"tempo-ingester", "tempo", "StatefulSet", lbl("tempo", "ingester"), 3, 3, 1000, 2000, 4 * Gi, 6 * Gi,
		3.1 * Gi, 3.5 * Gi, 780, 0.03, 0, 0, fullWindow},
	// Deployed three hours ago: enough data to draw, nowhere near enough to
	// judge. The engine must stay silent on this one.
	{"tempo-metrics-generator", "tempo", "Deployment", lbl("tempo", "metrics-generator"), 2, 2, 500, 1000, 2 * Gi, 4 * Gi,
		1.6 * Gi, 1.9 * Gi, 340, 0.02, 0, 0, 3 * time.Hour},

	{"grafana", "monitoring", "Deployment", lbl("grafana", ""), 2, 2, 250, 500, 1 * Gi, 1 * Gi,
		380 * Mi, 450 * Mi, 90, 0.00, 0, 0, fullWindow},
}

// smallFixtures model a collapsed deployment: one namespace, single-binary
// targets, and a DaemonSet collector.
var smallFixtures = []fixture{
	{"loki", "observability", "StatefulSet", lbl("loki", "single-binary"), 1, 1, 1000, 2000, 2 * Gi, 2 * Gi,
		1.94 * Gi, 1.99 * Gi, 640, 0.06, 1, 3, fullWindow},
	{"mimir", "observability", "StatefulSet", lbl("mimir", "all"), 1, 1, 2000, 3000, 4 * Gi, 6 * Gi,
		2.1 * Gi, 2.4 * Gi, 1180, 0.04, 0, 0, fullWindow},
	{"tempo", "observability", "StatefulSet", lbl("tempo", ""), 1, 1, 1000, 2000, 2 * Gi, 3 * Gi,
		640 * Mi, 780 * Mi, 320, 0.02, 0, 0, fullWindow},
	{"grafana", "observability", "Deployment", lbl("grafana", ""), 1, 1, 250, 500, 512 * Mi, 512 * Mi,
		300 * Mi, 360 * Mi, 80, 0.00, 0, 0, fullWindow},
	{"alloy", "observability", "DaemonSet", lbl("alloy", ""), 3, 3, 200, 400, 512 * Mi, 1 * Gi,
		470 * Mi, 520 * Mi, 380, 0.34, 0, 0, fullWindow},
}

// fixturesFor resolves the topology name. An unknown name falls back to large
// rather than erroring, because this is a development aid.
func fixturesFor(topology string) []fixture {
	if topology == "small" {
		return smallFixtures
	}
	return largeFixtures
}

// Source implements the component lister against the fixtures.
type Source struct{ cfg config.Config }

// NewSource returns a synthetic cluster.
func NewSource(cfg config.Config) *Source { return &Source{cfg: cfg} }

func (s *Source) Describe() string {
	fixtures := fixturesFor(s.cfg.DemoTopology)
	seen := map[string]bool{}
	for _, f := range fixtures {
		seen[f.namespace] = true
	}
	if len(seen) == 1 {
		return fmt.Sprintf("demo · ns/%s", fixtures[0].namespace)
	}
	return fmt.Sprintf("demo · %d namespaces", len(seen))
}

func (s *Source) ListComponents(_ context.Context) ([]k8s.Component, error) {
	clf, err := k8s.NewClassifier(s.cfg.Classify)
	if err != nil {
		return nil, err
	}

	fixtures := fixturesFor(s.cfg.DemoTopology)
	out := make([]k8s.Component, 0, len(fixtures))
	for _, f := range fixtures {
		comp := k8s.Component{
			Name:          f.name,
			Namespace:     f.namespace,
			Kind:          f.kind,
			Replicas:      f.replicas,
			ReadyReplicas: f.ready,
			PodPattern:    k8s.PodPattern(s.cfg, f.kind, f.name),
			Containers: []k8s.Container{{
				Name:       "app",
				CPURequest: f.cpuReq,
				CPULimit:   f.cpuLim,
				MemRequest: f.memReq,
				MemLimit:   f.memLim,
			}},
		}
		comp.Product, comp.Role, comp.Zone = clf.Classify(f.namespace, f.name, f.labels)
		out = append(out, comp)
	}
	return out, nil
}

// Provider implements metrics.Provider against the fixtures.
type Provider struct{ cfg config.Config }

// NewProvider returns synthetic usage history.
func NewProvider(cfg config.Config) *Provider { return &Provider{cfg: cfg} }

func (p *Provider) Describe() string {
	return fmt.Sprintf("demo · %s topology", p.topology())
}

func (p *Provider) topology() string {
	if p.cfg.DemoTopology == "small" {
		return "small"
	}
	return "large"
}

func (p *Provider) Usage(_ context.Context, t metrics.Target) (metrics.Usage, error) {
	for _, f := range fixturesFor(p.cfg.DemoTopology) {
		if f.name != t.Name || (t.Namespace != "" && f.namespace != t.Namespace) {
			continue
		}
		return metrics.Usage{
			MemP99Bytes:   f.memP99,
			MemMaxBytes:   f.memMax,
			CPUP99Millis:  f.cpuP99,
			ThrottleRatio: f.throttle,
			OOMContainers: f.ooms,
			Restarts:      f.restarts,
			Series:        synthSeries(t.Name, f.memP99, p.cfg.SparkPoints),
			Coverage:      f.coverage,
			Queries: []metrics.Sample{
				{Expr: "demo: memory working set p99", Value: f.memP99},
				{Expr: "demo: cpu p99 (millicores)", Value: f.cpuP99},
				{Expr: "demo: cfs throttle ratio", Value: f.throttle},
				{Expr: "demo: OOMKilled containers", Value: f.ooms},
			},
		}, nil
	}
	return metrics.Usage{}, fmt.Errorf("no demo fixture for %s/%s", t.Namespace, t.Name)
}

// synthSeries builds a plausible memory curve: a slow ramp with a daily cycle
// and a little noise, seeded from the workload name so it is stable across
// refreshes.
func synthSeries(seed string, peak float64, points int) []float64 {
	if points < 2 {
		points = 24
	}
	var h int64
	for _, r := range seed {
		h = h*31 + int64(r)
	}
	rng := rand.New(rand.NewSource(h))

	out := make([]float64, points)
	for i := range out {
		frac := float64(i) / float64(points-1)
		ramp := 0.72 + 0.28*frac
		daily := 1 + 0.08*math.Sin(frac*4*math.Pi)
		noise := 1 + (rng.Float64()-0.5)*0.06
		out[i] = peak * ramp * daily * noise
	}
	return out
}
