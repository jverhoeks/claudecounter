package main

import (
	"testing"
	"time"
)

func TestScanCutoff(t *testing.T) {
	loc := time.UTC
	cases := []struct {
		name string
		now  time.Time
		want time.Time // expected cutoff
	}{
		{
			// Mid-month: now-35d is well before first-of-month, so the
			// rolling 35-day window wins (gives us a wider scan).
			name: "mid-month rolling window wins",
			now:  time.Date(2026, 4, 26, 12, 0, 0, 0, loc),
			want: time.Date(2026, 4, 26, 12, 0, 0, 0, loc).AddDate(0, 0, -35),
		},
		{
			// Just past midnight on the 1st: now-35d is March 27, well
			// before May 1, so the rolling window wins. This is the
			// edge case the cutoff is designed to handle: April 30
			// events shouldn't disappear at 00:01 on May 1.
			name: "first-of-month edge case",
			now:  time.Date(2026, 5, 1, 0, 1, 0, 0, loc),
			want: time.Date(2026, 5, 1, 0, 1, 0, 0, loc).AddDate(0, 0, -35),
		},
		{
			// Hypothetical: late in a 31-day month, firstOfMonth and
			// now-35d are very close. We always take whichever is
			// earlier (more inclusive), which is the rolling one.
			name: "near month-end picks earlier of the two",
			now:  time.Date(2026, 5, 31, 23, 0, 0, 0, loc),
			want: time.Date(2026, 5, 31, 23, 0, 0, 0, loc).AddDate(0, 0, -35),
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := scanCutoff(c.now)
			if !got.Equal(c.want) {
				t.Errorf("scanCutoff(%v) = %v, want %v", c.now, got, c.want)
			}
			// Invariant: cutoff must always be at or before
			// start-of-current-month, so we never miss a current-month event.
			fom := firstOfMonth(c.now)
			if got.After(fom) {
				t.Errorf("cutoff %v is after firstOfMonth %v — would skip current-month files", got, fom)
			}
			// And must always include the last 35 days of activity.
			if c.now.Sub(got) < 35*24*time.Hour {
				t.Errorf("cutoff %v is less than 35d ago from %v", got, c.now)
			}
		})
	}
}
