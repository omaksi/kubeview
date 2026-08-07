// Package tui renders the terminal interface.
//
// The model is read-only by construction: there is no code path from a
// keystroke to a cluster mutation. The most destructive thing a key can do is
// put YAML on the clipboard.
package tui

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/bubbles/help"
	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/omaksi/kubectl-lgtm/internal/clipboard"
	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/format"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
	"github.com/omaksi/kubectl-lgtm/internal/metrics"
	"github.com/omaksi/kubectl-lgtm/internal/scaling"
)

// Source lists the components to analyse. Both the live cluster client and the
// demo fixtures satisfy it, which is the whole of the --demo implementation.
type Source interface {
	ListComponents(ctx context.Context) ([]k8s.Component, error)
	// Describe reports the scope actually searched. It is not always the scope
	// requested — a cluster-wide list can fall back to one namespace — so the
	// header shows what happened rather than what was asked for.
	Describe() string
}

// maxConcurrentQueries bounds the fan-out against Prometheus. Each component
// issues six queries, and a 40-component stack would otherwise open 240 at once.
const maxConcurrentQueries = 8

type resultsMsg struct {
	results []scaling.Result
	err     error
}

type statusMsg struct {
	text  string
	isErr bool
}

type clearStatusMsg struct{}

// Model is the Bubble Tea model.
type Model struct {
	cfg    config.Config
	source Source
	prov   metrics.Provider
	engine *scaling.Engine

	table  table.Model
	detail viewport.Model
	help   help.Model
	keys   keyMap

	results []scaling.Result
	loading bool
	err     error

	status      string
	statusIsErr bool

	width, height int
	ready         bool
	focusDetail   bool
	showFullHelp  bool
}

// New builds the model. Nothing is fetched until Init runs.
func New(cfg config.Config, src Source, prov metrics.Provider) Model {
	t := table.New(table.WithFocused(true))
	st := table.DefaultStyles()
	st.Header = st.Header.Bold(true).Foreground(colMuted).
		BorderStyle(lipgloss.NormalBorder()).BorderBottom(true).BorderForeground(colBorder)
	st.Selected = st.Selected.Bold(true).Foreground(colAccent).Reverse(true)
	t.SetStyles(st)

	return Model{
		cfg:     cfg,
		source:  src,
		prov:    prov,
		engine:  scaling.Default(),
		table:   t,
		help:    help.New(),
		keys:    defaultKeys(),
		loading: true,
	}
}

func (m Model) Init() tea.Cmd { return m.load() }

// load fetches components and their usage, then runs the rule engine. Usage
// queries fan out because they are network-bound and independent.
func (m Model) load() tea.Cmd {
	cfg, src, prov, engine := m.cfg, m.source, m.prov, m.engine
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()

		comps, err := src.ListComponents(ctx)
		if err != nil {
			return resultsMsg{err: err}
		}
		if len(comps) == 0 {
			return resultsMsg{err: fmt.Errorf(
				"no LGTM components found in %s\n\n"+
					"try --namespace to point somewhere else, --selector to widen the match,\n"+
					"--all to keep workloads that were not recognised, or --demo to see the UI",
				src.Describe())}
		}

		results := make([]scaling.Result, len(comps))
		sem := make(chan struct{}, maxConcurrentQueries)
		var wg sync.WaitGroup

		for i, c := range comps {
			wg.Add(1)
			go func(i int, c k8s.Component) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				usage, uerr := prov.Usage(ctx, metrics.Target{
					Namespace:  c.Namespace,
					Name:       c.Name,
					PodPattern: c.PodPattern,
				})
				res := engine.Analyze(scaling.Input{Component: c, Usage: usage, Cfg: cfg})
				if uerr != nil {
					// Without usage data there is nothing to recommend, and
					// saying so beats presenting an empty row as healthy.
					res.Recs = nil
					res.Note = "metrics unavailable: " + uerr.Error()
				}
				results[i] = res
			}(i, c)
		}
		wg.Wait()
		return resultsMsg{results: results}
	}
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.ready = true
		m.layout()

	case resultsMsg:
		m.loading = false
		m.err = msg.err
		if msg.err == nil {
			m.results = msg.results
		}
		m.layout()

	case statusMsg:
		m.status, m.statusIsErr = msg.text, msg.isErr
		cmds = append(cmds, tea.Tick(4*time.Second, func(time.Time) tea.Msg {
			return clearStatusMsg{}
		}))

	case clearStatusMsg:
		m.status = ""

	case tea.KeyMsg:
		switch {
		case key.Matches(msg, m.keys.Quit):
			return m, tea.Quit

		case key.Matches(msg, m.keys.Refresh):
			m.loading = true
			m.status = ""
			return m, m.load()

		case key.Matches(msg, m.keys.Help):
			m.showFullHelp = !m.showFullHelp
			m.help.ShowAll = m.showFullHelp
			m.layout()
			return m, nil

		case key.Matches(msg, m.keys.Focus):
			m.focusDetail = !m.focusDetail
			if m.focusDetail {
				m.table.Blur()
			} else {
				m.table.Focus()
			}
			return m, nil

		case key.Matches(msg, m.keys.Copy):
			return m, m.copySnippets()

		case key.Matches(msg, m.keys.Grafana):
			return m, m.openGrafana()
		}
	}

	if m.focusDetail {
		var cmd tea.Cmd
		m.detail, cmd = m.detail.Update(msg)
		cmds = append(cmds, cmd)
	} else {
		var cmd tea.Cmd
		m.table, cmd = m.table.Update(msg)
		cmds = append(cmds, cmd)
		m.syncDetail()
	}

	return m, tea.Batch(cmds...)
}

