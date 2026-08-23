package k8s_test

import (
	"regexp"
	"testing"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
)

// regexpCompileAnchored wraps a pattern the way Prometheus does: label matchers
// are fully anchored, which is what makes the kind-aware pod patterns safe.
func regexpCompileAnchored(pattern string) (*regexp.Regexp, error) {
	return regexp.Compile("^(?:" + pattern + ")$")
}

func newClassifier(t *testing.T, rules config.ClassifyRules) *k8s.Classifier {
	t.Helper()
	c, err := k8s.NewClassifier(rules)
	if err != nil {
		t.Fatalf("NewClassifier: %v", err)
	}
	return c
}

func defaultClassifier(t *testing.T) *k8s.Classifier {
	t.Helper()
	return newClassifier(t, config.Default().Classify)
}

func TestClassifyFromName(t *testing.T) {
	c := defaultClassifier(t)

	cases := []struct {
		name    string
		product k8s.Product
		role    string
		zone    string
	}{
		{"mimir-ingester-zone-a", k8s.ProductMimir, "ingester", "a"},
		{"mimir-query-frontend", k8s.ProductMimir, "query-frontend", ""},
		{"mimir-query-scheduler", k8s.ProductMimir, "query-scheduler", ""},
		{"mimir-store-gateway", k8s.ProductMimir, "store-gateway", ""},
		{"loki-querier", k8s.ProductLoki, "querier", ""},
		{"tempo-distributor", k8s.ProductTempo, "distributor", ""},
		{"grafana", k8s.ProductGrafana, "", ""},
		{"some-random-app", k8s.ProductUnknown, "", ""},

		// Collapsed deployment modes.
		{"loki-write", k8s.ProductLoki, "write", ""},
		{"loki-backend", k8s.ProductLoki, "backend", ""},
		{"loki-read", k8s.ProductLoki, "read", ""},
		{"mimir-all", k8s.ProductMimir, "all", ""},

		// A release-prefixed name still classifies.
		{"obs-mimir-compactor", k8s.ProductMimir, "compactor", ""},

		// Cortex is Mimir's former name and still appears in older charts.
		{"cortex-ingester", k8s.ProductMimir, "ingester", ""},
	}

	for _, tc := range cases {
		product, role, zone := c.Classify("monitoring", tc.name, nil)
		if product != tc.product || role != tc.role || zone != tc.zone {
			t.Errorf("Classify(%q) = (%q, %q, %q), want (%q, %q, %q)",
				tc.name, product, role, zone, tc.product, tc.role, tc.zone)
		}
	}
}

// Substring matching would classify these wrongly, and a mis-detected role
// changes both the scaling advice and the values.yaml key in the snippet.
func TestClassifyMatchesWholeSegmentsOnly(t *testing.T) {
	c := defaultClassifier(t)

	cases := []struct{ name, wantRole string }{
		{"mimir-smallish", ""},    // contains "all"
		{"loki-spreader", ""},     // contains "read"
		{"tempo-ingesterish", ""}, // contains "ingester"
		{"mimir-all", "all"},      // a real trailing segment does match
		// Where two roles both match, the longer one wins: a gateway that also
		// runs every target is more usefully described as a gateway.
		{"mimir-gateway-all", "gateway"},
	}

	for _, tc := range cases {
		if _, role, _ := c.Classify("monitoring", tc.name, nil); role != tc.wantRole {
			t.Errorf("Classify(%q) role = %q, want %q", tc.name, role, tc.wantRole)
		}
	}
}

func TestClassifyPrefersLabelsOverName(t *testing.T) {
	c := defaultClassifier(t)

	// The name says nothing useful; the labels say everything.
	product, role, _ := c.Classify("obs", "lgtm-0", map[string]string{
		"app.kubernetes.io/name":      "loki",
		"app.kubernetes.io/component": "single-binary",
	})
	if product != k8s.ProductLoki || role != "single-binary" {
		t.Errorf("got (%q, %q), want (loki, single-binary)", product, role)
	}
}

// Roles are sorted longest-first internally, so a config file may list them in
// any order without breaking query-frontend vs querier.
func TestClassifyRoleOrderIndependent(t *testing.T) {
	rules := config.Default().Classify
	rules.Roles = []string{"querier", "query-frontend", "all", "ingester"}

	c := newClassifier(t, rules)
	if _, role, _ := c.Classify("monitoring", "mimir-query-frontend", nil); role != "query-frontend" {
		t.Errorf("role = %q, want query-frontend", role)
	}
}

