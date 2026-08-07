package tui

import (
	"math"
	"strings"
)

var blocks = []rune("▁▂▃▄▅▆▇█")

// Sparkline renders a series as inline block characters, resampled to width.
//
// The scale is min-to-max within the series, not zero-based: for memory usage
// the interesting signal is the shape of the change, and a zero-based scale
// flattens every busy component into a straight line.
func Sparkline(vals []float64, width int) string {
	if width <= 0 {
		return ""
	}
	if len(vals) == 0 {
		return strings.Repeat("·", width)
	}

	buckets := resample(vals, width)

	min, max := math.Inf(1), math.Inf(-1)
	for _, v := range buckets {
		if math.IsNaN(v) {
			continue
		}
		min = math.Min(min, v)
		max = math.Max(max, v)
	}
	if math.IsInf(min, 1) {
		return strings.Repeat("·", width)
	}

	var b strings.Builder
	span := max - min
	for _, v := range buckets {
		if math.IsNaN(v) {
			b.WriteRune('·')
			continue
		}
		// A flat series sits mid-scale rather than at the floor, so that
		// "steady" and "idle" do not look identical.
		idx := len(blocks) / 2
		if span > 0 {
			idx = int((v - min) / span * float64(len(blocks)-1))
		}
		b.WriteRune(blocks[clamp(idx, 0, len(blocks)-1)])
	}
	return b.String()
}

// resample averages the series into exactly width buckets, repeating values
// when the series is shorter than the target width.
func resample(vals []float64, width int) []float64 {
	out := make([]float64, width)
	if len(vals) <= width {
		for i := range out {
			out[i] = vals[i*len(vals)/width]
		}
		return out
	}
	for i := range out {
		lo := i * len(vals) / width
		hi := (i + 1) * len(vals) / width
		if hi <= lo {
			hi = lo + 1
		}
		sum, n := 0.0, 0
		for _, v := range vals[lo:hi] {
			if math.IsNaN(v) {
				continue
			}
			sum += v
			n++
		}
		if n == 0 {
			out[i] = math.NaN()
			continue
		}
		out[i] = sum / float64(n)
	}
	return out
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
