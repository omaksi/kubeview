package scaling_test

import (
	"context"
	"strings"
	"testing"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/demo"
	"github.com/omaksi/kubectl-lgtm/internal/metrics"
	"github.com/omaksi/kubectl-lgtm/internal/scaling"
)

// analyzeTopology runs the full engine over a demo topology and indexes the
// results by component name.
func analyzeTopology(t *testing.T, topology string) map[string]scaling.Result {
	t.Helper()

	cfg := config.Default()
	cfg.Demo = true
	cfg.DemoTopology = topology
	src := demo.NewSource(cfg)
	prov := demo.NewProvider(cfg)
	engine := scaling.Default()

	comps, err := src.ListComponents(context.Background())
	if err != nil {
		t.Fatalf("list components: %v", err)
	}

	out := make(map[string]scaling.Result, len(comps))
	for _, c := range comps {
		usage, err := prov.Usage(context.Background(), metrics.Target{
			Namespace:  c.Namespace,
			Name:       c.Name,
			PodPattern: c.PodPattern,
		})
		if err != nil {
			t.Fatalf("usage for %s: %v", c.Name, err)
		}
		out[c.Name] = engine.Analyze(scaling.Input{Component: c, Usage: usage, Cfg: cfg})
	}
	return out
}

func analyzeDemo(t *testing.T) map[string]scaling.Result {
	t.Helper()
	return analyzeTopology(t, "large")
}

func rulesFired(res scaling.Result) []string {
	var names []string
	for _, rec := range res.Recs {
		names = append(names, rec.Rule)
	}
	return names
}

func findRule(res scaling.Result, rule string) (scaling.Recommendation, bool) {
	for _, rec := range res.Recs {
		if rec.Rule == rule {
			return rec, true
		}
	}
	return scaling.Recommendation{}, false
}

func TestRulesFireOnExpectedComponents(t *testing.T) {
	results := analyzeDemo(t)

	cases := []struct {
		component string
		rule      string
		severity  scaling.Severity
	}{
		{"mimir-store-gateway", "oom-killed", scaling.Critical},
		{"mimir-store-gateway", "memory-near-limit", scaling.Warn}, // 7.4Gi of an 8Gi limit
		{"mimir-querier", "cpu-throttling", scaling.Warn},
		{"mimir-ingester-zone-a", "memory-over-provisioned", scaling.Warn},
		{"loki-querier", "memory-over-provisioned", scaling.Warn},
		{"mimir-distributor", "memory-over-provisioned", scaling.Info}, // 1.8x — worth noting, not warning
	}

	for _, tc := range cases {
		res, ok := results[tc.component]
		if !ok {
			t.Fatalf("no result for %s", tc.component)
		}
		rec, ok := findRule(res, tc.rule)
		if !ok {
			t.Errorf("%s: expected rule %q, got %v", tc.component, tc.rule, rulesFired(res))
			continue
		}
		if rec.Severity != tc.severity {
			t.Errorf("%s/%s: severity = %v, want %v",
				tc.component, tc.rule, rec.Severity, tc.severity)
		}
	}
}

// A component with almost no history must produce no recommendations at all.
// Guessing from thin data is the failure mode that makes operators stop reading
// the tool, so it is worth a test of its own.
func TestInsufficientHistoryProducesNoRecommendations(t *testing.T) {
	results := analyzeDemo(t)

	res, ok := results["tempo-metrics-generator"]
	if !ok {
		t.Fatal("no result for tempo-metrics-generator")
	}
	if len(res.Recs) != 0 {
		t.Errorf("expected no recommendations on 3h of history, got %v", rulesFired(res))
	}
	if !strings.Contains(res.Note, "history") {
		t.Errorf("expected a note explaining the silence, got %q", res.Note)
	}
}

