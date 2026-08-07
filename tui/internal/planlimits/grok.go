package planlimits

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"
	"time"
)

// grokBillingMarker is the log message that carries the usage figure.
const grokBillingMarker = "billing: fetched credits config"

type grokLine struct {
	TS  string `json:"ts"`
	Msg string `json:"msg"`
	Ctx struct {
		Config struct {
			CreditUsagePercent float64 `json:"creditUsagePercent"`
			CurrentPeriod      struct {
				Type  string `json:"type"`
				Start string `json:"start"`
				End   string `json:"end"`
			} `json:"currentPeriod"`
		} `json:"config"`
		SubscriptionTier string `json:"subscriptionTier"`
	} `json:"ctx"`
}

// ScanGrok returns Grok's weekly utilisation, or nothing.
//
// Grok reports only a weekly billing period — every observed period was
// USAGE_PERIOD_TYPE_WEEKLY — and it is vendor-anchored (Thursday 20:00
// UTC), so it aligns with neither the ISO week nor Codex's 7-day rolling
// window. It is never reconciled with either.
//
// Grok's session transcripts are deliberately NOT read: they carry only
// a cumulative per-prompt context total, which is not billable tokens,
// and they are where all the corpus size is.
func ScanGrok(path string, now time.Time) ([]Gauge, error) {
	if path == "" {
		return nil, nil
	}
	fh, err := os.Open(path)
	if err != nil {
		return nil, nil // absent log is a normal state, not a failure
	}
	defer fh.Close()

	var newest *Gauge
	var newestAt time.Time

	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 0, 256*1024), 4*1024*1024)
	for sc.Scan() {
		raw := sc.Text()
		// Substring reject first: only ~105 of many thousands of lines
		// are billing lines, so this avoids parsing almost all of them.
		if !strings.Contains(raw, grokBillingMarker) {
			continue
		}
		var l grokLine
		if err := json.Unmarshal([]byte(raw), &l); err != nil {
			continue
		}
		if l.Msg != grokBillingMarker {
			continue
		}
		obs, err := time.Parse(time.RFC3339, l.TS)
		if err != nil {
			continue
		}
		if newest != nil && !obs.After(newestAt) {
			continue
		}
		end, err := time.Parse(time.RFC3339, l.Ctx.Config.CurrentPeriod.End)
		if err != nil {
			continue
		}
		newestAt = obs
		newest = &Gauge{
			Vendor:    "grok",
			WindowLbl: "wk",
			Pct:       l.Ctx.Config.CreditUsagePercent,
			ResetsAt:  end,
			Observed:  obs,
			Stale:     end.Before(now),
			Plan:      l.Ctx.SubscriptionTier,
		}
	}
	// A scanner error — e.g. a line larger than the 4 MiB buffer above —
	// ends Scan() early: any billing lines physically after the bad one
	// are unreadable and lost. That is a partial read, not a fatal one: any
	// billing lines found before it still count. Per ScanGrok's "optional
	// input" contract this is never surfaced to the caller as an error.
	_ = sc.Err()

	if newest == nil {
		return nil, nil
	}
	return []Gauge{*newest}, nil
}
