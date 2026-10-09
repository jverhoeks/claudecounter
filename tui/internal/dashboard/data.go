package dashboard

import (
	"github.com/jverhoeks/claudecounter/tui/internal/hints"
	"github.com/jverhoeks/claudecounter/tui/internal/perf"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

// Data is one scan's worth of everything the analytics views draw from.
type Data struct {
	Spend    Snapshot
	Samples  []perf.Sample
	Settings hints.Settings
	Sources  []sources.Source
	Warnings []string
	Pricing  pricing.Table
}

// Loader scans afresh; progress reports per-request-parse files done of
// total and may be nil.
type Loader func(progress func(done, total int)) Data
