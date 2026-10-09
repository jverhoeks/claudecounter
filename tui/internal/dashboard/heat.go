package dashboard

import (
	"fmt"
	"sort"
)

// HeatStop is one colour stop of the macapp's HeatField scale: dark navy
// at zero, then blue, cyan, yellow, orange, red.
type HeatStop struct {
	T   float64
	RGB uint32
}

var HeatStops = []HeatStop{
	{0.00, 0x0d1330}, {0.15, 0x153b8f}, {0.35, 0x1f8fd6}, {0.55, 0x3fd1c7},
	{0.72, 0xf2d14b}, {0.86, 0xf08a24}, {1.00, 0xe8412c},
}

// HeatColor is the scale at t (clamped to [0,1]), as "#rrggbb".
func HeatColor(t float64) string {
	t = min(max(t, 0), 1)
	lo, hi := HeatStops[0], HeatStops[len(HeatStops)-1]
	for i := 1; i < len(HeatStops); i++ {
		if t <= HeatStops[i].T {
			lo, hi = HeatStops[i-1], HeatStops[i]
			break
		}
	}
	f := 0.0
	if hi.T != lo.T {
		f = (t - lo.T) / (hi.T - lo.T)
	}
	ch := func(shift uint) int {
		a, b := float64(lo.RGB>>shift&0xff), float64(hi.RGB>>shift&0xff)
		return int(a + (b-a)*f)
	}
	return fmt.Sprintf("#%02x%02x%02x", ch(16), ch(8), ch(0))
}

// HeatCap is where the scale tops out: the 95th percentile of active
// cells, so one outlier hour doesn't leave everything else cold.
func HeatCap(grid [7][24]float64) float64 {
	var active []float64
	for _, row := range grid {
		for _, v := range row {
			if v > 0 {
				active = append(active, v)
			}
		}
	}
	if len(active) == 0 {
		return 1
	}
	sort.Float64s(active)
	return max(active[int(float64(len(active)-1)*0.95)], 0.01)
}
