// Package dashboard is the data behind the analytics views (--dashboards
// and --web-dashboards): spend history with the hour of day, and the
// pure helpers the macapp's dashboard window draws from (Analytics.swift).
//
// It keeps its own cells rather than extending agg: agg's cells are
// keyed by day only and its Snapshot feeds the --once golden output,
// which this must not move.
package dashboard

import (
	"strings"
	"sync"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
)

// Key is one series within a day-hour: the same cut as agg's cells.
type Key struct {
	Project string
	Source  string
	Vendor  string
	Model   string
	IsSub   bool
}

type slot struct {
	Day  string // YYYY-MM-DD, local
	Hour int    // local hour 0-23
	Key  Key
}

type cell struct {
	Tokens       agg.TokenCounts
	PricedTokens agg.TokenCounts // the part priced from the table
	CostedUSD    float64         // the part the vendor costed itself
}

// History collects reader events into day × hour × series cells. Safe
// for one writer and concurrent readers.
type History struct {
	mu       sync.Mutex
	pricing  pricing.Table
	seen     map[string]struct{}
	cells    map[slot]cell
	coverage map[string]map[string]agg.Coverage // day -> vendor
}

func NewHistory(p pricing.Table) *History {
	return &History{
		pricing:  p,
		seen:     map[string]struct{}{},
		cells:    map[slot]cell{},
		coverage: map[string]map[string]agg.Coverage{},
	}
}

func DayKey(t time.Time) string { return t.Local().Format("2006-01-02") }

// Apply mirrors agg.Aggregator.Apply: dedupe by message:request,
// coverage-only events count turns and never spend, costed events carry
// their own USD.
func (h *History) Apply(e reader.Event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if e.MessageID != "" && e.RequestID != "" {
		k := e.MessageID + ":" + e.RequestID
		if _, dup := h.seen[k]; dup {
			return
		}
		h.seen[k] = struct{}{}
	}
	day := DayKey(e.Timestamp)
	if e.CoverageOnly {
		byVendor := h.coverage[day]
		if byVendor == nil {
			byVendor = map[string]agg.Coverage{}
			h.coverage[day] = byVendor
		}
		c := byVendor[e.Vendor]
		c.Turns++
		if e.HasUsage {
			c.WithUsage++
		}
		byVendor[e.Vendor] = c
		return
	}
	s := slot{Day: day, Hour: e.Timestamp.Local().Hour(), Key: Key{
		Project: e.Project, Source: e.Source, Vendor: e.Vendor, Model: e.Model, IsSub: e.IsSubagent,
	}}
	tok := agg.TokenCounts{
		In: e.Usage.InputTokens, Out: e.Usage.OutputTokens,
		CacheCreate: e.Usage.CacheCreationInputTokens, CacheRead: e.Usage.CacheReadInputTokens,
		CacheCreate1h: e.Usage.CacheCreation1hInputTokens,
	}
	c := h.cells[s]
	c.Tokens = c.Tokens.Add(tok)
	if e.Costed {
		c.CostedUSD += e.CostUSD
	} else {
		c.PricedTokens = c.PricedTokens.Add(tok)
	}
	h.cells[s] = c
}

// Row is one priced cell of a Snapshot.
type Row struct {
	Day  string
	Hour int
	Key  Key
	agg.ModelDay
}

// Snapshot is an immutable, priced copy of the history.
type Snapshot struct {
	Rows     []Row
	Coverage map[string]map[string]agg.Coverage // day -> vendor
	AsOf     time.Time
}

func (h *History) Snapshot(now time.Time) Snapshot {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := Snapshot{Rows: make([]Row, 0, len(h.cells)), Coverage: map[string]map[string]agg.Coverage{}, AsOf: now}
	for s, c := range h.cells {
		usd := c.CostedUSD + h.pricing.Cost(s.Key.Model, c.PricedTokens.ToUsage())
		out.Rows = append(out.Rows, Row{Day: s.Day, Hour: s.Hour, Key: s.Key, ModelDay: agg.ModelDay{USD: usd, Tokens: c.Tokens}})
	}
	for d, m := range h.coverage {
		cp := make(map[string]agg.Coverage, len(m))
		for k, v := range m {
			cp[k] = v
		}
		out.Coverage[d] = cp
	}
	return out
}

// ShortProject is the tail of Claude's dash-encoded project dir
// ("-Users-me-src-foo-bar" → "foo-bar").
func ShortProject(encoded string) string {
	if encoded == "" {
		return "(unknown)"
	}
	parts := strings.Split(strings.TrimPrefix(encoded, "-"), "-")
	if len(parts) <= 4 {
		return encoded
	}
	tail := strings.Join(parts[4:], "-")
	if tail == "" {
		return encoded
	}
	return tail
}
