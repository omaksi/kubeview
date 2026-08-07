package scaling

import (
	"fmt"
	"sort"
	"strings"

	"github.com/omaksi/kubectl-lgtm/internal/format"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
)

// Engine runs the rule catalogue over one component at a time.
type Engine struct{ rules []Rule }

// New builds an engine from an explicit rule set.
func New(rules ...Rule) *Engine { return &Engine{rules: rules} }

// DefaultRules is the catalogue shipped today. Adding a rule is the intended
// way to extend this tool: implement Rule, append here, done.
func DefaultRules() []Rule {
	return []Rule{
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

	if in.Usage.Coverage > 0 && in.Usage.Coverage < in.Cfg.MinWindow {
		res.Note = fmt.Sprintf("only %s of history available, %s required — no recommendations",
			format.Duration(in.Usage.Coverage), format.Duration(in.Cfg.MinWindow))
		return res
	}

	conf := confidenceFor(in)
	for _, rule := range e.rules {
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
	if len(res.Recs) == 0 && res.Note == "" {
		res.Note = "no findings — sized within tolerance"
	}
	return res
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
