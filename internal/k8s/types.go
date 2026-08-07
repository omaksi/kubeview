package k8s

import "fmt"

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
		return string(c.Product)
	case c.Zone != "":
		return fmt.Sprintf("%s/%s zone-%s", c.Product, c.Role, c.Zone)
	default:
		return fmt.Sprintf("%s/%s", c.Product, c.Role)
	}
}
