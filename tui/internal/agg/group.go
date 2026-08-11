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
