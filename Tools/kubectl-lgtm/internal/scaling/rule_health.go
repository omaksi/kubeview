package scaling

import (
	"fmt"
)

// flappingRestarts is the restart count over the window above which a
// component is treated as flapping rather than as having restarted once.
const flappingRestarts = 5

// Unhealthy reports components that are not actually running.
//
// This is the one rule that reads cluster state rather than history, and it
// exists because the first live run found a distributor sitting at 0/3 with
// 434 restarts that produced no findings at all: every other rule reasons
// about the sizing of a component that is assumed to be up. A component that
// is down outranks every sizing question about it.
type Unhealthy struct{}

func (Unhealthy) Name() string { return "unhealthy" }

// NeedsHistory is false: readiness comes from the API server, not from the
// metrics window, so a thin lookback must not suppress it. Reporting "0/3
// ready" is a fact, not an inference from sparse data.
func (Unhealthy) NeedsHistory() bool { return false }

func (r Unhealthy) Eval(in Input) []Recommendation {
	c := in.Component
	var out []Recommendation

	// Replicas == 0 is a component deliberately scaled to zero, not a fault.
	if c.Replicas > 0 && c.ReadyReplicas < c.Replicas {
		sev := Warn
		lead := fmt.Sprintf("Degraded — %d/%d replicas ready", c.ReadyReplicas, c.Replicas)
		if c.ReadyReplicas == 0 {
			sev = Critical
			lead = fmt.Sprintf("Down — 0/%d replicas ready", c.Replicas)
		}

		out = append(out, Recommendation{
			Severity: sev,
			Title:    lead,
			Current:  fmt.Sprintf("%d/%d ready, %.0f restart(s) over the window", c.ReadyReplicas, c.Replicas, in.Usage.Restarts),
			// No Suggested: there is nothing to change. Suggested is a value the
			// operator applies, and filling it with prose makes a front end render
			// a sentence where it draws "current → new value".
			Rationale: fmt.Sprintf(
				"%s Usage figures for this component are measured across whatever replicas were alive, so treat them as a lower bound: sizing advice derived from them will understate real demand. %s Diagnose before resizing.",
				readinessImpact(in), unhealthyHint(in)),
			Evidence: []Evidence{
				{Expr: "kube_state: ready / desired replicas", Value: fmt.Sprintf("%d/%d", c.ReadyReplicas, c.Replicas)},
				{Expr: "increase(kube_pod_container_status_restarts_total)", Value: fmt.Sprintf("%.0f", in.Usage.Restarts)},
			},
		})
	}

	// Flapping with no OOM to explain it. When containers did OOM, the
	// oom-killed rule already says so with a specific fix; repeating it here
	// as a vaguer finding would just add noise.
	if in.Usage.Restarts >= flappingRestarts && in.Usage.OOMContainers <= 0 && c.ReadyReplicas == c.Replicas {
		out = append(out, Recommendation{
			Severity:  Warn,
			Title:     fmt.Sprintf("Restarting repeatedly — %.0f restart(s) over the window", in.Usage.Restarts),
			Current:   fmt.Sprintf("%d/%d ready, but %.0f restart(s) recorded", c.ReadyReplicas, c.Replicas, in.Usage.Restarts),
			Rationale: "The component currently reports ready, but has restarted repeatedly over the window. No container was OOMKilled, so raising memory will not help: the cause is in the process or its configuration, not its size.",
			Evidence: []Evidence{
				{Expr: "increase(kube_pod_container_status_restarts_total)", Value: fmt.Sprintf("%.0f", in.Usage.Restarts)},
				{Expr: `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`, Value: "0 container(s)"},
			},
		})
	}

	return out
}

// readinessImpact says what being down costs for this kind of component, in
// the same voice the OOM rule uses.
func readinessImpact(in Input) string {
	if in.Component.Monolithic() {
		return "This is a single-binary deployment, so the whole stack is affected — ingestion, queries and compaction alike."
	}
	switch in.Component.Role {
	case "distributor":
		return "A distributor that is down rejects writes: data is being dropped at the front door, not merely delayed."
	case "ingester", "write":
		return "An ingester that is down risks unflushed data and forces a replay on restart."
	case "store-gateway":
		return "A store-gateway that is down makes historical blocks unqueryable, so long-range queries fail or return partial data."
	case "compactor":
		return "A compactor that is down leaves blocks unmerged, and query performance degrades the longer it stays that way."
	case "querier", "query-frontend", "query-scheduler", "read":
		return "Queries routed through this component are failing."
	case "gateway", "nginx":
		return "This is the entry point for the product, so both reads and writes through it are failing."
	default:
		return "This component is not serving."
	}
}

func unhealthyHint(in Input) string {
	if in.Usage.Restarts >= flappingRestarts {
		return "The restart count says it is crash-looping rather than merely slow to start."
	}
	return "Check whether it is crash-looping, unschedulable, or stuck waiting on a dependency."
}

// A health finding carries no Snippet on purpose. Its fix is not a config
// change, so there is no fragment to paste — and a snippet of shell commands
// only helps a front end that sits in a terminal. What to look at goes in the
// Rationale, where every front end can render it; where to look lives in the
// front end, which knows what it can navigate to.
