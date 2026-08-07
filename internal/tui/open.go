package tui

import (
	"fmt"
	"net/url"
	"os/exec"
	"runtime"
	"strings"

	"github.com/omaksi/kubectl-lgtm/internal/config"
	"github.com/omaksi/kubectl-lgtm/internal/k8s"
)

// grafanaExploreURL builds an Explore link pre-filled with the memory query for
// a component. Deep analysis belongs in a browser — the terminal is for triage,
// and there is no point reimplementing a time-series viewer badly.
func grafanaExploreURL(cfg config.Config, c k8s.Component) (string, error) {
	if cfg.GrafanaURL == "" {
		return "", fmt.Errorf("no Grafana URL configured, pass --grafana-url")
	}
	expr := fmt.Sprintf(`max by (pod) (%s{namespace=%q,pod=~%q,container!=""})`,
		cfg.Metrics.MemWorkingSet, c.Namespace, c.PodPattern)

	// Explore takes a JSON blob in the `left` parameter. Building it by hand
	// keeps this dependency-free and the shape is stable across Grafana 9-12.
	pane := fmt.Sprintf(`{"queries":[{"refId":"A","expr":%q}],"range":{"from":"now-%s","to":"now"}}`,
		expr, promRange(cfg))

	base := strings.TrimRight(cfg.GrafanaURL, "/")
	return fmt.Sprintf("%s/explore?left=%s", base, url.QueryEscape(pane)), nil
}

func promRange(cfg config.Config) string {
	hours := int(cfg.Window.Hours())
	if hours%24 == 0 {
		return fmt.Sprintf("%dd", hours/24)
	}
	return fmt.Sprintf("%dh", hours)
}

// openURL hands a URL to the desktop browser.
func openURL(u string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", u)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	return cmd.Start()
}
