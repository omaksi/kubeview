// Package format renders numbers the way an operator expects to read them.
package format

import (
	"fmt"
	"math"
	"time"
)

const (
	Ki = 1024
	Mi = 1024 * Ki
	Gi = 1024 * Mi
	Ti = 1024 * Gi
)

// Bytes renders a byte count for display: 5.1Gi, 380Mi, "-" when unset.
func Bytes(v float64) string {
	if v <= 0 || math.IsNaN(v) {
		return "-"
	}
	switch {
	case v >= Ti:
		return fmt.Sprintf("%.1fTi", v/Ti)
	case v >= Gi:
		return fmt.Sprintf("%.1fGi", v/Gi)
	case v >= Mi:
		return fmt.Sprintf("%.0fMi", v/Mi)
	default:
		return fmt.Sprintf("%.0fKi", v/Ki)
	}
}

// Quantity renders a byte count as an exact Kubernetes resource quantity,
// suitable for pasting into a values file. Unlike Bytes it never loses
// precision: the value is always a whole number of the chosen unit.
func Quantity(v int64) string {
	switch {
	case v == 0:
		return "0"
	case v%Gi == 0:
		return fmt.Sprintf("%dGi", v/Gi)
	case v%Mi == 0:
		return fmt.Sprintf("%dMi", v/Mi)
	default:
		return fmt.Sprintf("%dKi", (v+Ki-1)/Ki)
	}
}

// Millis renders CPU millicores as a Kubernetes quantity.
func Millis(v int64) string {
	if v <= 0 {
		return "-"
	}
	return fmt.Sprintf("%dm", v)
}

// MillisFloat renders a measured CPU value, which is rarely a round number.
func MillisFloat(v float64) string {
	if v <= 0 || math.IsNaN(v) {
		return "-"
	}
	return fmt.Sprintf("%.0fm", v)
}

// Percent renders a 0..1 ratio.
func Percent(v float64) string {
	if math.IsNaN(v) {
		return "-"
	}
	return fmt.Sprintf("%.0f%%", v*100)
}

// Ratio renders a multiplier, e.g. 2.4x.
func Ratio(v float64) string {
	if v <= 0 || math.IsNaN(v) || math.IsInf(v, 0) {
		return "-"
	}
	return fmt.Sprintf("%.1fx", v)
}

// Duration renders a lookback window compactly: 14d, 6h, 45m.
func Duration(d time.Duration) string {
	switch {
	case d >= 24*time.Hour:
		return fmt.Sprintf("%dd", int(d.Hours())/24)
	case d >= time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
}
