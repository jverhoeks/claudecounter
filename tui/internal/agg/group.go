package agg

// Mode selects how per-series totals are collapsed for display. The same
// mode drives the monthly table and the charts on both surfaces.
type Mode int

const (
	GroupModel  Mode = iota // one series per model, merged across sources
	GroupVendor             // one series per vendor — the "all Claude" view
	GroupSource             // one series per configured subscription
	GroupTotal              // a single series
)

func (m Mode) String() string {
	switch m {
	case GroupVendor:
		return "vendor"
	case GroupSource:
		return "source"
	case GroupTotal:
		return "total"
	default:
		return "model"
	}
}

// Next cycles model -> vendor -> source -> total -> model.
func (m Mode) Next() Mode {
	if m >= GroupTotal {
		return GroupModel
	}
	return m + 1
}

// label reduces a series key to its display name under a mode.
func (m Mode) label(k SeriesKey) string {
	switch m {
	case GroupVendor:
		return k.Vendor
	case GroupSource:
		return k.Source
	case GroupTotal:
		return "total"
	default:
		return k.Model
	}
}

// Group collapses per-series totals by mode. Every mode partitions the
// same input, so all four sum to the same grand total — no mode may lose
// or duplicate spend.
func Group(in map[SeriesKey]ModelDay, m Mode) map[string]ModelDay {
	out := make(map[string]ModelDay, len(in))
	for k, v := range in {
		name := m.label(k)
		cur := out[name]
		cur.USD += v.USD
		cur.Tokens = cur.Tokens.Add(v.Tokens)
		out[name] = cur
	}
	return out
}

// GroupCoverage collapses per-vendor coverage onto the same display rows
// Group produces, so the two maps always share a key set — a row without
// an entry would silently render unmarked.
//
// A row spanning several vendors takes the worst of them. Averaging, or
// weighting by spend, would let a large complete Claude figure hide a
// small partial Grok one inside the same row, which is exactly the
// failure this marker exists to prevent.
func GroupCoverage(in map[SeriesKey]ModelDay, cov map[string]Coverage, m Mode) map[string]Coverage {
	// Reported in model mode only. The marker is a caveat about one
	// model's turns — the subset of them that predate its vendor's usage
	// field — so on a rollup row it answers a question nobody asked:
	// "grok ~90%" beside a vendor total reads as doubt about the vendor
	// itself. Returning nothing here rather than gating in each view
	// keeps the TUI and the menu bar in step by construction, and keeps
	// the rule testable: the macapp's table lives in a target with no
	// test path.
	if m != GroupModel {
		return map[string]Coverage{}
	}

	out := make(map[string]Coverage, len(in))
	for k := range in {
		name := m.label(k)
		c := cov[k.Vendor]
		if cur, ok := out[name]; ok && cur.Fraction() <= c.Fraction() {
			continue
		}
		out[name] = c
	}
	return out
}
