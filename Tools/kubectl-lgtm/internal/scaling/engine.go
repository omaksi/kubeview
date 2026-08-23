package scaling

import (
	"fmt"
	"sort"
	"strings"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/format"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
	"github.com/omaksi/kubectl-lgtm/internal/metrics"
)

// Engine runs the rule catalogue over one component at a time.
type Engine struct{ rules []Rule }

// New builds an engine from an explicit rule set.
func New(rules ...Rule) *Engine { return &Engine{rules: rules} }

// DefaultRules is the catalogue shipped today. Adding a rule is the intended
// way to extend this tool: implement Rule, append here, done.
func DefaultRules() []Rule {
	return []Rule{
		// Health first: a component that is not running makes every sizing
		// finding about it provisional.
		Unhealthy{},
		OOMKilled{},
		MemoryNearLimit{},
		CPUThrottling{},
		MemoryOverProvisioned{},
	}
}

// Default returns an engine with the default catalogue.
func Default() *Engine { return New(DefaultRules()...) }

// Analyze evaluates every rule against one component.
//
// It refuses to emit anything when the lookback is too thin. A recommendation
// derived from thirty minutes of data is worse than silence: it teaches the
// operator to distrust the tool.
func (e *Engine) Analyze(in Input) Result {
	res := Result{Component: in.Component, Usage: in.Usage}

	// Thin history silences everything that reasons about the window, but not
	// what is read straight from the API server. "0/3 replicas ready" is a
	// fact; suppressing it because metrics are sparse hides the very thing an
	// operator opened the tool to see.
	thin := in.Usage.Coverage > 0 && in.Usage.Coverage < in.Cfg.MinWindow

	conf := confidenceFor(in)
	for _, rule := range e.rules {
		if thin && needsHistory(rule) {
			continue
		}
		for _, rec := range rule.Eval(in) {
			rec.Rule = rule.Name()
			rec.Component = in.Component.Name
			rec.Window = in.Usage.Coverage
			if rec.Window == 0 {
				rec.Window = in.Cfg.Window
			}
			rec.Confidence = conf
			res.Recs = append(res.Recs, rec)
		}
	}

	sort.SliceStable(res.Recs, func(i, j int) bool {
		return res.Recs[i].Severity > res.Recs[j].Severity
	})

	switch {
	case thin && len(res.Recs) == 0:
		res.Note = fmt.Sprintf("only %s of history available, %s required — no recommendations",
			format.Duration(in.Usage.Coverage), format.Duration(in.Cfg.MinWindow))
	case thin:
		res.Note = fmt.Sprintf("only %s of history available, %s required — showing only findings that do not depend on it",
			format.Duration(in.Usage.Coverage), format.Duration(in.Cfg.MinWindow))
	case len(res.Recs) == 0:
		res.Note = "no findings — sized within tolerance"
	}
	return res
}

// AnalyzeNoMetrics evaluates a component with no usage data at all — for
// --no-metrics, which skips endpoint discovery and every PromQL query rather
// than letting one fail.
//
// It filters by NeedsHistory() explicitly instead of routing a zero Usage
// through Analyze. That shortcut looks tempting — a zero-value Usage has
// Coverage == 0, and every rule already guards its own inputs with
// `if x <= 0 { return nil }` — but Analyze's thin-data gate is
// `Coverage > 0 && Coverage < MinWindow`, which a zero Coverage fails,
// leaving thin == false and every rule evaluated. Suppression would then
// depend on each rule's guard holding forever, which is an implementation
// detail of the rule, not a promise of this API. Filtering by NeedsHistory()
// here makes "no metrics were queried" a decision this function owns.
func (e *Engine) AnalyzeNoMetrics(c k8s.Component, cfg config.Config) Result {
	in := Input{Component: c, Usage: metrics.Usage{}, Cfg: cfg}
	res := Result{Component: c, Usage: in.Usage}

	for _, rule := range e.rules {
		if needsHistory(rule) {
			continue
		}
		for _, rec := range rule.Eval(in) {
			rec.Rule = rule.Name()
			rec.Component = c.Name
			rec.Window = cfg.Window
			rec.Confidence = Low
			res.Recs = append(res.Recs, rec)
		}
	}

	sort.SliceStable(res.Recs, func(i, j int) bool {
		return res.Recs[i].Severity > res.Recs[j].Severity
	})

	if len(res.Recs) == 0 {
		res.Note = "metrics not queried — no findings from cluster state alone"
	} else {
		res.Note = "metrics not queried — showing only findings that do not depend on usage history"
	}
	return res
}

// needsHistory reports whether a rule's output depends on the metrics window.
//
// Rules opt out by implementing NeedsHistory() bool; the default is true, so
// an existing rule keeps being gated unless it says otherwise.
func needsHistory(r Rule) bool {
	if h, ok := r.(interface{ NeedsHistory() bool }); ok {
		return h.NeedsHistory()
	}
	return true
}

// confidenceFor derives confidence from how much of the requested window
// actually returned data.
func confidenceFor(in Input) Confidence {
	if in.Cfg.Window <= 0 || in.Usage.Coverage <= 0 {
		return Low
	}
	switch ratio := float64(in.Usage.Coverage) / float64(in.Cfg.Window); {
	case ratio >= 0.9:
		return High
	case ratio >= 0.5:
		return Medium
	default:
		return Low
	}
}

// roundUp rounds a byte count up to the nearest multiple of unit, so suggested
// values are quantities a human would have typed.
func roundUp(v float64, unit int64) int64 {
	if v <= 0 {
		return 0
	}
	n := int64(v)
	if r := n % unit; r != 0 {
		n += unit - r
	}
	return n
}

// chartKey maps a component role to the key used in that product's Helm values.
//
// The charts disagree with each other — mimir-distributed uses snake_case, loki
// and tempo use camelCase — and a collapsed deployment has no per-role key at
// all. The snippet therefore always carries a comment telling the operator to
// check the path; this is a good guess, not a guarantee.
func chartKey(product k8s.Product, role string) string {
	// A monolithic target has no per-component section: the resources live
	// under the product's own key.
	if role == "" || role == "all" {
		if product == k8s.ProductUnknown {
			return "<component>"
		}
		return string(product)
	}

	switch product {
	case k8s.ProductMimir:
		return strings.ReplaceAll(role, "-", "_")
	default:
		return camel(role)
	}
}

func camel(role string) string {
	parts := strings.Split(role, "-")
	for i := 1; i < len(parts); i++ {
		if parts[i] == "" {
			continue
		}
		parts[i] = strings.ToUpper(parts[i][:1]) + parts[i][1:]
	}
	return strings.Join(parts, "")
}

// snippet renders a values.yaml fragment for a nested path.
func snippet(c k8s.Component, note string, path []string, value string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s — %s\n", c.Name, note)
	b.WriteString("# verify the key path against your chart version before applying\n")
	b.WriteString(chartKey(c.Product, c.Role))
	b.WriteString(":\n")
	for i, seg := range path {
		fmt.Fprintf(&b, "%s%s:\n", strings.Repeat("  ", i+1), seg)
	}
	fmt.Fprintf(&b, "%s%s\n", strings.Repeat("  ", len(path)+1), value)
	return b.String()
}
