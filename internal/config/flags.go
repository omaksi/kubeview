package config

import (
	"fmt"
	"strings"
)

// stringSlice is a repeatable, comma-splitting flag value.
//
// The first Set clears whatever default was there, so `--kinds Deployment`
// means "only Deployments" rather than "the defaults plus Deployments". One
// instance is shared between a flag and its shorthand, so `-n a --namespace b`
// accumulates instead of the second occurrence resetting the first.
type stringSlice struct {
	target  *[]string
	touched bool
}

func newStringSlice(target *[]string) *stringSlice {
	return &stringSlice{target: target}
}

func (s *stringSlice) Set(v string) error {
	if !s.touched {
		*s.target = nil
		s.touched = true
	}
	for _, part := range strings.Split(v, ",") {
		if p := strings.TrimSpace(part); p != "" {
			*s.target = append(*s.target, p)
		}
	}
	return nil
}

func (s *stringSlice) String() string {
	if s == nil || s.target == nil {
		return ""
	}
	return strings.Join(*s.target, ",")
}

// podMatchValue validates the pod matching mode at parse time, so a typo fails
// immediately rather than silently matching nothing.
type podMatchValue PodMatch

func (p *podMatchValue) Set(v string) error {
	switch PodMatch(v) {
	case PodMatchKind, PodMatchPrefix:
		*p = podMatchValue(v)
		return nil
	default:
		return fmt.Errorf("must be %q or %q", PodMatchKind, PodMatchPrefix)
	}
}

func (p *podMatchValue) String() string {
	if p == nil {
		return ""
	}
	return string(*p)
}
