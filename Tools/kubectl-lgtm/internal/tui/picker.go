package tui

import (
	"errors"
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ErrNoContextChosen means the operator dismissed the picker.
var ErrNoContextChosen = errors.New("no context chosen")

// pickerWindow caps how many contexts are on screen at once. A kubeconfig that
// has accumulated every cluster an engineer has ever touched should scroll, not
// overflow the terminal.
const pickerWindow = 12

type picker struct {
	title   string
	names   []string
	current string
	cursor  int
	top     int
	chosen  string
}

// PickContext asks which cluster to inspect.
//
// It runs before the main model, as its own short-lived program, so the table
// model never has to carry a second state machine for a screen shown at most
// once per run.
func PickContext(names []string, current string) (string, error) {
	if len(names) == 0 {
		return "", errors.New("no contexts found in kubeconfig")
	}
	if len(names) == 1 {
		return names[0], nil
	}

	p := picker{title: "which cluster?", names: names, current: current}
	for i, n := range names {
		if n == current {
			p.cursor = i
		}
	}
	p.scroll()

	final, err := tea.NewProgram(p).Run()
	if err != nil {
		return "", err
	}
	got, ok := final.(picker)
	if !ok || got.chosen == "" {
		return "", ErrNoContextChosen
	}
	return got.chosen, nil
}

func (p picker) Init() tea.Cmd { return nil }

func (p picker) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	key, ok := msg.(tea.KeyMsg)
	if !ok {
		return p, nil
	}
	switch key.String() {
	case "ctrl+c", "q", "esc":
		return p, tea.Quit
	case "up", "k":
		if p.cursor > 0 {
			p.cursor--
		}
	case "down", "j":
		if p.cursor < len(p.names)-1 {
			p.cursor++
		}
	case "home", "g":
		p.cursor = 0
	case "end", "G":
		p.cursor = len(p.names) - 1
	case "enter":
		p.chosen = p.names[p.cursor]
		return p, tea.Quit
	}
	p.scroll()
	return p, nil
}

// scroll keeps the cursor inside the visible window.
func (p *picker) scroll() {
	if p.cursor < p.top {
		p.top = p.cursor
	}
	if p.cursor >= p.top+pickerWindow {
		p.top = p.cursor - pickerWindow + 1
	}
	if p.top < 0 {
		p.top = 0
	}
}

func (p picker) View() string {
	var b strings.Builder

	b.WriteString(lipgloss.NewStyle().Bold(true).Foreground(colAccent).Render("kubectl-lgtm"))
	b.WriteString(lipgloss.NewStyle().Foreground(colMuted).Render("  " + p.title))
	b.WriteString("\n\n")

	end := min(p.top+pickerWindow, len(p.names))
	for i := p.top; i < end; i++ {
		name := p.names[i]
		line := "  " + name
		if name == p.current {
			line += lipgloss.NewStyle().Foreground(colMuted).Render("  (current)")
		}
		if i == p.cursor {
			b.WriteString(lipgloss.NewStyle().Bold(true).Foreground(colAccent).Render("> " + name))
			if name == p.current {
				b.WriteString(lipgloss.NewStyle().Foreground(colMuted).Render("  (current)"))
			}
		} else {
			b.WriteString(line)
		}
		b.WriteString("\n")
	}

	if len(p.names) > pickerWindow {
		b.WriteString(lipgloss.NewStyle().Foreground(colMuted).
			Render(fmt.Sprintf("\n  %d/%d", p.cursor+1, len(p.names))))
		b.WriteString("\n")
	}

	b.WriteString("\n")
	b.WriteString(lipgloss.NewStyle().Foreground(colMuted).
		Render("↑/↓ move • enter select • q cancel"))
	b.WriteString("\n")
	return b.String()
}

// allNamespaces is the sentinel entry meaning "do not narrow the search".
const allNamespaces = "· all namespaces ·"

// PickNamespace asks which namespace to inspect, given the ones that actually
// contain LGTM components.
//
// It only asks when there is a real choice: nothing found or a single
// namespace answers itself, which is what makes the bare binary work without
// flags on a normal deployment. The returned string is empty for "search
// everything".
func PickNamespace(found []string) (string, error) {
	switch len(found) {
	case 0:
		return "", nil
	case 1:
		return found[0], nil
	}

	p := picker{
		title: "which namespace?",
		names: append(append([]string{}, found...), allNamespaces),
	}
	final, err := tea.NewProgram(p).Run()
	if err != nil {
		return "", err
	}
	got, ok := final.(picker)
	if !ok || got.chosen == "" {
		return "", ErrNoContextChosen
	}
	if got.chosen == allNamespaces {
		return "", nil
	}
	return got.chosen, nil
}
