package scaling

import (
	"fmt"

	"github.com/omaksi/kubectl-lgtm/internal/format"
)

// throttleWarn is the share of CFS periods that may be throttled before it
// starts showing up as query latency.
const throttleWarn = 0.20

// throttleCritical is where throttling dominates the component's behaviour.
const throttleCritical = 0.40

// CPUThrottling reports components spending a meaningful share of their CFS
// periods throttled. Like OOMKills this is measured rather than inferred: the
// kernel counted the throttled periods.
type CPUThrottling struct{}

func (CPUThrottling) Name() string { return "cpu-throttling" }

func (r CPUThrottling) Eval(in Input) []Recommendation {
	ratio := in.Usage.ThrottleRatio
	if ratio < throttleWarn {
		return nil
	}

	c := in.Component.Primary()
	sev := Warn
	if ratio >= throttleCritical {
		sev = Critical
	}

	p99 := in.Usage.CPUP99Millis
	suggested := int64(p99 * 1.5)
	if r := suggested % 100; r != 0 {
		suggested += 100 - r
	}
	if suggested <= c.CPULimit {
		suggested = c.CPULimit + 500
	}

	current := "no CPU limit set"
	if c.CPULimit > 0 {
		current = fmt.Sprintf("limits.cpu %s", format.Millis(c.CPULimit))
	}

	return []Recommendation{{
		Severity:  sev,
		Title:     fmt.Sprintf("CPU throttled in %s of periods", format.Percent(ratio)),
		Current:   fmt.Sprintf("%s, p99 usage %s", current, format.MillisFloat(p99)),
		Suggested: fmt.Sprintf("limits.cpu %s, or drop the limit entirely", format.Millis(suggested)),
		Rationale: fmt.Sprintf(
			"The scheduler halted this container in %s of CFS periods, which surfaces as query latency rather than as an error. For latency-sensitive components many operators remove the CPU limit altogether and rely on requests for scheduling — throttling a %s cannot make the cluster safer, only slower.",
			format.Percent(ratio), roleLabel(in)),
		Evidence: []Evidence{
			{Expr: "increase(container_cpu_cfs_throttled_periods_total) / increase(container_cpu_cfs_periods_total)",
				Value: format.Percent(ratio)},
			{Expr: "p99 CPU usage", Value: format.MillisFloat(p99)},
			{Expr: "configured limits.cpu", Value: format.Millis(c.CPULimit)},
			{Expr: "configured requests.cpu", Value: format.Millis(c.CPURequest)},
		},
		Snippet: snippet(in.Component, "raise CPU limit to stop throttling",
			[]string{"resources", "limits"},
			fmt.Sprintf("cpu: %s", format.Millis(suggested))),
	}}
}

func roleLabel(in Input) string {
	if in.Component.Role == "" {
		return "component"
	}
	return in.Component.Role
}
