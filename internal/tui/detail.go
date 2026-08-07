package tui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/format"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
	"github.com/omaksi/kubectl-lgtm/internal/scaling"
)

// renderDetail builds the lower pane: the facts about a component, then every
// recommendation with the evidence behind it.
func renderDetail(res scaling.Result, cfg config.Config, width int) string {
	if width < 30 {
		width = 30
	}
	wrap := lipgloss.NewStyle().Width(width)
	indent := lipgloss.NewStyle().Width(width).PaddingLeft(4)

	var b strings.Builder
	c := res.Component
	u := res.Usage

	b.WriteString(titleStyle.Render(c.Name))
	b.WriteString("  ")
	b.WriteString(mutedStyle.Render(fmt.Sprintf("ns/%s · %s · %s · %d/%d %s ready%s",
		c.Namespace, c.Title(), c.Kind, c.ReadyReplicas, c.Replicas, replicaWord(c),
		statefulTag(c))))
	b.WriteString("\n\n")

	prim := c.Primary()
	b.WriteString(kv("requests", fmt.Sprintf("cpu %s   memory %s",
		format.Millis(prim.CPURequest), format.Quantity(prim.MemRequest)), width))
	b.WriteString(kv("limits", fmt.Sprintf("cpu %s   memory %s",
		format.Millis(prim.CPULimit), format.Quantity(prim.MemLimit)), width))
	b.WriteString(kv("observed", fmt.Sprintf("cpu p99 %s   memory p99 %s   peak %s",
		format.MillisFloat(u.CPUP99Millis), format.Bytes(u.MemP99Bytes), format.Bytes(u.MemMaxBytes)), width))
	b.WriteString(kv("throttled", format.Percent(u.ThrottleRatio), width))
	b.WriteString(kv("history", fmt.Sprintf("%s of %s requested",
		format.Duration(u.Coverage), format.Duration(cfg.Window)), width))
	// The pod regex is shown because it is the setting most likely to be wrong
	// on an unusual deployment, and a wrong one looks exactly like no data.
	b.WriteString(kv("pods", mutedStyle.Render(`pod=~"`+c.PodPattern+`"`), width))

	if len(u.Series) > 0 {
		sparkW := width - labelWidth - 12
		if sparkW > 60 {
			sparkW = 60
		}
		if sparkW > 4 {
			b.WriteString(kv("memory", Sparkline(u.Series, sparkW)+"  "+
				mutedStyle.Render(format.Duration(u.Coverage)+" →"), width))
		}
	}

	if res.Note != "" {
		b.WriteString("\n")
		b.WriteString(wrap.Render(mutedStyle.Render("· " + res.Note)))
		b.WriteString("\n")
	}

	for _, rec := range res.Recs {
		b.WriteString("\n")
		b.WriteString(strings.Repeat("─", width))
		b.WriteString("\n")

		head := lipgloss.NewStyle().Foreground(severityColor(rec.Severity)).Bold(true)
		b.WriteString(head.Render(rec.Severity.String()) + "  " + valueStyle.Render(rec.Title))
		b.WriteString("\n")
		b.WriteString(mutedStyle.Render(fmt.Sprintf("      %s · %s window · %s confidence",
			rec.Rule, format.Duration(rec.Window), rec.Confidence)))
		b.WriteString("\n\n")

		b.WriteString(kv("current", rec.Current, width))
		b.WriteString(kv("suggested", rec.Suggested, width))
		b.WriteString(kv("why", rec.Rationale, width))
		b.WriteString("\n")

		b.WriteString(labelStyle.Render("  evidence"))
		b.WriteString("\n")
		for _, e := range rec.Evidence {
			b.WriteString(indent.Render(fmt.Sprintf("%s  %s",
				mutedStyle.Render(e.Expr), valueStyle.Render(e.Value))))
			b.WriteString("\n")
		}

		if rec.Snippet != "" {
			b.WriteString("\n")
			b.WriteString(labelStyle.Render("  values.yaml") + mutedStyle.Render("  (press y to copy)"))
			b.WriteString("\n")
			for _, line := range strings.Split(strings.TrimRight(rec.Snippet, "\n"), "\n") {
				b.WriteString(snippetStyle.Render("    " + line))
				b.WriteString("\n")
			}
		}
	}

	return b.String()
}

// labelWidth is the gutter reserved for field labels, so wrapped values line up
// under themselves instead of falling back to column zero.
const labelWidth = 11

// kv renders a label/value pair with a hanging indent.
func kv(label, value string, width int) string {
	gutter := labelStyle.Render(fmt.Sprintf("%*s", labelWidth, label)) + "  "

	bodyW := width - labelWidth - 2
	if bodyW < 10 {
		bodyW = 10
	}
	body := lipgloss.NewStyle().Width(bodyW).Render(value)

	return lipgloss.JoinHorizontal(lipgloss.Top, gutter, body) + "\n"
}

// replicaWord avoids calling a DaemonSet's node count "replicas".
func replicaWord(c k8s.Component) string {
	if c.Kind == "DaemonSet" {
		return "nodes"
	}
	return "replicas"
}

func statefulTag(c k8s.Component) string {
	switch {
	case c.Monolithic():
		return " · single binary"
	case c.Stateful():
		return " · stateful"
	default:
		return ""
	}
}
