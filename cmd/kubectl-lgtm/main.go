// Command kubectl-lgtm is a read-only terminal dashboard for the LGTM stack.
//
// It shows current and historical resource usage per component and derives
// scaling recommendations from it. It never writes to the cluster: the intended
// workflow is to read a finding, copy the values.yaml snippet, and put it
// through the normal GitOps review.
//
// Named kubectl-lgtm so it can be dropped anywhere on $PATH and invoked as
// `kubectl lgtm`.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/demo"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
	"github.com/omaksi/kubectl-lgtm/internal/metrics"
	"github.com/omaksi/kubectl-lgtm/internal/scaling"
	"github.com/omaksi/kubectl-lgtm/internal/tui"
)

// version is overridden at build time via -ldflags.
var version = "dev"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "kubectl-lgtm:", err)
		os.Exit(1)
	}
}

func run() error {
	cfg := config.Default()
	fs := flag.NewFlagSet("kubectl-lgtm", flag.ExitOnError)
	cfg.BindFlags(fs)
	showVersion := fs.Bool("version", false, "print version and exit")
	jsonOut := fs.Bool("json", false, "print the analysis as JSON on stdout and exit, no UI")

	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "kubectl-lgtm — read-only scaling dashboard for the LGTM stack\n\n")
		fmt.Fprintf(fs.Output(), "usage:\n  kubectl lgtm [flags]\n\nflags:\n")
		fs.PrintDefaults()
		fmt.Fprintf(fs.Output(), "\nexamples:\n"+
			"  kubectl lgtm                       # pick a cluster, find its metrics store, go\n"+
			"  kubectl lgtm --context stg-eks     # skip the picker\n"+
			"  kubectl lgtm -n mimir,loki,tempo   # limit the search\n"+
			"  kubectl lgtm --prom-url http://localhost:9090   # bypass discovery entirely\n"+
			"  kubectl lgtm -l app.kubernetes.io/part-of=memberlist --window 7d\n"+
			"  kubectl lgtm --demo\n"+
			"  kubectl lgtm --context stg-eks --json   # machine-readable, no UI\n"+
			"\nconfig file (flags win over it):\n"+
			"  %s\n", cfg.ConfigFile)
	}
	if err := fs.Parse(os.Args[1:]); err != nil {
		return err
	}
	if *showVersion {
		fmt.Println("kubectl-lgtm", version)
		return nil
	}

	if err := applyConfigFile(&cfg, fs); err != nil {
		return err
	}

	// Ask which cluster before touching one. --context and --json both skip
	// this, so scripted and embedded use never block on a prompt.
	if !cfg.Demo && cfg.Context == "" && !*jsonOut {
		names, current, err := k8s.Contexts(cfg.Kubeconfig)
		if err != nil {
			return err
		}
		chosen, err := tui.PickContext(names, current)
		if err != nil {
			return err
		}
		cfg.Context = chosen
	}

	src, prov, connect, cleanup, err := wire(&cfg, *jsonOut)
	if err != nil {
		return err
	}
	defer cleanup()

	if *jsonOut {
		return runJSON(cfg, src, prov, connect)
	}

	prog := tea.NewProgram(tui.New(cfg, src, prov, connect), tea.WithAltScreen())
	_, err = prog.Run()
	return err
}

// closer holds the teardown for whatever connect opened. connect runs on a
// Bubble Tea goroutine while main waits on Run, so the write is guarded.
type closer struct {
	mu sync.Mutex
	fn func()
}

func (c *closer) set(fn func()) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.fn = fn
}

func (c *closer) run() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fn != nil {
		c.fn()
		c.fn = nil
	}
}

// applyConfigFile merges the config file underneath the flags.
//
// Precedence is defaults < file < flags. fs.Visit reports only the flags the
// user actually typed, which is what lets the file fill in everything else
// without clobbering an explicit choice.
func applyConfigFile(cfg *config.Config, fs *flag.FlagSet) error {
	flagged := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { flagged[f.Name] = true })

	file, err := config.Load(cfg.ConfigFile, flagged["config"])
	if err != nil {
		return err
	}
	return file.Apply(cfg, flagged)
}

