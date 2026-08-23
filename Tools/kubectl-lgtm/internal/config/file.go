package config

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"sigs.k8s.io/yaml"
)

// File is the on-disk config shape.
//
// It is deliberately a separate type from Config: the file speaks in strings
// ("14d"), the runtime speaks in time.Duration, and pointer fields let us tell
// "absent" from "set to the zero value". Keeping them apart means the file
// format can change without disturbing the rest of the program.
type File struct {
	Namespaces []string `json:"namespaces,omitempty"`
	Selector   *string  `json:"selector,omitempty"`
	Kinds      []string `json:"kinds,omitempty"`
	All        *bool    `json:"all,omitempty"`

	PodMatch          *string           `json:"podMatch,omitempty"`
	PodMatchOverrides map[string]string `json:"podMatchOverrides,omitempty"`

	PromURL    *string `json:"promURL,omitempty"`
	GrafanaURL *string `json:"grafanaURL,omitempty"`

	Window    *string `json:"window,omitempty"`
	Step      *string `json:"step,omitempty"`
	MinWindow *string `json:"minWindow,omitempty"`

	Metrics  *MetricNames   `json:"metrics,omitempty"`
	Classify *ClassifyRules `json:"classify,omitempty"`
}

// Load reads a config file. A missing file at the default path is not an
// error — the defaults are meant to work unconfigured — but a missing file the
// user named explicitly is.
func Load(path string, explicit bool) (*File, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) && !explicit {
			return nil, nil
		}
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}

	var f File
	if err := yaml.UnmarshalStrict(data, &f); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", path, err)
	}
	return &f, nil
}

// Apply merges the file into cfg. Any setting the user passed as an explicit
// flag is left alone: flags beat the file, the file beats the defaults.
func (f *File) Apply(cfg *Config, flagged map[string]bool) error {
	if f == nil {
		return nil
	}

	set := func(names ...string) bool {
		for _, n := range names {
			if flagged[n] {
				return false
			}
		}
		return true
	}

	if len(f.Namespaces) > 0 && set("namespace", "n") {
		cfg.Namespaces = append([]string(nil), f.Namespaces...)
	}
	if f.Selector != nil && set("selector", "l") {
		cfg.Selector = *f.Selector
	}
	if len(f.Kinds) > 0 && set("kinds") {
		cfg.Kinds = append([]string(nil), f.Kinds...)
	}
	if f.All != nil && set("all") {
		cfg.All = *f.All
	}
	if f.PromURL != nil && set("prom-url") {
		cfg.PromURL = *f.PromURL
	}
	if f.GrafanaURL != nil && set("grafana-url") {
		cfg.GrafanaURL = *f.GrafanaURL
	}

	if f.PodMatch != nil && set("pod-match") {
		switch PodMatch(*f.PodMatch) {
		case PodMatchKind, PodMatchPrefix:
			cfg.PodMatch = PodMatch(*f.PodMatch)
		default:
			return fmt.Errorf("podMatch: must be %q or %q, got %q",
				PodMatchKind, PodMatchPrefix, *f.PodMatch)
		}
	}
	if len(f.PodMatchOverrides) > 0 {
		if cfg.PodMatchOverrides == nil {
			cfg.PodMatchOverrides = map[string]string{}
		}
		for k, v := range f.PodMatchOverrides {
			cfg.PodMatchOverrides[k] = v
		}
	}

	for _, d := range []struct {
		raw  *string
		flag string
		dst  *time.Duration
		name string
	}{
		{f.Window, "window", &cfg.Window, "window"},
		{f.Step, "step", &cfg.Step, "step"},
		{f.MinWindow, "min-window", &cfg.MinWindow, "minWindow"},
	} {
		if d.raw == nil || !set(d.flag) {
			continue
		}
		v, err := ParseDuration(*d.raw)
		if err != nil {
			return fmt.Errorf("%s: %w", d.name, err)
		}
		*d.dst = v
	}

	if f.Metrics != nil {
		mergeMetrics(&cfg.Metrics, *f.Metrics)
	}
	if f.Classify != nil {
		mergeClassify(&cfg.Classify, *f.Classify)
	}
	return nil
}

// mergeMetrics overlays only the names the file actually set, so remapping one
// series does not blank the other five.
func mergeMetrics(dst *MetricNames, src MetricNames) {
	for _, p := range []struct{ d, s *string }{
		{&dst.MemWorkingSet, &src.MemWorkingSet},
		{&dst.CPUUsage, &src.CPUUsage},
		{&dst.ThrottledPeriods, &src.ThrottledPeriods},
		{&dst.TotalPeriods, &src.TotalPeriods},
		{&dst.LastTermReason, &src.LastTermReason},
		{&dst.Restarts, &src.Restarts},
	} {
		if *p.s != "" {
			*p.d = *p.s
		}
	}
}

// mergeClassify combines file rules with the built-ins.
//
// Label lists replace (an operator who names them means those and no others).
// Products and roles merge, so adding a vendored product name does not lose
// Mimir. Overrides append and are evaluated before anything else.
func mergeClassify(dst *ClassifyRules, src ClassifyRules) {
	if len(src.ProductLabels) > 0 {
		dst.ProductLabels = append([]string(nil), src.ProductLabels...)
	}
	if len(src.RoleLabels) > 0 {
		dst.RoleLabels = append([]string(nil), src.RoleLabels...)
	}
	if len(src.Products) > 0 {
		if dst.Products == nil {
			dst.Products = map[string][]string{}
		}
		for product, aliases := range src.Products {
			dst.Products[product] = append([]string(nil), aliases...)
		}
	}
	if len(src.Roles) > 0 {
		dst.Roles = dedupe(append(dst.Roles, src.Roles...))
	}
	dst.Overrides = append(dst.Overrides, src.Overrides...)
}

func dedupe(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := in[:0]
	for _, v := range in {
		if v == "" || seen[v] {
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	sort.SliceStable(out, func(i, j int) bool { return len(out[i]) > len(out[j]) })
	return out
}

// ParseDuration extends time.ParseDuration with days and weeks, because a
// lookback window is naturally written as "14d" and time.ParseDuration rejects
// it outright.
func ParseDuration(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty duration")
	}

	unit := time.Duration(0)
	switch s[len(s)-1] {
	case 'd':
		unit = 24 * time.Hour
	case 'w':
		unit = 7 * 24 * time.Hour
	}
	if unit != 0 {
		n, err := strconv.ParseFloat(s[:len(s)-1], 64)
		if err != nil {
			return 0, fmt.Errorf("invalid duration %q", s)
		}
		return time.Duration(n * float64(unit)), nil
	}

	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("invalid duration %q (try 14d, 12h, 30m)", s)
	}
	return d, nil
}
