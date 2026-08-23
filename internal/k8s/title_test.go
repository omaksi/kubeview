package k8s_test

import (
	"context"
	"testing"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/demo"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
)

// Title collapsing every role-less component sharing a product down to the
// bare product name was a correctness bug, not a cosmetic one: against the
// live cluster it rendered "alloy" (DaemonSet, 11d of history, a CRIT
// finding), "alloy-metrics" (StatefulSet, 1.1d, no findings) and
// "alloy-singleton" (Deployment, 1.1d, no findings) all under one label,
// which is how a report reader mistook the 11-day-backed finding for a
// 1.1-day one. See CLAUDE.md / the handoff for the incident.
func TestTitleDisambiguatesRolelessSiblings(t *testing.T) {
	cases := []struct {
		name, role string
		product    k8s.Product
		want       string
	}{
		{"lgtm-distributed-grafana", "", k8s.ProductGrafana, "grafana"},
		{"alloy", "", k8s.ProductAlloy, "alloy"},
		{"alloy-metrics", "", k8s.ProductAlloy, "alloy-metrics"},
		{"alloy-singleton", "", k8s.ProductAlloy, "alloy-singleton"},
	}

	titles := map[string]bool{}
	for _, tc := range cases {
		c := k8s.Component{Name: tc.name, Product: tc.product, Role: tc.role}
		got := c.Title()
		if got != tc.want {
			t.Errorf("Component{Name: %q}.Title() = %q, want %q", tc.name, got, tc.want)
		}
		titles[got] = true
	}

	// The specific regression: siblings that only differ after the product
	// token must not collide.
	if len(titles) != len(cases) {
		t.Errorf("titles collided: %v", titles)
	}
}

// A component whose product came from a label or a configured alias (e.g.
// "promtail" classified as alloy) may not contain the product token in its
// name at all. There is nothing to slice from, so this must fall back to the
// prior behaviour rather than mis-slicing or panicking.
func TestTitleFallsBackWhenProductNotInName(t *testing.T) {
	c := k8s.Component{Name: "promtail", Product: k8s.ProductAlloy, Role: ""}
	if got, want := c.Title(), "alloy"; got != want {
		t.Errorf("Title() = %q, want %q", got, want)
	}
}

// Roled components whose role IS reflected in the name were already unique
// and must render exactly as before: unchanged product/role, zone form kept,
// and classify.go's longest-role-first match (query-frontend beats querier)
// not regressed by anything Title() does on top of it.
func TestTitleUnaffectedWhenRoleIsSet(t *testing.T) {
	cases := []struct {
		c    k8s.Component
		want string
	}{
		{k8s.Component{Name: "mimir-querier", Product: k8s.ProductMimir, Role: "querier"}, "mimir/querier"},
		{k8s.Component{Name: "lgtm-distributed-mimir-ingester", Product: k8s.ProductMimir, Role: "ingester"}, "mimir/ingester"},
		{k8s.Component{Name: "mimir-ingester-zone-a", Product: k8s.ProductMimir, Role: "ingester", Zone: "a"}, "mimir/ingester zone-a"},
		{k8s.Component{Name: "lgtm-distributed-loki-query-frontend", Product: k8s.ProductLoki, Role: "query-frontend"}, "loki/query-frontend"},
	}
	for _, tc := range cases {
		if got := tc.c.Title(); got != tc.want {
			t.Errorf("Component{Name: %q}.Title() = %q, want %q", tc.c.Name, got, tc.want)
		}
	}
}

// The real incident: mimir-distributed backs chunks-cache, index-cache,
// metadata-cache and results-cache with the same memcached subchart, so all
// four carry app.kubernetes.io/component: memcached and previously rendered
// as one indistinguishable "mimir/memcached" — two of them carrying opposite
// findings (one over its limit, one over-provisioned) read on screen as one
// component being told contradictory things.
func TestTitleDisambiguatesRoledSiblingsWithSharedLabelRole(t *testing.T) {
	cases := []struct {
		name string
		want string
	}{
		{"lgtm-distributed-mimir-chunks-cache", "mimir/chunks-cache"},
		{"lgtm-distributed-mimir-index-cache", "mimir/index-cache"},
		{"lgtm-distributed-mimir-metadata-cache", "mimir/metadata-cache"},
		{"lgtm-distributed-mimir-results-cache", "mimir/results-cache"},
	}

	titles := map[string]bool{}
	for _, tc := range cases {
		c := k8s.Component{Name: tc.name, Product: k8s.ProductMimir, Role: "memcached"}
		got := c.Title()
		if got != tc.want {
			t.Errorf("Component{Name: %q}.Title() = %q, want %q", tc.name, got, tc.want)
		}
		titles[got] = true
	}

	// The specific regression: chunks-cache vs index-cache vs metadata-cache
	// vs results-cache, all sharing role "memcached".
	if len(titles) != len(cases) {
		t.Errorf("titles collided: %v", titles)
	}
}

// A roled component whose role has nothing in the name to key off (no
// segments past the product token) has to fall back to "product/role" —
// no worse than the pre-fix behaviour, since there is genuinely nothing left
// in the name to disambiguate with.
func TestTitleFallsBackWhenNoQualifierAfterProduct(t *testing.T) {
	c := k8s.Component{Name: "mimir", Product: k8s.ProductMimir, Role: "memcached"}
	if got, want := c.Title(), "mimir/memcached"; got != want {
		t.Errorf("Title() = %q, want %q", got, want)
	}
}

// The invariant behind both title fixes, asserted directly rather than only
// against the specific names known today: within one report, no two
// components may share a title. A per-name test like the ones above would
// not have caught the memcached collision until it was already reported;
// this one trips on any future classifier or fixture change that produces a
// new collision.
func TestNoTwoComponentsShareATitle(t *testing.T) {
	for _, topology := range []string{"large", "small"} {
		cfg := config.Default()
		cfg.Demo = true
		cfg.DemoTopology = topology
		src := demo.NewSource(cfg)

		comps, err := src.ListComponents(context.Background())
		if err != nil {
			t.Fatalf("%s: list components: %v", topology, err)
		}

		seenBy := map[string]string{} // title -> first component name that used it
		for _, c := range comps {
			title := c.Title()
			if prev, ok := seenBy[title]; ok {
				t.Errorf("%s: title %q shared by %q and %q", topology, title, prev, c.Name)
				continue
			}
			seenBy[title] = c.Name
		}
	}
}
