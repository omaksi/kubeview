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
// It must stay UNSTYLED. bubbles truncates every cell with
// runewidth.Truncate(value, col.Width, "…"), which counts ANSI escape bytes as
// visible runes: a styled "CRIT" is ~25 runes against a column width of 5, so
// it gets cut mid-escape and the terminal eats the rest of the row's colour.
// Headless tests cannot catch this — lipgloss drops to a no-colour profile
// there, where the badge really is 4 runes and fits.
//
// Colour lives in the detail pane, where nothing truncates it; in the table,
// worst-first ordering carries the signal instead.
func severityBadge(s scaling.Severity, any bool) string {
	if !any {
		return "ok"
	}
	return s.String()
}
