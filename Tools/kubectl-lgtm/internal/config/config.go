// Package config holds runtime configuration for kubectl-lgtm.
//
// Two things are configurable on purpose, because they are what differs
// between a three-pod test stack and a fifty-pod production one:
//
//   - discovery — which namespaces, which label selector, which kinds
//   - classification — how a workload maps to a product and a role
//
// Metric names live here too. cAdvisor, kube-state-metrics and the
// Mimir/Loki/Tempo charts all rename series between releases, and a rule that
// hardcodes one is a rule that silently reports a healthy stack.
package config

import (
	"flag"
	"os"
	"path/filepath"
	"time"
)

// PodMatch selects how a workload's pods are matched in PromQL.
type PodMatch string

const (
	// PodMatchKind builds a regex from Kubernetes' own pod naming rules:
	// `<sts>-<ordinal>` for StatefulSets, `<deploy>-<rs-hash>-<pod-hash>` for
	// Deployments. Prometheus anchors regex matchers, so this cannot bleed
	// across workloads whose names prefix one another.
	PodMatchKind PodMatch = "kind"

	// PodMatchPrefix is the loose `<workload>-.*` form. Correct for unusual
	// pod naming, wrong when one workload name prefixes another.
	PodMatchPrefix PodMatch = "prefix"
)

// Config is the fully-resolved runtime configuration.
type Config struct {
	Kubeconfig string
	Context    string
	ConfigFile string

	// Namespaces to search. Empty means every namespace the user can list,
	// falling back to the kubeconfig's namespace when that is forbidden.
	Namespaces []string
	// Selector is a label selector applied when listing workloads.
	Selector string
	// Kinds limits which workload kinds are considered.
	Kinds []string
	// All keeps workloads that could not be classified as part of the stack.
	All bool

	PodMatch PodMatch
	// PodMatchOverrides maps a workload name to an explicit pod regex, for
	// deployments that name pods in a way the built-in modes cannot express.
	PodMatchOverrides map[string]string

	PromURL    string
	GrafanaURL string
	// Match is appended to every PromQL selector, e.g. cluster="inno-shared-eks".
	// A central store holding several clusters uses the same namespace and pod
	// names in each, so without this max() silently spans them.
	Match string

	// Tenant is sent as X-Scope-OrgID. Needed only when talking straight to a
	// multi-tenant Mimir; its gateway supplies a default.
	Tenant string

	// NoMetrics skips endpoint discovery and every PromQL query. Every
	// component is still listed and classified from the Kubernetes API alone;
	// only usage numbers and the findings derived from them are absent. It is
	// a runtime mode rather than deployment shape, so — like Demo — it is
	// flag-only and not settable from the config file.
	NoMetrics bool

	Window      time.Duration
	Step        time.Duration
	MinWindow   time.Duration
	SparkPoints int

	Demo         bool
	DemoTopology string

	Metrics  MetricNames
	Classify ClassifyRules
}

// MetricNames lets an operator remap series that differ between chart versions.
type MetricNames struct {
	MemWorkingSet    string `json:"memWorkingSet,omitempty"`
	CPUUsage         string `json:"cpuUsage,omitempty"`
	ThrottledPeriods string `json:"throttledPeriods,omitempty"`
	TotalPeriods     string `json:"totalPeriods,omitempty"`
	LastTermReason   string `json:"lastTerminatedReason,omitempty"`
	Restarts         string `json:"restarts,omitempty"`
}

// ClassifyRules describes how a workload is mapped to a product and a role.
// Everything here is data rather than code so an unusual deployment can be
// described in a config file instead of a patch.
type ClassifyRules struct {
	// ProductLabels are consulted in order for the product name.
	ProductLabels []string `json:"productLabels,omitempty"`
	// RoleLabels are consulted in order for the component role.
	RoleLabels []string `json:"roleLabels,omitempty"`
	// Products maps a product to the aliases that identify it, in labels or
	// in the workload name.
	Products map[string][]string `json:"products,omitempty"`
	// Roles are matched against the workload name when no role label is
	// present. Longest match wins, so "query-frontend" beats "querier".
	Roles []string `json:"roles,omitempty"`
	// Overrides are applied first and win outright.
	Overrides []ClassifyOverride `json:"overrides,omitempty"`
}

