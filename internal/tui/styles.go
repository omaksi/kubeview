package tui

import (
	"github.com/charmbracelet/lipgloss"

	"github.com/omaksi/kubectl-lgtm/internal/scaling"
)

// Colours are adaptive so the tool is legible in both light and dark terminals.
var (
	colCritical = lipgloss.AdaptiveColor{Light: "#C62828", Dark: "#FF6369"}
	colWarn     = lipgloss.AdaptiveColor{Light: "#B45309", Dark: "#FFB224"}
	colInfo     = lipgloss.AdaptiveColor{Light: "#1D4ED8", Dark: "#6BA9FF"}
	colOK       = lipgloss.AdaptiveColor{Light: "#15803D", Dark: "#5BD98A"}
	colMuted    = lipgloss.AdaptiveColor{Light: "#6B7280", Dark: "#8B92A0"}
	colAccent   = lipgloss.AdaptiveColor{Light: "#5B21B6", Dark: "#B69CFF"}
	colBorder   = lipgloss.AdaptiveColor{Light: "#D1D5DB", Dark: "#3A3F4B"}
)

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(colAccent)
	mutedStyle = lipgloss.NewStyle().Foreground(colMuted)
	labelStyle = lipgloss.NewStyle().Foreground(colMuted)
	valueStyle = lipgloss.NewStyle().Bold(true)
	errStyle   = lipgloss.NewStyle().Foreground(colCritical).Bold(true)
	okStyle    = lipgloss.NewStyle().Foreground(colOK)

	paneStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(colBorder).
			Padding(0, 1)

	focusedPaneStyle = paneStyle.BorderForeground(colAccent)

	snippetStyle = lipgloss.NewStyle().Foreground(colMuted).Italic(false)
)

// severityColor maps a severity to its display colour.
func severityColor(s scaling.Severity) lipgloss.TerminalColor {
	switch s {
	case scaling.Critical:
		return colCritical
	case scaling.Warn:
		return colWarn
	default:
		return colInfo
	}
}

// severityBadge renders the short severity tag used in the table and detail
// pane. Components with no findings get a green tick rather than a blank, so a
// healthy stack reads as healthy at a glance.
func severityBadge(s scaling.Severity, any bool) string {
	if !any {
		return okStyle.Render("  ok")
	}
	return lipgloss.NewStyle().Foreground(severityColor(s)).Bold(true).Render(s.String())
}
