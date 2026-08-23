package k8s

import (
	"fmt"
	"strings"
)

// Product identifies which part of the stack a workload belongs to. It is a
// plain string rather than a closed enum because the set is configurable —
// a vendored or renamed distribution should classify without a code change.
type Product string

const (
	ProductMimir   Product = "mimir"
	ProductLoki    Product = "loki"
	ProductTempo   Product = "tempo"
	ProductGrafana Product = "grafana"
	ProductPyro    Product = "pyroscope"
	ProductAlloy   Product = "alloy"
	ProductUnknown Product = ""
)

// Component is a single scalable unit of the stack: one Deployment, StatefulSet
// or DaemonSet, flattened to the fields the rules actually reason about.
type Component struct {
	Name      string
	Namespace string
	Kind      string // Deployment | StatefulSet | DaemonSet
	Product   Product
	// Role is the stack-level role: ingester, querier, distributor, compactor…
	// or a collapsed target like all, single-binary, read, write, backend.
	Role string

	Replicas      int32
	ReadyReplicas int32

	// Zone is set for zone-aware deployments (ingester-zone-a → "a").
	Zone string

	// PodPattern is the regex that matches this workload's pods in PromQL.
	// It is computed at discovery time because it depends on the kind.
	PodPattern string

	Containers []Container
}

// Container carries the resource envelope of one container in the pod spec.
// CPU is in millicores, memory in bytes. Zero means "unset", which is itself a
// finding worth reporting.
type Container struct {
	Name       string
	CPURequest int64
	CPULimit   int64
	MemRequest int64
	MemLimit   int64
}

// statefulRoles hold data that must be flushed or handed off before a replica
// goes away. They must never be scaled by a naive HPA.
//
// The collapsed targets are here too: a Loki `write` or `backend` pod, or any
// `all`/`single-binary` process, contains an ingester whatever else it also is.
var statefulRoles = map[string]bool{
	"ingester":      true,
	"store-gateway": true,
	"compactor":     true,
	"index-gateway": true,
	"alertmanager":  true,
	"ruler":         true,
	"write":         true,
	"backend":       true,
	"single-binary": true,
	"all":           true,
}

// monolithicRoles run every target in one process, so scaling them scales
// everything — including the parts that did not need it.
var monolithicRoles = map[string]bool{
	"all":           true,
	"single-binary": true,
}

// Stateful reports whether scaling this component down requires care.
func (c Component) Stateful() bool {
	if statefulRoles[c.Role] {
		return true
	}
	// An unclassified StatefulSet is assumed stateful. Guessing the safe way
	// costs a cautious sentence of advice; guessing the other way costs data.
	return c.Role == "" && c.Kind == "StatefulSet"
}

// Monolithic reports whether this component is a single-binary deployment.
func (c Component) Monolithic() bool { return monolithicRoles[c.Role] }

// Primary returns the container the rules should judge the workload by,
// skipping sidecars where possible.
func (c Component) Primary() Container {
	if len(c.Containers) == 0 {
		return Container{}
	}
	for _, ct := range c.Containers {
		if ct.Name == string(c.Product) || ct.Name == c.Role || ct.Name == c.Name {
			return ct
		}
	}
	return c.Containers[0]
}

// Title is the display name used in the detail pane.
func (c Component) Title() string {
	switch {
	case c.Product == ProductUnknown && c.Role == "":
		return c.Name
	case c.Role == "":
		return titleFromName(c.Name, c.Product)
	case c.Zone != "":
		// Zone form is already unique (product/role zone-X) and is left alone
		// unconditionally, regardless of whether role literally appears in
		// the name — this branch is validated against real zone-aware
		// ingesters and must not change shape.
		return fmt.Sprintf("%s/%s zone-%s", c.Product, c.Role, c.Zone)
	case !roleInName(c.Name, c.Role):
		// The role came from a label the name does not reflect. On the live
		// cluster, mimir-distributed backs chunks-cache, index-cache,
		// metadata-cache and results-cache with the same memcached subchart,
		// so all four carry app.kubernetes.io/component: memcached — same
		// product, identical label-derived role, and "mimir/memcached"
		// collapsed all four onto one title even though two of them carried
		// opposite findings (one over its limit, one over-provisioned) that
		// then read as one component being told contradictory things. The
		// name is the only thing left that still distinguishes them here, so
		// use its own qualifier instead of the role — same principle as the
		// roleless case, just keeping the role slot's position in the title.
		return roledTitleFromName(c.Name, c.Product, c.Role)
	default:
		return fmt.Sprintf("%s/%s", c.Product, c.Role)
	}
}

// roledTitleFromName substitutes the segments of name that follow the
// product token for the role, producing e.g. "mimir/chunks-cache" instead of
// "mimir/memcached". Falls back to "product/role" — no worse than before —
// when the name has nothing past the product token to offer instead.
func roledTitleFromName(name string, product Product, role string) string {
	if tail := segmentsAfterProduct(name, product); len(tail) > 0 {
		return fmt.Sprintf("%s/%s", product, strings.Join(tail, "-"))
	}
	return fmt.Sprintf("%s/%s", product, role)
}

// roleInName reports whether role appears as a contiguous run of whole
// dash-separated segments in name — the same matching classify.go uses so a
// substring hit cannot land inside an unrelated word (see containsSegments).
func roleInName(name, role string) bool {
	if role == "" {
		return false
	}
	return containsSegments(strings.Split(name, "-"), strings.Split(role, "-"))
}

// segmentsAfterProduct returns name's dash-separated segments strictly after
// the product token, matched as a whole segment, or nil when the product does
// not appear in name at all — it came from a label, or from a configured
// alias like "promtail" that maps to alloy without ever containing the word.
func segmentsAfterProduct(name string, product Product) []string {
	segs := strings.Split(name, "-")
	for i, s := range segs {
		if strings.EqualFold(s, string(product)) {
			return segs[i+1:]
		}
	}
	return nil
}

// titleFromName returns the name from the product token onward, rather than
// the bare product, for a component with no role. A role-less component is
// not necessarily unique per product: "alloy", "alloy-metrics" and
// "alloy-singleton" all classify as product alloy with no role, and
// collapsing them to one title ("alloy") made a CRIT finding on the DaemonSet
// indistinguishable from an unrelated, healthy Deployment sharing the label —
// a real misread, not a cosmetic one.
//
// The match is a whole dash-separated segment, never a substring, for the
// same reason classify.go's containsSegments is: a substring hit can land
// inside an unrelated word. If the product does not appear in the name at
// all — it came from a label, or from a configured alias like "promtail"
// that maps to alloy without ever containing the word — there is nothing to
// slice from, so this falls back to the bare product, matching prior
// behaviour.
func titleFromName(name string, product Product) string {
	segs := strings.Split(name, "-")
	for i, s := range segs {
		if strings.EqualFold(s, string(product)) {
			return strings.Join(segs[i:], "-")
		}
	}
	return string(product)
}