func TestClassifyOverrides(t *testing.T) {
	rules := config.Default().Classify
	rules.Overrides = []config.ClassifyOverride{
		{Namespace: "obs", Name: `^house-blend-.*`, Product: "mimir", Role: "ingester"},
	}
	c := newClassifier(t, rules)

	product, role, _ := c.Classify("obs", "house-blend-0", nil)
	if product != k8s.ProductMimir || role != "ingester" {
		t.Errorf("got (%q, %q), want (mimir, ingester)", product, role)
	}

	// The namespace is part of the match.
	if product, _, _ := c.Classify("other", "house-blend-0", nil); product != k8s.ProductUnknown {
		t.Errorf("override leaked into namespace %q: got product %q", "other", product)
	}
}

func TestClassifyCustomProduct(t *testing.T) {
	rules := config.Default().Classify
	rules.Products["mimir"] = []string{"mimir", "cortex", "metrics-store"}

	c := newClassifier(t, rules)
	if product, role, _ := c.Classify("obs", "metrics-store-ingester", nil); product != k8s.ProductMimir || role != "ingester" {
		t.Errorf("got (%q, %q), want (mimir, ingester)", product, role)
	}
}

func TestNewClassifierRejectsBadOverrideRegex(t *testing.T) {
	rules := config.Default().Classify
	rules.Overrides = []config.ClassifyOverride{{Name: "([unclosed"}}

	if _, err := k8s.NewClassifier(rules); err == nil {
		t.Fatal("expected an error for an invalid override regex")
	}
}

// The whole point of kind-aware matching: a workload whose name prefixes
// another must not absorb the other's pods.
func TestPodPatternDoesNotBleedAcrossWorkloads(t *testing.T) {
	cfg := config.Default()

	pattern := k8s.PodPattern(cfg, "StatefulSet", "loki-ingester")
	for _, pod := range []string{"loki-ingester-zone-a-0", "loki-ingester-zone-b-11"} {
		if matchesAnchored(t, pattern, pod) {
			t.Errorf("pattern %q wrongly matches %q", pattern, pod)
		}
	}
	for _, pod := range []string{"loki-ingester-0", "loki-ingester-12"} {
		if !matchesAnchored(t, pattern, pod) {
			t.Errorf("pattern %q fails to match %q", pattern, pod)
		}
	}
}

func TestPodPatternByKind(t *testing.T) {
	cfg := config.Default()

	cases := []struct {
		kind, name, pod string
		want            bool
	}{
		{"Deployment", "mimir-querier", "mimir-querier-7d9f8b6c4-x2k9p", true},
		{"Deployment", "mimir-querier", "mimir-querier-frontend-7d9f8-x2k9p", false},
		{"DaemonSet", "alloy", "alloy-b4kz2", true},
		{"StatefulSet", "mimir-compactor", "mimir-compactor-0", true},
	}

	for _, tc := range cases {
		pattern := k8s.PodPattern(cfg, tc.kind, tc.name)
		if got := matchesAnchored(t, pattern, tc.pod); got != tc.want {
			t.Errorf("%s %q pattern %q against %q = %v, want %v",
				tc.kind, tc.name, pattern, tc.pod, got, tc.want)
		}
	}
}

func TestPodPatternPrefixModeAndOverrides(t *testing.T) {
	cfg := config.Default()
	cfg.PodMatch = config.PodMatchPrefix

	if got := k8s.PodPattern(cfg, "StatefulSet", "loki"); got != "loki-.*" {
		t.Errorf("prefix mode gave %q, want %q", got, "loki-.*")
	}

	cfg.PodMatchOverrides = map[string]string{"loki": "custom-pod-.+"}
	if got := k8s.PodPattern(cfg, "StatefulSet", "loki"); got != "custom-pod-.+" {
		t.Errorf("override gave %q, want %q", got, "custom-pod-.+")
	}
}

// matchesAnchored mirrors PromQL, which anchors regex label matchers.
func matchesAnchored(t *testing.T, pattern, s string) bool {
	t.Helper()
	re, err := regexpCompileAnchored(pattern)
	if err != nil {
		t.Fatalf("compile %q: %v", pattern, err)
	}
	return re.MatchString(s)
}