// ClassifyOverride forces the classification of matching workloads.
type ClassifyOverride struct {
	// Namespace is an optional exact match.
	Namespace string `json:"namespace,omitempty"`
	// Name is a regex matched against the workload name.
	Name string `json:"name"`

	Product string `json:"product,omitempty"`
	Role    string `json:"role,omitempty"`
	Zone    string `json:"zone,omitempty"`
}

// DefaultKinds is the workload set considered when nothing is configured.
// DaemonSets are included because collection agents (Alloy, Promtail) are part
// of most stacks and are worth sizing.
var DefaultKinds = []string{"Deployment", "StatefulSet", "DaemonSet"}

// DefaultRoles covers the distributed deployment modes plus the collapsed ones.
// A small cluster runs Loki as `single-binary` or as `read`/`write`/`backend`,
// and Mimir or Tempo as a single `all` target; a large one splits every role
// out. Both must classify.
var DefaultRoles = []string{
	// longest first — "query-frontend" must not be matched as "querier"
	"overrides-exporter",
	"metrics-generator",
	"query-scheduler",
	"query-frontend",
	"store-gateway",
	"index-gateway",
	"single-binary",
	"results-cache",
	"metadata-cache",
	"chunks-cache",
	"alertmanager",
	"distributor",
	"table-manager",
	"compactor",
	"ingester",
	"querier",
	"backend",
	"gateway",
	"ruler",
	"write",
	"read",
	"all",
}

// DefaultProducts maps each product to the aliases seen in the wild. Cortex is
// included because Mimir forked from it and older charts still use the name.
var DefaultProducts = map[string][]string{
	"mimir":     {"mimir", "cortex"},
	"loki":      {"loki"},
	"tempo":     {"tempo"},
	"grafana":   {"grafana"},
	"pyroscope": {"pyroscope", "phlare"},
	"alloy":     {"alloy", "grafana-agent", "promtail"},
}

// Default returns the configuration used when no flags or file are supplied.
func Default() Config {
	return Config{
		Kubeconfig:   defaultKubeconfig(),
		ConfigFile:   defaultConfigFile(),
		Kinds:        append([]string(nil), DefaultKinds...),
		PodMatch:     PodMatchKind,
		PromURL:      "",
		Window:       14 * 24 * time.Hour,
		Step:         time.Hour,
		MinWindow:    6 * time.Hour,
		SparkPoints:  24,
		DemoTopology: "large",
		Metrics: MetricNames{
			MemWorkingSet:    "container_memory_working_set_bytes",
			CPUUsage:         "container_cpu_usage_seconds_total",
			ThrottledPeriods: "container_cpu_cfs_throttled_periods_total",
			TotalPeriods:     "container_cpu_cfs_periods_total",
			LastTermReason:   "kube_pod_container_status_last_terminated_reason",
			Restarts:         "kube_pod_container_status_restarts_total",
		},
		Classify: ClassifyRules{
			ProductLabels: []string{
				"app.kubernetes.io/name",
				"app.kubernetes.io/part-of",
				"app",
			},
			RoleLabels: []string{
				"app.kubernetes.io/component",
				"app.kubernetes.io/target",
			},
			Products: cloneProducts(DefaultProducts),
			Roles:    append([]string(nil), DefaultRoles...),
		},
	}
}

func cloneProducts(in map[string][]string) map[string][]string {
	out := make(map[string][]string, len(in))
	for k, v := range in {
		out[k] = append([]string(nil), v...)
	}
	return out
}