// selected returns the currently highlighted result.
func (m Model) selected() (scaling.Result, bool) {
	i := m.table.Cursor()
	if i < 0 || i >= len(m.results) {
		return scaling.Result{}, false
	}
	return m.results[i], true
}

// copySnippets puts every values.yaml fragment for the selected component on
// the clipboard. Copying all of them rather than "the top one" keeps the
// binding predictable when a component has several findings.
func (m Model) copySnippets() tea.Cmd {
	res, ok := m.selected()
	if !ok || len(res.Recs) == 0 {
		return status("nothing to copy for this component", true)
	}
	var parts []string
	for _, rec := range res.Recs {
		if rec.Snippet != "" {
			parts = append(parts, strings.TrimRight(rec.Snippet, "\n"))
		}
	}
	if len(parts) == 0 {
		return status("no snippets on these findings", true)
	}
	via, err := clipboard.Copy(strings.Join(parts, "\n\n"))
	if err != nil {
		return status(err.Error(), true)
	}
	return status(fmt.Sprintf("copied %d snippet(s) via %s", len(parts), via), false)
}

func (m Model) openGrafana() tea.Cmd {
	res, ok := m.selected()
	if !ok {
		return nil
	}
	u, err := grafanaExploreURL(m.cfg, res.Component)
	if err != nil {
		return status(err.Error(), true)
	}
	if err := openURL(u); err != nil {
		return status("could not open browser: "+err.Error(), true)
	}
	return status("opened "+res.Component.Name+" in Grafana Explore", false)
}

func status(text string, isErr bool) tea.Cmd {
	return func() tea.Msg { return statusMsg{text: text, isErr: isErr} }
}

// rows renders the component table using exactly the columns that survived
// visibleSpecs, so headers and cells cannot drift apart.
func (m Model) rows(innerW int) []table.Row {
	specs := m.visibleSpecs(innerW)

	rows := make([]table.Row, 0, len(m.results))
	for _, res := range m.results {
		c, u := res.Component, res.Usage
		sev, any := res.Worst()

		findings := "-"
		if any {
			findings = fmt.Sprintf("%d", len(res.Recs))
		}

		v := rowValues{
			sev:       severityBadge(sev, any),
			namespace: c.Namespace,
			name:      c.Name,
			kind:      c.Kind,
			ready:     fmt.Sprintf("%d/%d", c.ReadyReplicas, c.Replicas),
			memReq:    format.Quantity(c.Primary().MemRequest),
			memP99:    format.Bytes(u.MemP99Bytes),
			cpuP99:    format.MillisFloat(u.CPUP99Millis),
			trend:     Sparkline(u.Series, m.sparkWidth()),
			findings:  findings,
		}

		row := make(table.Row, 0, len(specs))
		for _, spec := range specs {
			row = append(row, spec.value(v))
		}
		rows = append(rows, row)
	}
	return rows
}

func (m Model) sparkWidth() int {
	w := m.cfg.SparkPoints
	if w > 24 {
		w = 24
	}
	if w < 8 {
		w = 8
	}
	return w
}

