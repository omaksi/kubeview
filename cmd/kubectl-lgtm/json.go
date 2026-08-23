package main

import (
	"encoding/json"
	"io"
	"time"

	"github.com/omaksi/kubectl-lgtm/internal/metrics"
	"github.com/omaksi/kubectl-lgtm/internal/scaling"
)

// The wire format is declared here rather than by tagging the core structs.
//
// A front end that is not this binary — the macOS app, a CI job, a dashboard —
// is a consumer of a contract, and a contract should be something someone chose.
// Struct tags on internal types make it accidental instead: renaming a field for
// clarity silently breaks every consumer, and there is no single place to read
// what is actually published. Everything below is additive-only.
type jsonReport struct {
	Version     string    `json:"version"`
	GeneratedAt time.Time `json:"generatedAt"`
	Context     string    `json:"context"`
	Scope       string    `json:"scope"`
	Source      string    `json:"source"`
	// Warning is a caveat about the metrics store, empty when there is none.
	// The one that matters today: a Mimir holding several clusters means every
	// aggregation silently spans them, and a max across four clusters looks
	// exactly like a legitimate number.
	Warning    string  `json:"warning,omitempty"`
	WindowSecs float64 `json:"windowSecs"`
	// MetricsAvailable is false for --no-metrics: every component below is
	// still real, classified from the Kubernetes API, but Usage is zeroed and
	// any findings come only from rules that read cluster state rather than
	// history.
	MetricsAvailable bool            `json:"metricsAvailable"`
	Components       []jsonComponent `json:"components"`
}

type jsonComponent struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Kind      string `json:"kind"`
	Product   string `json:"product"`
	Role      string `json:"role"`
	Zone      string `json:"zone"`
	Title     string `json:"title"`
	// PodPattern is the regex matching this workload's pods. It is the join
	// key a front end uses to match a component to the live pods it already
	// holds from its own watch, without reimplementing kind-aware pod naming.
	PodPattern string `json:"podPattern"`

	Replicas      int32 `json:"replicas"`
	ReadyReplicas int32 `json:"readyReplicas"`
	Stateful      bool  `json:"stateful"`

	CPURequestMillis int64 `json:"cpuRequestMillis"`
	CPULimitMillis   int64 `json:"cpuLimitMillis"`
	MemRequestBytes  int64 `json:"memRequestBytes"`
	MemLimitBytes    int64 `json:"memLimitBytes"`

	Usage jsonUsage `json:"usage"`
	Note  string    `json:"note"`
	// Severity is the worst finding on this component, or "" when there are
	// none. Precomputed so a consumer can sort and colour without reimplementing
	// the ranking.
	Severity string    `json:"severity"`
	Findings []jsonRec `json:"findings"`
}

type jsonUsage struct {
	MemP99Bytes   float64   `json:"memP99Bytes"`
	MemMaxBytes   float64   `json:"memMaxBytes"`
	CPUP99Millis  float64   `json:"cpuP99Millis"`
	ThrottleRatio float64   `json:"throttleRatio"`
	OOMContainers float64   `json:"oomContainers"`
	Restarts      float64   `json:"restarts"`
	CoverageSecs  float64   `json:"coverageSecs"`
	Series        []float64 `json:"series"`

	// Pods carries each replica measured on its own. The scalars above are the
	// max across these, kept because sizing a limit needs the busiest replica -
	// but the collapse is a judgement, and a consumer showing what the cluster
	// is actually doing should read these instead.
	Pods []jsonPodUsage `json:"pods"`
}

type jsonPodUsage struct {
	Name          string  `json:"name"`
	MemP99Bytes   float64 `json:"memP99Bytes"`
	MemMaxBytes   float64 `json:"memMaxBytes"`
	CPUP99Millis  float64 `json:"cpuP99Millis"`
	ThrottleRatio float64 `json:"throttleRatio"`
	OOMContainers float64 `json:"oomContainers"`
	Restarts      float64 `json:"restarts"`
}

