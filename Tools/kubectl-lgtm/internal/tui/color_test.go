package tui

import (
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// truncatedEscape matches an ANSI sequence that was cut off mid-parameter by a
// width-based truncation: ESC [ digits, then the ellipsis instead of a final
// byte. A terminal cannot parse this, so it swallows the rest of the row.
var truncatedEscape = regexp.MustCompile("\x1b\\[[0-9;]*…")

// withTrueColor forces a colour profile for the duration of a test.
//
// Every other test in this package renders with lipgloss's no-colour profile,
// because there is no TTY under `go test`. That is precisely why the SEV column
// shipped broken: styled cell values are ~25 runes with escapes but 4 without,
// and bubbles truncates cells by rune count at a column width of 5. Without
// this the whole class of bug is invisible to the suite.
func withTrueColor(t *testing.T) {
	t.Helper()
	prev := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(prev) })
}

func TestNoCellIsTruncatedMidEscapeInColor(t *testing.T) {
	withTrueColor(t)

	for _, width := range []int{80, 100, 150, 220} {
		frame := renderDemo(t, width, testHeight)
		if loc := truncatedEscape.FindString(frame); loc != "" {
			t.Errorf("width %d: a styled cell was truncated mid-escape (%q) — "+
				"table cells must not contain ANSI, bubbles truncates them by rune count",
				width, loc)
		}
	}
}

// The severity column is the one thing an operator scans first. It has to
// survive rendering on a colour terminal, not just a headless one.
func TestSeverityColumnIsReadableInColor(t *testing.T) {
	withTrueColor(t)

	frame := renderDemo(t, testWidth, testHeight)
	for _, want := range []string{"CRIT", "WARN"} {
		if !strings.Contains(frame, want) {
			t.Errorf("severity %q is missing from the table on a colour terminal", want)
		}
	}
}
