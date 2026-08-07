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
	"flag"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/demo"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
	"github.com/omaksi/kubectl-lgtm/internal/metrics"
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

	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "kubectl-lgtm — read-only scaling dashboard for the LGTM stack\n\n")
		fmt.Fprintf(fs.Output(), "usage:\n  kubectl lgtm [flags]\n\nflags:\n")
		fs.PrintDefaults()
		fmt.Fprintf(fs.Output(), "\nexamples:\n"+
			"  kubectl lgtm --demo\n"+
			"  kubectl lgtm --demo --demo-topology small\n"+
			"  kubectl lgtm                       # search every namespace you can list\n"+
			"  kubectl lgtm -n mimir,loki,tempo --prom-url http://mimir-query-frontend:8080/prometheus\n"+
			"  kubectl lgtm -l app.kubernetes.io/part-of=memberlist --window 7d\n"+
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

	src, prov, err := wire(cfg)
	if err != nil {
		return err
	}

	prog := tea.NewProgram(tui.New(cfg, src, prov), tea.WithAltScreen())
	_, err = prog.Run()
	return err
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
func wire(cfg config.Config) (tui.Source, metrics.Provider, error) {
	if cfg.Demo {
		return demo.NewSource(cfg), demo.NewProvider(cfg), nil
	}

	client, err := k8s.New(cfg)
	if err != nil {
		return nil, nil, fmt.Errorf("%w\n\nno cluster? try: kubectl lgtm --demo", err)
	}
	prom, err := metrics.NewPrometheus(cfg)
	if err != nil {
		return nil, nil, err
	}
	return client, prom, nil
}
