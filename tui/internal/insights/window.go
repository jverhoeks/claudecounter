// Package insights analyzes parsed Claude Code sessions for structural
// usage, waste, abuse, and loop patterns. It is a pure layer: no I/O, no
// clock, no network — callers pass parsed sessions in and get findings out.
package insights

import "strings"

const defaultWindow uint64 = 200_000

const largeWindow uint64 = 1_000_000

// ContextWindow returns the model's nominal context window in tokens. The
// pricing table carries no window field, so this small map fills the gap. Any
// model id flagged with the 1M variant marker ("[1m]") gets 1,000,000;
// everything else falls back to the 200k default.
func ContextWindow(model string) uint64 {
	if strings.Contains(model, "[1m]") {
		return largeWindow
	}
	return defaultWindow
}

// EffectiveWindow returns the window to score a session against. Real
// transcripts often record the 1M-beta models without the "[1m]" marker (the
// id is just "claude-opus-4-8"), so the nominal map under-reports. A single
// request's input+cache can never exceed the model's actual window, so an
// observed peak above the nominal 200k is proof the session ran on the larger
// window — we bump to 1M rather than print an impossible >100%.
func EffectiveWindow(model string, peak uint64) uint64 {
	win := ContextWindow(model)
	if peak > win {
		return largeWindow
	}
	return win
}