// layout recomputes pane geometry. The table gets the top 55% so a stack of
// twenty components stays visible while reading a finding.
func (m *Model) layout() {
	if !m.ready {
		return
	}
	helpH := 1
	if m.showFullHelp {
		helpH = 4
	}
	chrome := 1 /*header*/ + 1 /*status*/ + helpH
	avail := m.height - chrome
	if avail < 8 {
		avail = 8
	}

	tableOuter := avail * 55 / 100
	if tableOuter < 6 {
		tableOuter = 6
	}
	detailOuter := avail - tableOuter
	if detailOuter < 4 {
		detailOuter = 4
	}

	innerW := m.width - 4 // pane border + padding
	if innerW < 20 {
		innerW = 20
	}

	m.table.SetColumns(m.columns(innerW))
	m.table.SetRows(m.rows(innerW))
	m.table.SetWidth(innerW)
	m.table.SetHeight(tableOuter - 2)

	// bubbles' SetRows pushes the cursor to -1 when it is handed an empty set,
	// and never restores it once rows arrive. The first layout happens on the
	// window-size message, before any results, so without this the selection —
	// and with it the whole detail pane — stays empty.
	if m.table.Cursor() < 0 && len(m.results) > 0 {
		m.table.SetCursor(0)
	}

	m.detail.Width = innerW
	m.detail.Height = detailOuter - 2
	m.help.Width = m.width - 2
	m.syncDetail()
}

// columnSpec describes one table column and how readily it can be sacrificed.
// A column with dropOrder 0 is never dropped; higher numbers go first.
type columnSpec struct {
	title     string
	width     int
	dropOrder int
	// value extracts the cell, so dropping a column cannot desynchronise the
	// header from the rows.
	value func(rowValues) string
}

// rowValues is the per-component data the table can display.
type rowValues struct {
	sev       string
	namespace string
	name      string
	kind      string
	ready     string
	memReq    string
	memP99    string
	cpuP99    string
	trend     string
	findings  string
}

// multiNamespace reports whether the results span more than one namespace, in
// which case the table needs a column to disambiguate them.
func (m Model) multiNamespace() bool {
	var first string
	for _, r := range m.results {
		if first == "" {
			first = r.Component.Namespace
			continue
		}
		if r.Component.Namespace != first {
			return true
		}
	}
	return false
}

// minNameWidth is the narrowest a component name may be squeezed before other
// columns must go instead.
const minNameWidth = 18

// specs returns the full column set in display order. The namespace column
// appears only when the results actually span more than one.
func (m Model) specs() []columnSpec {
	cols := []columnSpec{
		{"SEV", 5, 0, func(v rowValues) string { return v.sev }},
	}
	if m.multiNamespace() {
		cols = append(cols,
			columnSpec{"NAMESPACE", 14, 6, func(v rowValues) string { return v.namespace }})
	}
	return append(cols,
		columnSpec{"COMPONENT", 0, 0, func(v rowValues) string { return v.name }}, // flexes
		columnSpec{"KIND", 11, 3, func(v rowValues) string { return v.kind }},
		columnSpec{"READY", 6, 0, func(v rowValues) string { return v.ready }},
		columnSpec{"MEM REQ", 8, 5, func(v rowValues) string { return v.memReq }},
		columnSpec{"MEM p99", 8, 0, func(v rowValues) string { return v.memP99 }},
		columnSpec{"CPU p99", 8, 2, func(v rowValues) string { return v.cpuP99 }},
		columnSpec{"TREND", m.sparkWidth(), 1, func(v rowValues) string { return v.trend }},
		columnSpec{"FIND", 4, 4, func(v rowValues) string { return v.findings }},
	)
}

