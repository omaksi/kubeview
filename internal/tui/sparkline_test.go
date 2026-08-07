package tui

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSparklineWidthIsExact(t *testing.T) {
	cases := []struct {
		name  string
		vals  []float64
		width int
	}{
		{"downsample", []float64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, 4},
		{"upsample", []float64{1, 2, 3}, 12},
		{"exact", []float64{1, 2, 3, 4}, 4},
		{"empty", nil, 8},
	}

	for _, tc := range cases {
		got := utf8.RuneCountInString(Sparkline(tc.vals, tc.width))
		if got != tc.width {
			t.Errorf("%s: width = %d runes, want %d", tc.name, got, tc.width)
		}
	}
}

func TestSparklineRisesWithTheSeries(t *testing.T) {
	out := []rune(Sparkline([]float64{1, 2, 3, 4, 5, 6, 7, 8}, 8))
	for i := 1; i < len(out); i++ {
		if out[i] < out[i-1] {
			t.Fatalf("expected a monotonically rising sparkline, got %q", string(out))
		}
	}
	if out[0] == out[len(out)-1] {
		t.Errorf("expected visible range across a rising series, got %q", string(out))
	}
}

// A flat series must not render at the floor: "steady" and "idle" look
// identical then, which is misleading at a glance.
func TestSparklineFlatSeriesSitsMidScale(t *testing.T) {
	out := Sparkline([]float64{5, 5, 5, 5, 5, 5}, 6)
	mid := blocks[len(blocks)/2]
	if out != strings.Repeat(string(mid), 6) {
		t.Errorf("flat series rendered as %q, want six %q", out, string(mid))
	}
}

func TestSparklineZeroWidthIsEmpty(t *testing.T) {
	if got := Sparkline([]float64{1, 2, 3}, 0); got != "" {
		t.Errorf("width 0 rendered %q, want empty", got)
	}
}
