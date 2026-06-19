package main

import (
	"testing"
	"time"
)

func TestWindowStart(t *testing.T) {
	now := time.Date(2026, 6, 19, 12, 0, 0, 0, time.UTC)
	if got := windowStart(now, 7); !got.Equal(now.AddDate(0, 0, -7)) {
		t.Errorf("days=7 => %v", got)
	}
	if got := windowStart(now, 0); !got.IsZero() {
		t.Errorf("days=0 should be zero time, got %v", got)
	}
	if got := windowStart(now, -1); !got.IsZero() {
		t.Errorf("days<0 should be zero time, got %v", got)
	}
}
