package tui

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/demo"
)

const (
	testWidth  = 150
	testHeight = 46
)

// renderDemo drives the model through a real update cycle without a terminal,
// which makes the layout testable and lets `go test -v` print the screen.
func renderDemo(t *testing.T, width, height int) string {
	t.Helper()
	return renderTopology(t, "large", width, height)
}

func renderTopology(t *testing.T, topology string, width, height int) string {
	t.Helper()

	cfg := config.Default()
	cfg.Demo = true
	cfg.DemoTopology = topology

	var m tea.Model = New(cfg, demo.NewSource(cfg), demo.NewProvider(cfg), nil)

	loaded := m.(Model).load()()
	if msg, ok := loaded.(resultsMsg); ok && msg.err != nil {
		t.Fatalf("load failed: %v", msg.err)
	}

	m, _ = m.Update(tea.WindowSizeMsg{Width: width, Height: height})
	m, _ = m.Update(loaded)
	return m.View()
}

func TestViewRendersDemoStack(t *testing.T) {
	view := renderDemo(t, testWidth, testHeight)
	t.Log("\n" + view)

	for _, want := range []string{
		"kubectl-lgtm",
		"COMPONENT",
		"mimir-distributor",
		"critical",
		"demo",
		// The large topology spans namespaces, so the column must appear.
		"NAMESPACE",
		// The detail pane must be populated on first paint, not after the
		// first keypress. (Evidence sits below the fold — it is checked
		// against the unclipped render in
		// TestDetailPaneShowsEvidenceForSelection.)
		"requests",
		"observed",
		"suggested",
	} {
		if !strings.Contains(view, want) {
			t.Errorf("view is missing %q", want)
		}
	}
}

// Regression: the first layout runs on the window-size message, before results
// exist, and bubbles' SetRows leaves the cursor at -1 when given no rows.
func TestSelectionIsValidOnFirstPaint(t *testing.T) {
	cfg := config.Default()
	cfg.Demo = true

	var m tea.Model = New(cfg, demo.NewSource(cfg), demo.NewProvider(cfg), nil)
	loaded := m.(Model).load()()
	m, _ = m.Update(tea.WindowSizeMsg{Width: testWidth, Height: testHeight})
	m, _ = m.Update(loaded)

	if _, ok := m.(Model).selected(); !ok {
		t.Fatalf("no selection after load, cursor = %d", m.(Model).table.Cursor())
	}
}

// A single-namespace stack must not waste a column on a namespace that is the
// same on every row.
func TestSmallTopologyRendersWithoutNamespaceColumn(t *testing.T) {
	view := renderTopology(t, "small", testWidth, testHeight)
	t.Log("\n" + view)

	if strings.Contains(view, "NAMESPACE") {
		t.Error("namespace column shown for a single-namespace stack")
	}
	for _, want := range []string{"loki", "alloy", "DaemonSet", "single binary"} {
		if !strings.Contains(view, want) {
			t.Errorf("view is missing %q", want)
		}
	}
}

// Horizontal overflow is the classic TUI bug: it wraps and shears the whole
// frame. Check every rendered line against the terminal width, in both
// topologies — the namespace column changes the budget.
func TestViewNeverExceedsTerminalWidth(t *testing.T) {
	for _, topology := range []string{"large", "small"} {
		for _, width := range []int{80, 100, 150, 220} {
			view := renderTopology(t, topology, width, testHeight)
			for i, line := range strings.Split(view, "\n") {
				if w := lipgloss.Width(line); w > width {
					t.Errorf("%s topology at width %d: line %d is %d cells wide:\n%s",
						topology, width, i, w, line)
				}
			}
		}
	}
}

func TestViewFitsTerminalHeight(t *testing.T) {
	for _, topology := range []string{"large", "small"} {
		for _, height := range []int{24, 30, 46, 60} {
			view := renderTopology(t, topology, testWidth, height)
			if got := len(strings.Split(view, "\n")); got > height {
				t.Errorf("%s topology at height %d: view rendered %d lines",
					topology, height, got)
			}
		}
	}
}

func TestDetailPaneShowsEvidenceForSelection(t *testing.T) {
	cfg := config.Default()
	cfg.Demo = true

	var m tea.Model = New(cfg, demo.NewSource(cfg), demo.NewProvider(cfg), nil)
	loaded := m.(Model).load()()
	m, _ = m.Update(tea.WindowSizeMsg{Width: testWidth, Height: testHeight})
	m, _ = m.Update(loaded)

	// Walk down to the store-gateway, the fixture with the OOMKill.
	for i := 0; i < 20; i++ {
		if res, ok := m.(Model).selected(); ok && res.Component.Name == "mimir-store-gateway" {
			break
		}
		m, _ = m.Update(tea.KeyMsg{Type: tea.KeyDown})
	}

	res, ok := m.(Model).selected()
	if !ok || res.Component.Name != "mimir-store-gateway" {
		t.Fatalf("could not select mimir-store-gateway, landed on %+v", res.Component.Name)
	}

	detail := renderDetail(res, cfg, 120)
	t.Log("\n" + detail)

	for _, want := range []string{
		"OOMKilled",
		"evidence",
		"values.yaml",
		"limits",
	} {
		if !strings.Contains(detail, want) {
			t.Errorf("detail pane is missing %q", want)
		}
	}
}
