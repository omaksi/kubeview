package scaling

import (
	"fmt"

	"github.com/omaksi/kubectl-lgtm/internal/format"
)

// OOMKilled reports containers the kernel has killed for exceeding their memory
// limit. This is the one rule with no heuristic in it: the event either
// happened or it did not, so it is always Critical and always actionable.
type OOMKilled struct{}

func (OOMKilled) Name() string { return "oom-killed" }

func (r OOMKilled) Eval(in Input) []Recommendation {
	if in.Usage.OOMContainers <= 0 {
		return nil
	}

	c := in.Component.Primary()
	peak := in.Usage.MemMaxBytes
	if peak <= 0 {
		peak = in.Usage.MemP99Bytes
	}

	// The kill truncates the observed maximum — the container died at the
	// limit, so the true demand is unknown and at least the limit. Size from
	// the limit, not from what we managed to scrape.
	base := float64(c.MemLimit)
	if peak > base {
		base = peak
	}
	suggested := roundUp(base*1.5, 512*format.Mi)

	current := "no memory limit set"
	if c.MemLimit > 0 {
		current = fmt.Sprintf("limits.memory %s", format.Quantity(c.MemLimit))
	}

	return []Recommendation{{
		Severity: Critical,
		Title: fmt.Sprintf("OOMKilled — %d container(s) over the window",
			int(in.Usage.OOMContainers)),
		Current:   current,
		Suggested: fmt.Sprintf("limits.memory %s", format.Quantity(suggested)),
		Rationale: fmt.Sprintf(
			"The kernel killed %d container(s) for exceeding the memory limit, with %.0f restart(s) recorded. Observed peak usage understates real demand here, because the process died at the ceiling rather than levelling off. %s",
			int(in.Usage.OOMContainers), in.Usage.Restarts, oomImpact(in)),
		Evidence: []Evidence{
			{Expr: `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`,
				Value: fmt.Sprintf("%d container(s)", int(in.Usage.OOMContainers))},
			{Expr: "increase(kube_pod_container_status_restarts_total)",
				Value: fmt.Sprintf("%.0f", in.Usage.Restarts)},
			{Expr: "configured limits.memory", Value: format.Quantity(c.MemLimit)},
			{Expr: "max container_memory_working_set_bytes", Value: format.Bytes(in.Usage.MemMaxBytes)},
		},
		Snippet: snippet(in.Component, "raise memory limit after OOMKill",
			[]string{"resources", "limits"},
			fmt.Sprintf("memory: %s", format.Quantity(suggested))),
	}}
}

// oomImpact explains what an OOM actually costs for this kind of component.
// An OOMKilled querier retries; an OOMKilled ingester can lose unflushed data.
func oomImpact(in Input) string {
	if in.Component.Monolithic() {
		return "This is a single-binary deployment, so the kill took the whole stack down with it — ingestion, queries and compaction alike."
	}
	switch in.Component.Role {
	case "write", "backend":
		return "This target contains the ingester, so the kill risks unflushed data and forces a replay on restart."
	case "ingester":
		return "An ingester OOM risks unflushed WAL data and forces a replay on restart — treat this as urgent."
	case "store-gateway":
		return "A store-gateway OOM drops loaded blocks and degrades query latency until they are re-synced."
	case "compactor":
		return "A compactor OOM aborts in-progress compaction, leaving blocks unmerged and query performance sliding."
	default:
		return "Queries served by this component failed during each kill."
	}
}
