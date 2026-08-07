package limits

import (
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// Window is the period a Status covers.
type Window int

const (
	WindowDay Window = iota
	WindowWeek
)

// String is the DISPLAY label, rendered in the gauge rows.
func (w Window) String() string {
	if w == WindowWeek {
		return "wk"
	}
	return "daily"
}

// Key is the stable IDENTITY of the window, independent of how it is
// displayed. The cross-language parity fixture compares Key, not String:
// if the two were the same value, someone retuning a display label would
// silently keep the parity test green while changing what users see.
func (w Window) Key() string {
	if w == WindowWeek {
		return "week"
	}
	return "day"
}

// State is how a window's spend compares to its limit.
type State int

const (
	StateUnset State = iota // no limit configured for this window
	StateOK
	StateWarn
	StateOver
)

func (s State) String() string {
	switch s {
	case StateOK:
		return "ok"
	case StateWarn:
		return "warn"
	case StateOver:
		return "over"
	default:
		return "unset"
	}
}

// Status is one window's evaluation. Pct is 0 when State is Unset —
// a percentage of an unconfigured limit is meaningless, not zero.
type Status struct {
	Window   Window
	SpentUSD float64
	LimitUSD float64
	Pct      float64
	State    State
	ResetsAt time.Time
}

// Evaluate reports spend against the configured limits. It is pure: no
// clock, no filesystem, no aggregator state — everything it needs is an
// argument, which is what makes the window boundaries directly testable.
//
// It always returns exactly two entries, WindowDay first, so callers can
// index without checking length.
func Evaluate(daily []agg.DailyTotal, cfg Config, now time.Time) []Status {
	lt := now.Local()
	todayKey := lt.Format("2006-01-02")
	nowYear, nowWeek := lt.ISOWeek()

	var daySpent, weekSpent float64
	for _, d := range daily {
		if d.Day == todayKey {
			daySpent += d.USD
		}
		t, err := time.ParseInLocation("2006-01-02", d.Day, time.Local)
		if err != nil {
			continue // unparseable day key: skip, never fail the whole gauge
		}
		// ISO week, not calendar week: the ISO year can differ from the
		// calendar year around New Year, and comparing both fields is
		// what keeps a week that straddles 31 Dec in one bucket.
		if y, w := t.ISOWeek(); y == nowYear && w == nowWeek {
			weekSpent += d.USD
		}
	}

	return []Status{
		build(WindowDay, daySpent, cfg.Daily, cfg.WarnPct, nextMidnight(lt)),
		build(WindowWeek, weekSpent, cfg.Weekly, cfg.WarnPct, nextMonday(lt)),
	}
}

func build(w Window, spent, limit float64, warnPct int, resets time.Time) Status {
	st := Status{Window: w, SpentUSD: spent, LimitUSD: limit, ResetsAt: resets}
	if limit <= 0 {
		st.State = StateUnset
		return st
	}
	st.Pct = 100 * spent / limit
	switch {
	case st.Pct >= 100:
		st.State = StateOver
	case st.Pct >= float64(warnPct):
		st.State = StateWarn
	default:
		st.State = StateOK
	}
	return st
}

func nextMidnight(lt time.Time) time.Time {
	return time.Date(lt.Year(), lt.Month(), lt.Day(), 0, 0, 0, 0, lt.Location()).AddDate(0, 0, 1)
}

// nextMonday returns the start of the next ISO week. Go's Weekday has
// Sunday at 0, so Sunday needs 1 day and every other day needs
// 8-weekday days to reach the following Monday.
func nextMonday(lt time.Time) time.Time {
	midnight := time.Date(lt.Year(), lt.Month(), lt.Day(), 0, 0, 0, 0, lt.Location())
	delta := (8 - int(lt.Weekday())) % 7
	if delta == 0 {
		delta = 7
	}
	return midnight.AddDate(0, 0, delta)
}
