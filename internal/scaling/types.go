package scaling

import (
	"time"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
	"github.com/omaksi/kubectl-lgtm/internal/metrics"
)

// Severity ranks how urgently a recommendation deserves attention.
type Severity int

const (
	Info Severity = iota
	Warn
	Critical
)

func (s Severity) String() string {
	switch s {
	case Critical:
		return "CRIT"
	case Warn:
		return "WARN"
	default:
		return "INFO"
	}
}

// Confidence reflects how much history backs a recommendation. It is derived
// from data coverage, never asserted by a rule.
type Confidence int

const (
	Low Confidence = iota
	Medium
	High
)

func (c Confidence) String() string {
	switch c {
	case High:
		return "high"
	case Medium:
		return "medium"
	default:
		return "low"
	}
}

// Evidence is one query and its result. A recommendation without evidence gets
// ignored; the same recommendation with the expression, the number and the
// window gets acted on — and stays debuggable when it is wrong.
type Evidence struct {
	Expr  string
	Value string
}

// Recommendation is the unit of output. Everything the operator needs to judge
// and apply the change is on this struct.
type Recommendation struct {
	Rule      string
	Component string
	Severity  Severity

	Title     string
	Current   string
	Suggested string
	Rationale string

	Evidence   []Evidence
	Window     time.Duration
	Confidence Confidence

	// Snippet is a ready-to-paste values.yaml fragment.
	Snippet string
	// GrafanaURL opens the panel backing this finding, when configured.
	GrafanaURL string
}

// Input is everything a rule may look at.
type Input struct {
	Component k8s.Component
	Usage     metrics.Usage
	Cfg       config.Config
}

// Result pairs a component with its analysis.
type Result struct {
	Component k8s.Component
	Usage     metrics.Usage
	Recs      []Recommendation
	// Note explains why there are no recommendations, when that needs saying.
	Note string
}

// Worst returns the highest severity present, and false if there are none.
func (r Result) Worst() (Severity, bool) {
	if len(r.Recs) == 0 {
		return Info, false
	}
	worst := r.Recs[0].Severity
	for _, rec := range r.Recs[1:] {
		if rec.Severity > worst {
			worst = rec.Severity
		}
	}
	return worst, true
}

// Rule derives recommendations from one component's data.
type Rule interface {
	Name() string
	Eval(Input) []Recommendation
}