// wire picks the data sources. --demo swaps both of them for fixtures, which is
// why no other package needs to know the mode exists.
//
// quiet suppresses every prompt, for --json: an embedded caller has no terminal
// to answer with, so an ambiguous namespace widens the search instead of asking.
func wire(cfg *config.Config, quiet bool) (tui.Source, metrics.Provider, tui.Connect, func(), error) {
	noop := func() {}
	if cfg.Demo {
		return demo.NewSource(*cfg), demo.NewProvider(*cfg), nil, noop, nil
	}

	client, err := k8s.New(*cfg)
	if err != nil {
		return nil, nil, nil, noop, fmt.Errorf("cannot reach a cluster with this context: %w", err)
	}

	// Narrow to the namespace holding the stack. Asked only when there is a
	// genuine choice, so the common case stays flag-free. This runs before the
	// program starts because it is interactive; it is also the first call that
	// touches the API server, so expired credentials surface here.
	if len(cfg.Namespaces) == 0 {
		fmt.Fprintln(os.Stderr, "scanning the cluster for LGTM components…")

		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		found, err := client.ProductNamespaces(ctx)
		cancel()
		if err != nil {
			return nil, nil, nil, noop, explain(err, *cfg)
		}

		var chosen string
		if quiet {
			// One hit is not a choice; more than one means searching all of
			// them, which is what the picker offers as its first option anyway.
			if len(found) == 1 {
				chosen = found[0]
			}
		} else if chosen, err = tui.PickNamespace(found); err != nil {
			return nil, nil, nil, noop, err
		}
		if chosen != "" {
			cfg.Namespaces = []string{chosen}
			// Rebuild so the client, and the endpoint search, both see the
			// narrowed scope. New() does no I/O beyond reading kubeconfig.
			if client, err = k8s.New(*cfg); err != nil {
				return nil, nil, nil, noop, err
			}
		}
	}

	// Endpoint discovery runs inside the program so it can show progress and
	// report failure in the UI, rather than leaving a blank terminal and then
	// printing to stderr.
	cl := &closer{}
	snapshot := *cfg
	connect := func(ctx context.Context, progress func(string)) (metrics.Provider, error) {
		progress("looking for a metrics endpoint…")
		prom, done, err := metrics.Discover(ctx, client.Clientset(), client.RestConfig(), snapshot, progress)
		if err != nil {
			return nil, explain(err, snapshot)
		}
		cl.set(done)
		return prom, nil
	}

	return client, nil, connect, cl.run, nil
}

// explain turns the two failures a first run actually hits into something
// actionable. A raw exec-plugin error says nothing about which login expired.
//
// It names the condition and leaves the remedy to whoever is reading: this
// output is rendered in a desktop app as often as in a terminal, and a shell
// command is not something a window can act on.
func explain(err error, cfg config.Config) error {
	s := err.Error()
	switch {
	case strings.Contains(s, "getting credentials"), strings.Contains(s, "exec:"):
		return fmt.Errorf("%w\n\nthe login for context %q has expired or is not valid\n"+
			"refresh it and try again", err, cfg.Context)
	case strings.Contains(s, "pods/portforward"), strings.Contains(s, "cannot create resource"):
		return fmt.Errorf("%w\n\nreading the metrics store needs create on pods/portforward in that\n"+
			"namespace, and this account does not have it", err)
	}
	return err
}

// runJSON prints the analysis as JSON and exits. It is the entry point every
// front end that is not the TUI goes through — the macOS app shells out to it
// exactly the way it shells out to kubectl.
//
// Progress goes to stderr so stdout carries nothing but the object.
func runJSON(cfg config.Config, src tui.Source, prov metrics.Provider, connect tui.Connect) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	kubeContext := cfg.Context
	if kubeContext == "" {
		if _, current, err := k8s.Contexts(cfg.Kubeconfig); err == nil {
			kubeContext = current
		}
	}

	// --no-metrics never calls connect: that closure is what opens the
	// port-forward and issues the PromQL queries, and skipping the call
	// entirely — rather than calling it and discarding the result — is what
	// makes this path safe when the metrics store is down or slow.
	if cfg.NoMetrics {
		results, err := scaling.RunNoMetrics(ctx, cfg, src, scaling.Default())
		if err != nil {
			return err
		}
		return writeJSON(os.Stdout, jsonReport{
			Version:          version,
			GeneratedAt:      time.Now().UTC(),
			Context:          kubeContext,
			Scope:            src.Describe(),
			Source:           "not queried",
			MetricsAvailable: false,
			WindowSecs:       cfg.Window.Seconds(),
			Components:       toJSON(results),
		})
	}

	if prov == nil {
		p, err := connect(ctx, func(s string) { fmt.Fprintln(os.Stderr, s) })
		if err != nil {
			return err
		}
		prov = p
	}

	results, err := scaling.Run(ctx, cfg, src, prov, scaling.Default())
	if err != nil {
		return err
	}

	return writeJSON(os.Stdout, jsonReport{
		Version:          version,
		GeneratedAt:      time.Now().UTC(),
		Context:          kubeContext,
		Scope:            src.Describe(),
		Source:           prov.Describe(),
		MetricsAvailable: true,
		Warning:          providerWarning(prov),
		WindowSecs:       cfg.Window.Seconds(),
		Components:       toJSON(results),
	})
}

// providerWarning reads the optional caveat a provider may carry. Optional
// interface rather than a Provider method, so the demo fixtures and any future
// source stay as small as they are.
func providerWarning(prov metrics.Provider) string {
	if w, ok := prov.(interface{ Warning() string }); ok {
		return w.Warning()
	}
	return ""
}
