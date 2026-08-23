package scaling

import (
	"fmt"

	"github.com/omaksi/kubectl-lgtm/internal/format"
)

// overProvisionRatio is how far requests may exceed p99 usage before we say so.
// Observability components are bursty and stateful, so the tolerance is
// deliberately generous — a 1.5x headroom is prudent, not waste.
const overProvisionRatio = 1.5

// minWasteBytes suppresses findings too small to be worth an operator's
// attention, summed across all replicas.
const minWasteBytes = 512 * format.Mi

// MemoryOverProvisioned finds components requesting far more memory than they
// have ever needed. This is usually the largest single cost win in an LGTM
// deployment, because ingester requests get set once during a panic and never
// revisited.
type MemoryOverProvisioned struct{}

func (MemoryOverProvisioned) Name() string { return "memory-over-provisioned" }

func (r MemoryOverProvisioned) Eval(in Input) []Recommendation {
	c := in.Component.Primary()
	p99 := in.Usage.MemP99Bytes
	if c.MemRequest <= 0 || p99 <= 0 {
		return nil
	}

	ratio := float64(c.MemRequest) / p99
	if ratio < overProvisionRatio {
		return nil
	}

	// Suggest p99 plus 30% headroom, rounded to something a human would type.
	suggested := roundUp(p99*1.3, 256*format.Mi)
	if suggested >= c.MemRequest {
		return nil
	}

	replicas := int64(in.Component.Replicas)
	if replicas < 1 {
		replicas = 1
	}
	saved := (c.MemRequest - suggested) * replicas
	if saved < minWasteBytes {
		return nil
	}

	sev := Info
	if ratio >= 2.5 {
		sev = Warn
	}

	return []Recommendation{{
		Severity: sev,
		Title:    fmt.Sprintf("Memory requests %s above p99 usage", format.Ratio(ratio)),
		Current:  fmt.Sprintf("requests.memory %s × %d replicas", format.Quantity(c.MemRequest), replicas),
		Suggested: fmt.Sprintf("requests.memory %s × %d replicas (frees %s of reservation)",
			format.Quantity(suggested), replicas, format.Bytes(float64(saved))),
		Rationale: fmt.Sprintf(
			"p99 working set over the window is %s. Requests reserve capacity from the scheduler whether or not it is used, so this component is holding %s of cluster memory it never touches.",
			format.Bytes(p99), format.Bytes(float64(saved))),
		Evidence: []Evidence{
			{Expr: "p99 container_memory_working_set_bytes", Value: format.Bytes(p99)},
			{Expr: "max container_memory_working_set_bytes", Value: format.Bytes(in.Usage.MemMaxBytes)},
			{Expr: "configured requests.memory", Value: format.Quantity(c.MemRequest)},
			{Expr: "request / p99 ratio", Value: format.Ratio(ratio)},
		},
		Snippet: snippet(in.Component, "reduce memory requests",
			[]string{"resources", "requests"},
			fmt.Sprintf("memory: %s", format.Quantity(suggested))),
	}}
}

// nearLimitRatio is the p99-to-limit ratio at which a component is close enough
// to its ceiling that the next traffic spike will OOM it.
const nearLimitRatio = 0.85

// MemoryNearLimit is the counterpart to over-provisioning: a component whose
// steady-state usage is already near its ceiling. This fires before the OOM
// happens, which is the whole point.
type MemoryNearLimit struct{}

func (MemoryNearLimit) Name() string { return "memory-near-limit" }

func (r MemoryNearLimit) Eval(in Input) []Recommendation {
	c := in.Component.Primary()
	p99 := in.Usage.MemP99Bytes
	if c.MemLimit <= 0 || p99 <= 0 {
		return nil
	}

	used := p99 / float64(c.MemLimit)
	if used < nearLimitRatio {
		return nil
	}

	sev := Warn
	if used >= 0.95 {
		sev = Critical
	}

	peak := in.Usage.MemMaxBytes
	if peak < p99 {
		peak = p99
	}
	suggested := roundUp(peak*1.5, 512*format.Mi)

	return []Recommendation{{
		Severity: sev,
		Title:    fmt.Sprintf("Memory p99 at %s of limit", format.Percent(used)),
		Current:  fmt.Sprintf("limits.memory %s, p99 %s", format.Quantity(c.MemLimit), format.Bytes(p99)),
		Suggested: fmt.Sprintf("limits.memory %s, or add replicas to spread the load",
			format.Quantity(suggested)),
		Rationale: fmt.Sprintf(
			"Steady-state usage leaves only %s of headroom. %s",
			format.Bytes(float64(c.MemLimit)-p99), headroomAdvice(in)),
		Evidence: []Evidence{
			{Expr: "p99 container_memory_working_set_bytes", Value: format.Bytes(p99)},
			{Expr: "max container_memory_working_set_bytes", Value: format.Bytes(in.Usage.MemMaxBytes)},
			{Expr: "configured limits.memory", Value: format.Quantity(c.MemLimit)},
			{Expr: "p99 / limit", Value: format.Percent(used)},
		},
		Snippet: snippet(in.Component, "raise memory limit",
			[]string{"resources", "limits"},
			fmt.Sprintf("memory: %s", format.Quantity(suggested))),
	}}
}

// headroomAdvice differs by component type. Adding replicas is a safe fix for a
// stateless component, a careful operation for a stateful one, and close to
// useless for a monolithic one — a single binary scales as a unit, so more
// replicas multiply every target rather than the one under pressure.
func headroomAdvice(in Input) string {
	switch {
	case in.Component.Monolithic():
		return "This is a single-binary deployment, so replicas scale every target at once — raise the limit, or split the stack into separate targets if this keeps happening."
	case in.Component.Kind == "DaemonSet":
		return "This is a DaemonSet — replica count follows the node count, so the limit is the only lever here."
	case in.Component.Stateful():
		return "This component is stateful — prefer raising the limit over adding replicas, and use rollout-operator if you do scale it."
	default:
		return "This component is stateless, so adding replicas is the safer of the two fixes."
	}
}
