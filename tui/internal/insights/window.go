// Package insights analyzes parsed Claude Code sessions for structural
// usage, waste, abuse, and loop patterns. It is a pure layer: no I/O, no
// clock, no network — callers pass parsed sessions in and get findings out.
package insights

import "strings"

const defaultWindow uint64 = 200_000

// ContextWindow returns the model's context window in tokens. The pricing
// table carries no window field, so this small map fills the gap. Any model
// id flagged with the 1M variant marker ("[1m]") gets 1,000,000; everything
// else falls back to the 200k default.
func ContextWindow(model string) uint64 {
	if strings.Contains(model, "[1m]") {
		return 1_000_000
	}
	return defaultWindow
}