type jsonRec struct {
	Rule       string         `json:"rule"`
	Severity   string         `json:"severity"`
	Title      string         `json:"title"`
	Current    string         `json:"current"`
	Suggested  string         `json:"suggested"`
	Rationale  string         `json:"rationale"`
	Confidence string         `json:"confidence"`
	WindowSecs float64        `json:"windowSecs"`
	Snippet    string         `json:"snippet"`
	GrafanaURL string         `json:"grafanaUrl,omitempty"`
	Evidence   []jsonEvidence `json:"evidence"`
}

type jsonEvidence struct {
	Expr  string `json:"expr"`
	Value string `json:"value"`
}

// writeJSON renders the analysis as one JSON object on stdout.
func writeJSON(w io.Writer, rep jsonReport) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(rep)
}

func toJSON(results []scaling.Result) []jsonComponent {
	out := make([]jsonComponent, 0, len(results))
	for _, r := range results {
		c := r.Component
		p := c.Primary()

		jc := jsonComponent{
			Name:      c.Name,
			Namespace: c.Namespace,
			Kind:      c.Kind,
			Product:   string(c.Product),
			Role:      c.Role,
			Zone:      c.Zone,
			Title:     c.Title(),

			PodPattern: c.PodPattern,

			Replicas:      c.Replicas,
			ReadyReplicas: c.ReadyReplicas,
			Stateful:      c.Stateful(),

			CPURequestMillis: p.CPURequest,
			CPULimitMillis:   p.CPULimit,
			MemRequestBytes:  p.MemRequest,
			MemLimitBytes:    p.MemLimit,

			Usage: jsonUsage{
				MemP99Bytes:   r.Usage.MemP99Bytes,
				MemMaxBytes:   r.Usage.MemMaxBytes,
				CPUP99Millis:  r.Usage.CPUP99Millis,
				ThrottleRatio: r.Usage.ThrottleRatio,
				OOMContainers: r.Usage.OOMContainers,
				Restarts:      r.Usage.Restarts,
				CoverageSecs:  r.Usage.Coverage.Seconds(),
				Series:        nonNil(r.Usage.Series),
				Pods:          podsToJSON(r.Usage.Pods),
			},
			Note:     r.Note,
			Findings: recsToJSON(r.Recs),
		}
		if worst, any := r.Worst(); any {
			jc.Severity = worst.String()
		}
		out = append(out, jc)
	}
	return out
}

func recsToJSON(recs []scaling.Recommendation) []jsonRec {
	out := make([]jsonRec, 0, len(recs))
	for _, rec := range recs {
		ev := make([]jsonEvidence, 0, len(rec.Evidence))
		for _, e := range rec.Evidence {
			ev = append(ev, jsonEvidence{Expr: e.Expr, Value: e.Value})
		}
		out = append(out, jsonRec{
			Rule:       rec.Rule,
			Severity:   rec.Severity.String(),
			Title:      rec.Title,
			Current:    rec.Current,
			Suggested:  rec.Suggested,
			Rationale:  rec.Rationale,
			Confidence: rec.Confidence.String(),
			WindowSecs: rec.Window.Seconds(),
			Snippet:    rec.Snippet,
			GrafanaURL: rec.GrafanaURL,
			Evidence:   ev,
		})
	}
	return out
}

// nonNil keeps empty slices out of the wire format as [] rather than null, so a
// consumer never has to special-case the difference.
func nonNil(s []float64) []float64 {
	if s == nil {
		return []float64{}
	}
	return s
}

func podsToJSON(pods []metrics.PodUsage) []jsonPodUsage {
	out := make([]jsonPodUsage, 0, len(pods))
	for _, p := range pods {
		out = append(out, jsonPodUsage{
			Name:          p.Pod,
			MemP99Bytes:   p.MemP99Bytes,
			MemMaxBytes:   p.MemMaxBytes,
			CPUP99Millis:  p.CPUP99Millis,
			ThrottleRatio: p.ThrottleRatio,
			OOMContainers: p.OOMContainers,
			Restarts:      p.Restarts,
		})
	}
	return out
}