// visibleSpecs drops optional columns, widest-sacrifice-first, until the table
// fits innerW. Without this the table overflows its pane on an 80-column
// terminal and lipgloss wraps every row, shearing the whole frame.
func (m Model) visibleSpecs(innerW int) []columnSpec {
	specs := m.specs()

	fits := func(s []columnSpec) (int, bool) {
		// bubbles pads every cell by one column on each side
		used := 2 * len(s)
		for _, c := range s {
			used += c.width
		}
		nameW := innerW - used
		return nameW, nameW >= minNameWidth
	}

	for {
		if _, ok := fits(specs); ok {
			break
		}
		victim, order := -1, 0
		for i, c := range specs {
			if c.dropOrder > order {
				victim, order = i, c.dropOrder
			}
		}
		if victim < 0 {
			break // only mandatory columns left; accept the squeeze
		}
		specs = append(specs[:victim:victim], specs[victim+1:]...)
	}

	nameW, _ := fits(specs)
	if nameW < 8 {
		nameW = 8
	}
	for i := range specs {
		if specs[i].width == 0 {
			specs[i].width = nameW
		}
	}
	return specs
}

func (m Model) columns(innerW int) []table.Column {
	specs := m.visibleSpecs(innerW)
	cols := make([]table.Column, 0, len(specs))
	for _, c := range specs {
		cols = append(cols, table.Column{Title: c.title, Width: c.width})
	}
	return cols
}

func (m *Model) syncDetail() {
	res, ok := m.selected()
	if !ok {
		m.detail.SetContent("")
		return
	}
	m.detail.SetContent(renderDetail(res, m.cfg, m.detail.Width))
}

func (m Model) View() string {
	if !m.ready {
		return "starting…"
	}
	if m.err != nil {
		return lipgloss.NewStyle().Padding(1, 2).Render(
			errStyle.Render("error") + "\n\n" +
				lipgloss.NewStyle().Width(m.width-4).Render(m.err.Error()) +
				"\n\n" + mutedStyle.Render("press r to retry, q to quit"))
	}
	if m.loading {
		return lipgloss.NewStyle().Padding(1, 2).Render(
			titleStyle.Render("kubectl-lgtm") + "\n\n" +
				mutedStyle.Render(fmt.Sprintf("querying %s over a %s window…",
					m.prov.Describe(), format.Duration(m.cfg.Window))))
	}

	tablePane, detailPane := paneStyle, paneStyle
	if m.focusDetail {
		detailPane = focusedPaneStyle
	} else {
		tablePane = focusedPaneStyle
	}

	return strings.Join([]string{
		m.header(),
		tablePane.Width(m.width - 2).Render(m.table.View()),
		detailPane.Width(m.width - 2).Render(m.detail.View()),
		m.statusLine(),
		m.help.View(m.keys),
	}, "\n")
}

// header renders the title bar, shedding context as the terminal narrows.
// The finding counts on the right are the last thing to go — they are the
// reason to look at the bar at all.
func (m Model) header() string {
	crit, warn := 0, 0
	for _, r := range m.results {
		for _, rec := range r.Recs {
			switch rec.Severity {
			case scaling.Critical:
				crit++
			case scaling.Warn:
				warn++
			}
		}
	}

	right := okStyle.Render("no findings")
	if crit > 0 || warn > 0 {
		right = lipgloss.NewStyle().Foreground(colCritical).Render(fmt.Sprintf("%d critical", crit)) +
			mutedStyle.Render("  ") +
			lipgloss.NewStyle().Foreground(colWarn).Render(fmt.Sprintf("%d warning", warn))
	}

	title := titleStyle.Render("kubectl-lgtm")
	scope := m.source.Describe()
	tiers := []string{
		fmt.Sprintf("  %s  ·  %s  ·  %s window  ·  %d components",
			scope, m.prov.Describe(), format.Duration(m.cfg.Window), len(m.results)),
		fmt.Sprintf("  %s  ·  %s window", scope, format.Duration(m.cfg.Window)),
		"  " + scope,
		"",
	}

	avail := m.width - 2
	for _, tier := range tiers {
		left := title + mutedStyle.Render(tier)
		gap := avail - lipgloss.Width(left) - lipgloss.Width(right)
		if gap >= 2 {
			return " " + left + strings.Repeat(" ", gap) + right
		}
	}
	// Nothing fits alongside the counts; keep the counts and drop the title.
	return " " + truncate(right, avail)
}

func (m Model) statusLine() string {
	if m.status == "" {
		return ""
	}
	st := okStyle
	if m.statusIsErr {
		st = errStyle
	}
	return " " + truncate(st.Render(m.status), m.width-2)
}

// truncate cuts a styled string to n cells without counting ANSI sequences.
func truncate(s string, n int) string {
	if n < 1 {
		return ""
	}
	return lipgloss.NewStyle().MaxWidth(n).Render(s)
}