func TestHealthyComponentIsSilent(t *testing.T) {
	results := analyzeDemo(t)

	// tempo-ingester sits at 3.1Gi against a 4Gi request and a 6Gi limit:
	// comfortably sized, nothing to say.
	res := results["tempo-ingester"]
	if len(res.Recs) != 0 {
		t.Errorf("expected tempo-ingester to be silent, got %v", rulesFired(res))
	}
}

func TestEveryRecommendationCarriesEvidenceAndSnippet(t *testing.T) {
	for name, res := range analyzeDemo(t) {
		for _, rec := range res.Recs {
			if len(rec.Evidence) == 0 {
				t.Errorf("%s/%s: recommendation without evidence", name, rec.Rule)
			}
			if strings.TrimSpace(rec.Snippet) == "" {
				t.Errorf("%s/%s: recommendation without a values snippet", name, rec.Rule)
			}
			if rec.Window == 0 {
				t.Errorf("%s/%s: recommendation without a window", name, rec.Rule)
			}
		}
	}
}

// Severity ordering drives what the operator reads first, so the sort matters.
func TestRecommendationsSortedBySeverity(t *testing.T) {
	res := analyzeDemo(t)["mimir-store-gateway"]
	if len(res.Recs) < 2 {
		t.Fatalf("expected several findings on store-gateway, got %d", len(res.Recs))
	}
	for i := 1; i < len(res.Recs); i++ {
		if res.Recs[i-1].Severity < res.Recs[i].Severity {
			t.Errorf("recommendations out of order at %d: %v then %v",
				i, res.Recs[i-1].Severity, res.Recs[i].Severity)
		}
	}
}

// A collapsed deployment must produce recommendations too, with advice that
// reflects the topology rather than microservices advice pasted onto it.
func TestSmallTopologyIsAnalysed(t *testing.T) {
	results := analyzeTopology(t, "small")

	if len(results) == 0 {
		t.Fatal("small topology produced no results")
	}

	loki, ok := results["loki"]
	if !ok {
		t.Fatal("no result for the loki single binary")
	}
	if !loki.Component.Monolithic() {
		t.Errorf("loki single-binary not detected as monolithic, role = %q", loki.Component.Role)
	}

	rec, ok := findRule(loki, "oom-killed")
	if !ok {
		t.Fatalf("expected an OOM finding on the loki single binary, got %v", rulesFired(loki))
	}
	if !strings.Contains(rec.Rationale, "single-binary") {
		t.Errorf("expected single-binary-aware rationale, got %q", rec.Rationale)
	}

	// The DaemonSet collector is throttled, and its advice must not suggest
	// adding replicas.
	alloy, ok := results["alloy"]
	if !ok {
		t.Fatal("no result for the alloy DaemonSet")
	}
	if !hasRule(alloy, "cpu-throttling") {
		t.Errorf("expected cpu-throttling on alloy, got %v", rulesFired(alloy))
	}
}

// Collapsed deployments key their values differently from microservices ones:
// the Loki chart has a real `singleBinary:` section, while a Mimir `all` target
// has no per-component section at all and keys off the product.
func TestCollapsedSnippetKeys(t *testing.T) {
	results := analyzeTopology(t, "small")

	rec, ok := findRule(results["loki"], "oom-killed")
	if !ok {
		t.Fatalf("no oom-killed finding on loki, got %v", rulesFired(results["loki"]))
	}
	if !strings.Contains(rec.Snippet, "\nsingleBinary:\n") {
		t.Errorf("expected the snippet to key off `singleBinary:`, got:\n%s", rec.Snippet)
	}

	rec, ok = findRule(results["mimir"], "memory-over-provisioned")
	if !ok {
		t.Fatalf("no over-provisioning finding on the mimir all-target, got %v",
			rulesFired(results["mimir"]))
	}
	if !strings.Contains(rec.Snippet, "\nmimir:\n") {
		t.Errorf("expected the snippet to key off `mimir:`, got:\n%s", rec.Snippet)
	}
}

func hasRule(res scaling.Result, rule string) bool {
	_, ok := findRule(res, rule)
	return ok
}