func defaultKubeconfig() string {
	if v := os.Getenv("KUBECONFIG"); v != "" {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".kube", "config")
}

// defaultConfigFile points at the XDG location. A missing file is not an
// error — the defaults are meant to work unconfigured.
//
// os.UserConfigDir is deliberately not used: on macOS it returns
// ~/Library/Application Support, and command-line tools live in ~/.config there
// like everywhere else.
func defaultConfigFile() string {
	if v := os.Getenv("KUBECTL_LGTM_CONFIG"); v != "" {
		return v
	}
	if dir := os.Getenv("XDG_CONFIG_HOME"); dir != "" {
		return filepath.Join(dir, "kubectl-lgtm", "config.yaml")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "kubectl-lgtm", "config.yaml")
}

// BindFlags registers the user-facing flags onto fs.
func (c *Config) BindFlags(fs *flag.FlagSet) {
	fs.StringVar(&c.Kubeconfig, "kubeconfig", c.Kubeconfig, "path to kubeconfig")
	fs.StringVar(&c.Context, "context", c.Context, "kubeconfig context to use")
	fs.StringVar(&c.ConfigFile, "config", c.ConfigFile, "path to a kubectl-lgtm config file")

	// One value instance per target, registered under both the long and short
	// name, so `-n a --namespace b` accumulates rather than resetting.
	namespaces := newStringSlice(&c.Namespaces)
	fs.Var(namespaces, "namespace",
		"namespace to search; repeatable or comma-separated (default: every namespace you can list)")
	fs.Var(namespaces, "n", "shorthand for --namespace")

	fs.StringVar(&c.Selector, "selector", c.Selector,
		"label selector for workload discovery, e.g. app.kubernetes.io/part-of=memberlist")
	fs.StringVar(&c.Selector, "l", c.Selector, "shorthand for --selector")

	fs.Var(newStringSlice(&c.Kinds), "kinds", "workload kinds to consider (Deployment, StatefulSet, DaemonSet)")
	fs.BoolVar(&c.All, "all", c.All, "include workloads that are not recognised as part of the stack")

	fs.Var((*podMatchValue)(&c.PodMatch), "pod-match",
		"how to match a workload's pods in PromQL: kind (exact, uses k8s naming) or prefix (loose)")

	fs.StringVar(&c.PromURL, "prom-url", c.PromURL,
		"Prometheus/Mimir query endpoint (default: discover one in the cluster)")
	fs.StringVar(&c.Tenant, "tenant", c.Tenant, "Mimir tenant, sent as X-Scope-OrgID")
	fs.StringVar(&c.Match, "match", c.Match,
		`extra PromQL label matchers, e.g. cluster="inno-shared-eks"`)
	fs.StringVar(&c.GrafanaURL, "grafana-url", c.GrafanaURL, "Grafana base URL, used by the 'g' key")

	fs.BoolVar(&c.NoMetrics, "no-metrics", c.NoMetrics,
		"skip endpoint discovery and every PromQL query; list and classify components only")

	fs.Var((*durationValue)(&c.Window), "window", "lookback window for usage analysis, e.g. 14d, 24h")
	fs.Var((*durationValue)(&c.Step), "step", "inner resolution of range queries")
	fs.Var((*durationValue)(&c.MinWindow), "min-window", "shortest history that may produce a recommendation")

	fs.BoolVar(&c.Demo, "demo", c.Demo, "run against synthetic data, no cluster or Prometheus needed")
	fs.StringVar(&c.DemoTopology, "demo-topology", c.DemoTopology,
		"demo stack shape: large (microservices) or small (single-binary)")
}

// NamespaceLabel describes the namespace scope for display.
func (c Config) NamespaceLabel() string {
	switch len(c.Namespaces) {
	case 0:
		return "all namespaces"
	case 1:
		return "ns/" + c.Namespaces[0]
	default:
		return "ns × " + itoa(len(c.Namespaces))
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
