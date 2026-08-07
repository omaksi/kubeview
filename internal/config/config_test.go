package config_test

import (
	"flag"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/omaksi/kubectl-lgtm/internal/config"
)

// parse mimics main(): bind flags, parse, then merge the file underneath only
// the settings the user did not type.
func parse(t *testing.T, file string, args ...string) config.Config {
	t.Helper()

	cfg := config.Default()
	cfg.ConfigFile = file

	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfg.BindFlags(fs)
	if err := fs.Parse(args); err != nil {
		t.Fatalf("parse %v: %v", args, err)
	}

	flagged := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { flagged[f.Name] = true })

	f, err := config.Load(cfg.ConfigFile, file != "")
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if err := f.Apply(&cfg, flagged); err != nil {
		t.Fatalf("apply config: %v", err)
	}
	return cfg
}

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

func TestNamespacesRepeatAndSplit(t *testing.T) {
	cases := []struct {
		args []string
		want []string
	}{
		{[]string{"-n", "mimir", "-n", "loki"}, []string{"mimir", "loki"}},
		{[]string{"-n", "mimir,loki,tempo"}, []string{"mimir", "loki", "tempo"}},
		// Long and short forms share one value, so they accumulate.
		{[]string{"-n", "mimir", "--namespace", "loki"}, []string{"mimir", "loki"}},
		{nil, nil},
	}

	for _, tc := range cases {
		got := parse(t, "", tc.args...).Namespaces
		if len(got) != len(tc.want) {
			t.Errorf("%v → %v, want %v", tc.args, got, tc.want)
			continue
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Errorf("%v → %v, want %v", tc.args, got, tc.want)
				break
			}
		}
	}
}

// A slice flag must replace its default, not append to it — `--kinds Deployment`
// means "only Deployments".
func TestKindsFlagReplacesDefault(t *testing.T) {
	got := parse(t, "", "--kinds", "Deployment").Kinds
	if len(got) != 1 || got[0] != "Deployment" {
		t.Errorf("kinds = %v, want [Deployment]", got)
	}
}

func TestFlagsBeatConfigFile(t *testing.T) {
	path := writeConfig(t, `
namespaces: [from-file]
promURL: http://from-file:9090
window: 7d
`)

	cfg := parse(t, path, "-n", "from-flag", "--window", "48h")

	if len(cfg.Namespaces) != 1 || cfg.Namespaces[0] != "from-flag" {
		t.Errorf("namespaces = %v, want [from-flag]", cfg.Namespaces)
	}
	if cfg.Window != 48*time.Hour {
		t.Errorf("window = %v, want 48h", cfg.Window)
	}
	// Untouched by flags, so the file wins over the default.
	if cfg.PromURL != "http://from-file:9090" {
		t.Errorf("promURL = %q, want the file's value", cfg.PromURL)
	}
}

func TestConfigFileBeatsDefaults(t *testing.T) {
	path := writeConfig(t, `
selector: app.kubernetes.io/part-of=memberlist
kinds: [StatefulSet]
podMatch: prefix
window: 2w
minWindow: 90m
metrics:
  memWorkingSet: my_custom_working_set
classify:
  products:
    mimir: [mimir, cortex, metrics-store]
  roles: [sharder]
  overrides:
    - name: "^house-.*"
      product: loki
      role: write
`)

	cfg := parse(t, path)

	if cfg.Selector != "app.kubernetes.io/part-of=memberlist" {
		t.Errorf("selector = %q", cfg.Selector)
	}
	if len(cfg.Kinds) != 1 || cfg.Kinds[0] != "StatefulSet" {
		t.Errorf("kinds = %v", cfg.Kinds)
	}
	if cfg.PodMatch != config.PodMatchPrefix {
		t.Errorf("podMatch = %q", cfg.PodMatch)
	}
	if cfg.Window != 14*24*time.Hour {
		t.Errorf("window = %v, want 2w", cfg.Window)
	}
	if cfg.MinWindow != 90*time.Minute {
		t.Errorf("minWindow = %v", cfg.MinWindow)
	}

	// One metric remapped, the rest left alone.
	if cfg.Metrics.MemWorkingSet != "my_custom_working_set" {
		t.Errorf("memWorkingSet = %q", cfg.Metrics.MemWorkingSet)
	}
	if cfg.Metrics.CPUUsage != "container_cpu_usage_seconds_total" {
		t.Errorf("cpuUsage was clobbered: %q", cfg.Metrics.CPUUsage)
	}

	// Roles merge with the built-ins rather than replacing them.
	if !contains(cfg.Classify.Roles, "sharder") {
		t.Error("configured role was dropped")
	}
	if !contains(cfg.Classify.Roles, "ingester") {
		t.Error("built-in roles were clobbered by the file")
	}
	if len(cfg.Classify.Overrides) != 1 {
		t.Errorf("overrides = %d, want 1", len(cfg.Classify.Overrides))
	}
}

func TestMissingConfigFileIsFatalOnlyWhenExplicit(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "absent.yaml")

	if _, err := config.Load(missing, false); err != nil {
		t.Errorf("default path should tolerate a missing file, got %v", err)
	}
	if _, err := config.Load(missing, true); err == nil {
		t.Error("an explicitly named missing file should error")
	}
}

func TestConfigFileRejectsUnknownKeys(t *testing.T) {
	path := writeConfig(t, "namspaces: [typo]\n")
	if _, err := config.Load(path, true); err == nil {
		t.Error("expected a parse error for an unknown key")
	}
}

func TestBadPodMatchIsRejected(t *testing.T) {
	path := writeConfig(t, "podMatch: sideways\n")
	f, err := config.Load(path, true)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	cfg := config.Default()
	if err := f.Apply(&cfg, nil); err == nil {
		t.Error("expected an error for an invalid podMatch")
	}
}

func TestParseDuration(t *testing.T) {
	cases := []struct {
		in   string
		want time.Duration
		ok   bool
	}{
		{"14d", 14 * 24 * time.Hour, true},
		{"2w", 14 * 24 * time.Hour, true},
		{"12h", 12 * time.Hour, true},
		{"90m", 90 * time.Minute, true},
		{"1.5d", 36 * time.Hour, true},
		{"", 0, false},
		{"14 days", 0, false},
		{"nope", 0, false},
	}

	for _, tc := range cases {
		got, err := config.ParseDuration(tc.in)
		if tc.ok && (err != nil || got != tc.want) {
			t.Errorf("ParseDuration(%q) = (%v, %v), want %v", tc.in, got, err, tc.want)
		}
		if !tc.ok && err == nil {
			t.Errorf("ParseDuration(%q) should have failed", tc.in)
		}
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
