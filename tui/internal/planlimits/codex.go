package planlimits

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// codexScanMaxAge bounds the walk. The longest window Codex reports is
// 7 days, so an observation older than this cannot describe a live
// window and is not worth reading.
const codexScanMaxAge = 8 * 24 * time.Hour

// codexScanMaxFiles caps the walk on very large corpora. Files are
// visited newest-first, so the cap only ever drops observations that
// are older than ones already found.
const codexScanMaxFiles = 50

type codexLine struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Payload   struct {
		Type       string `json:"type"`
		RateLimits *struct {
			LimitID   string     `json:"limit_id"`
			PlanType  string     `json:"plan_type"`
			Primary   *codexSlot `json:"primary"`
			Secondary *codexSlot `json:"secondary"`
		} `json:"rate_limits"`
	} `json:"payload"`
}

type codexSlot struct {
	UsedPercent   float64 `json:"used_percent"`
	WindowMinutes int     `json:"window_minutes"`
	ResetsAt      int64   `json:"resets_at"`
}

// ScanCodex returns the most recent utilisation observation for each
// window Codex reports.
//
// The slot names are NOT stable across Codex CLI versions: older builds
// put the 5-hour window in `primary` and the weekly in `secondary`;
// newer ones put the weekly in `primary` and omit the 5-hour window
// entirely. `limit_id` varies too ("codex", "premium"). Keying on
// window_minutes is therefore the only reliable identity.
//
// A missing or unreadable root is not an error — these are optional
// inputs and their absence simply means no rows.
func ScanCodex(root string, now time.Time) ([]Gauge, error) {
	if root == "" {
		return nil, nil
	}
	files, err := codexFiles(root)
	if err != nil || len(files) == 0 {
		return nil, nil
	}

	// window_minutes -> newest observation seen so far.
	best := map[int]Gauge{}
	bestAt := map[int]time.Time{}

	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			continue // unreadable file: keep scanning the rest
		}
		sc := bufio.NewScanner(fh)
		sc.Buffer(make([]byte, 0, 1024*1024), 16*1024*1024)
		for sc.Scan() {
			raw := sc.Bytes()
			// Cheap reject before the JSON parse: the vast majority of
			// lines in a session transcript carry no rate limits.
			if !strings.Contains(string(raw), `"rate_limits"`) {
				continue
			}
			var l codexLine
			if err := json.Unmarshal(raw, &l); err != nil {
				continue // malformed line: skip, partial data beats none
			}
			if l.Payload.Type != "token_count" || l.Payload.RateLimits == nil {
				continue
			}
			obs, err := time.Parse(time.RFC3339, l.Timestamp)
			if err != nil {
				continue
			}
			rl := l.Payload.RateLimits
			for _, slot := range []*codexSlot{rl.Primary, rl.Secondary} {
				if slot == nil || slot.WindowMinutes <= 0 {
					continue
				}
				if prev, ok := bestAt[slot.WindowMinutes]; ok && !obs.After(prev) {
					continue
				}
				resets := time.Unix(slot.ResetsAt, 0)
				bestAt[slot.WindowMinutes] = obs
				best[slot.WindowMinutes] = Gauge{
					Vendor:    "codex",
					WindowLbl: WindowLabel(slot.WindowMinutes),
					Pct:       slot.UsedPercent,
					ResetsAt:  resets,
					Observed:  obs,
					Stale:     resets.Before(now),
					Plan:      rl.PlanType,
				}
			}
		}
		fh.Close()
	}

	mins := make([]int, 0, len(best))
	for m := range best {
		mins = append(mins, m)
	}
	sort.Ints(mins) // shortest window first, so 5h precedes 7d
	out := make([]Gauge, 0, len(mins))
	for _, m := range mins {
		out = append(out, best[m])
	}
	return out, nil
}

// codexFiles lists session transcripts newest-first, dropping anything
// older than the longest window Codex reports.
//
// The age cutoff is anchored to the newest file's own mtime rather than
// to wall-clock time: ScanCodex's `now` parameter is a caller-supplied
// evaluation reference used only to decide whether a window has closed,
// and tests legitimately pass a synthetic value far from the present to
// exercise that without changing which files on disk count as recent.
func codexFiles(root string) ([]string, error) {
	type entry struct {
		path string
		mod  time.Time
	}
	var entries []entry

	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable subtree: skip it, keep walking
		}
		if d.IsDir() || !strings.HasSuffix(p, ".jsonl") {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		entries = append(entries, entry{p, info.ModTime()})
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, nil
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].mod.After(entries[j].mod) })

	cutoff := entries[0].mod.Add(-codexScanMaxAge)
	trimmed := entries[:0]
	for _, e := range entries {
		if e.mod.Before(cutoff) {
			continue
		}
		trimmed = append(trimmed, e)
	}
	entries = trimmed
	if len(entries) > codexScanMaxFiles {
		entries = entries[:codexScanMaxFiles]
	}
	out := make([]string, len(entries))
	for i, e := range entries {
		out[i] = e.path
	}
	return out, nil
}
