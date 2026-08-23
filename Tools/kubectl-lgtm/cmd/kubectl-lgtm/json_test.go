package main

import (
	"bytes"
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"
	"time"
)

// TestJSONWireFormatKeys pins the --json wire format.
//
// kubectl-lgtm has exactly one consumer of this output — the KubeView macOS
// app's LgtmService.swift — living in a separate repo. Nothing in the Go build
// notices if a field here gets renamed or dropped; it would just silently stop
// decoding on the other side of the wire, discovered only against a real
// cluster. This test is what stands in for that consumer: it marshals a fully
// populated report (every field set, including the omitempty ones, and a
// non-empty per-pod slice) and asserts the exact set of JSON key paths against
// a checked-in golden file, so renaming or dropping a field fails the build
// here instead.
//
// If a field is deliberately added or renamed, update testdata/json_keys.golden
// to match — that edit is the record of the wire format change.
func TestJSONWireFormatKeys(t *testing.T) {
	report := jsonReport{
		Version:          "dev",
		GeneratedAt:      time.Date(2026, 8, 23, 5, 37, 21, 675376000, time.UTC),
		Context:          "arn:aws:eks:eu-central-1:000000000000:cluster/example",
		Scope:            "ns/observability",
		Source:           "observability/lgtm-distributed-mimir-nginx (Mimir gateway)",
		Warning:          "this store holds 5 clusters — every aggregation spans all of them",
		MetricsAvailable: true,
		WindowSecs:       86400,
		Components: []jsonComponent{
			{
				Name:             "mimir-distributor",
				Namespace:        "observability",
				Kind:             "Deployment",
				Product:          "mimir",
				Role:             "distributor",
				Zone:             "a",
				Title:            "mimir/distributor",
				PodPattern:       "mimir-distributor-[0-9a-f]+-[0-9a-z]+",
				Replicas:         3,
				ReadyReplicas:    3,
				Stateful:         false,
				CPURequestMillis: 500,
				CPULimitMillis:   1000,
				MemRequestBytes:  1073741824,
				MemLimitBytes:    2147483648,
				Usage: jsonUsage{
					MemP99Bytes:   1500000000,
					MemMaxBytes:   1800000000,
					CPUP99Millis:  650,
					ThrottleRatio: 0.02,
					OOMContainers: 0,
					Restarts:      2,
					CoverageSecs:  86400,
					Series:        []float64{1, 2, 3},
					Pods: []jsonPodUsage{
						{
							Name:          "mimir-distributor-abc123-xyz",
							MemP99Bytes:   1500000000,
							MemMaxBytes:   1800000000,
							CPUP99Millis:  650,
							ThrottleRatio: 0.02,
							OOMContainers: 0,
							Restarts:      2,
						},
					},
				},
				Note:     "no findings — sized within tolerance",
				Severity: "WARN",
				Findings: []jsonRec{
					{
						Rule:       "cpu-throttling",
						Severity:   "WARN",
						Title:      "approaching CPU limit",
						Current:    "1000m limit",
						Suggested:  "1500m limit",
						Rationale:  "p99 CPU is within 15% of the configured limit",
						Confidence: "high",
						WindowSecs: 86400,
						Snippet:    "distributor:\n  resources:\n    limits:\n      cpu: 1500m\n",
						GrafanaURL: "https://grafana.example/d/abc?var-namespace=observability",
						Evidence: []jsonEvidence{
							{Expr: "quantile_over_time(0.99, ...)", Value: "650"},
						},
					},
				},
			},
		},
	}

	var buf bytes.Buffer
	if err := writeJSON(&buf, report); err != nil {
		t.Fatalf("writeJSON: %v", err)
	}

	var generic interface{}
	if err := json.Unmarshal(buf.Bytes(), &generic); err != nil {
		t.Fatalf("unmarshal produced JSON: %v", err)
	}

	var raw []string
	collectPaths(generic, "", &raw)
	paths := dedupeSorted(raw)

	const goldenPath = "testdata/json_keys.golden"
	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(goldenPath, []byte(strings.Join(paths, "\n")+"\n"), 0o644); err != nil {
			t.Fatalf("writing golden file: %v", err)
		}
	}

	wantRaw, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("reading golden file: %v (run with UPDATE_GOLDEN=1 to create it)", err)
	}
	want := strings.Split(strings.TrimRight(string(wantRaw), "\n"), "\n")

	if !stringsEqual(paths, want) {
		t.Errorf("--json key set changed from testdata/json_keys.golden\ngot:\n%s\n\nwant:\n%s\n\n"+
			"if this is an intentional, additive wire-format change, update the golden file with:\n"+
			"  UPDATE_GOLDEN=1 go test ./cmd/kubectl-lgtm/ -run TestJSONWireFormatKeys",
			strings.Join(paths, "\n"), strings.Join(want, "\n"))
	}
}

// collectPaths walks a decoded JSON value and records the dotted path of every
// leaf (scalar or null). Array indices are normalized to "N" so the path set
// describes shape, not a particular slice length.
func collectPaths(v interface{}, prefix string, out *[]string) {
	switch val := v.(type) {
	case map[string]interface{}:
		keys := make([]string, 0, len(val))
		for k := range val {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			p := k
			if prefix != "" {
				p = prefix + "." + k
			}
			collectPaths(val[k], p, out)
		}
	case []interface{}:
		p := prefix + ".N"
		if len(val) == 0 {
			// An empty array still carries a shape worth pinning — a rule
			// enforced elsewhere in this package guarantees every array field
			// here is emitted as [] rather than null, and losing that would
			// mean a consumer decoding into a non-optional Swift array starts
			// seeing null.
			*out = append(*out, prefix+".[]")
			return
		}
		for _, elem := range val {
			collectPaths(elem, p, out)
		}
	default:
		*out = append(*out, prefix)
	}
}

// dedupeSorted sorts and dedupes path list; a repeated-element array (e.g.
// usage.series) otherwise contributes one identical leaf path per element.
func dedupeSorted(in []string) []string {
	sort.Strings(in)
	out := in[:0]
	var last string
	for i, p := range in {
		if i == 0 || p != last {
			out = append(out, p)
			last = p
		}
	}
	return out
}

func stringsEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
