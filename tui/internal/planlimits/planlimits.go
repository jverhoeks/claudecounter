// Package planlimits reads vendor-reported plan utilisation out of the
// Codex and Grok CLIs' own local logs. These percentages are
// authoritative — they come from the vendor, not from our pricing table —
// and they cover windows the vendor defines, which do not align with the
// calendar day or ISO week used for USD budgets.
//
// Every observation is point-in-time. Scanners take the single most
// recent value and never aggregate across events.
package planlimits

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// shortWindowCutoffMinutes divides the "short window" duration band from
// the weekly band. A day and a 5-hour window sit on the short side.
const shortWindowCutoffMinutes = 1440

// Gauge is one vendor's utilisation of one of its own windows.
type Gauge struct {
	Vendor    string // "codex" | "grok"
	WindowLbl string // "5h" | "7d" | "wk"
	Pct       float64
	ResetsAt  time.Time
	Observed  time.Time // when the vendor wrote this figure
	Stale     bool      // the window closed before now
	Plan      string    // "plus" | "SuperGrok" | ""
}

// WindowLabel renders a window duration compactly: hours below a day,
// whole days above. 300 -> "5h", 10080 -> "7d".
func WindowLabel(minutes int) string {
	if minutes < shortWindowCutoffMinutes {
		return fmt.Sprintf("%dh", minutes/60)
	}
	if minutes == shortWindowCutoffMinutes {
		return "24h"
	}
	return fmt.Sprintf("%dd", minutes/shortWindowCutoffMinutes)
}

// IsShortWindow reports whether a window belongs in the short-window
// display band rather than the weekly band.
func IsShortWindow(minutes int) bool { return minutes <= shortWindowCutoffMinutes }

// DefaultCodexRoot is where the Codex CLI writes session transcripts.
func DefaultCodexRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex", "sessions")
}

// DefaultGrokLog is the Grok CLI's unified log, which carries its
// billing/usage lines.
func DefaultGrokLog() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".grok", "logs", "unified.jsonl")
}
