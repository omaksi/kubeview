// Package metrics reads historical usage from Prometheus or Mimir.
//
// Nothing here stores data: the stack being managed is already a time-series
// database, so every number the rules use is a PromQL query against it. Each
// query is retained on the Usage struct so a recommendation can show its work.
package metrics

import (
	"context"
	"time"
)

// Sample is one executed query and the scalar it produced. It exists so that a
// recommendation can cite the exact expression behind a number.
type Sample struct {
	Expr  string
	Value float64
}

// Usage is the historical picture of one component over the lookback window.
type Usage struct {
	MemP99Bytes   float64
	MemMaxBytes   float64
	CPUP99Millis  float64
	ThrottleRatio float64
	OOMContainers float64
	Restarts      float64

	// Series is the memory working set over time, already resampled to the
	// configured sparkline width.
	Series []float64

	// Coverage is how much history actually came back. A 14d window over a
	// component deployed yesterday has 1d of coverage, and the engine must not
	// pretend otherwise.
	Coverage time.Duration

	Queries []Sample
}

// Target identifies the pods to query for one workload.
//
// The pod pattern is supplied by the discovery layer rather than derived here,
// because matching depends on the workload's kind — StatefulSet pods are
// `<name>-<ordinal>`, Deployment pods carry two hash segments — and the
// operator can override it outright for unusual deployments.
type Target struct {
	Namespace  string
	Name       string
	PodPattern string
}

// Provider supplies usage data for a workload. The Prometheus and demo
// implementations are interchangeable, which is what makes --demo possible
// without any branching inside the rules.
type Provider interface {
	Usage(ctx context.Context, t Target) (Usage, error)
	// Describe names the backing source, for the status bar.
	Describe() string
}
