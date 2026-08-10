package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
	"github.com/jverhoeks/claudecounter/tui/internal/watcher"
)

func TestEndToEnd_NewFileAndAppend(t *testing.T) {
	root := t.TempDir()
	projOld := filepath.Join(root, "old")
	projCur := filepath.Join(root, "cur")
	os.MkdirAll(projOld, 0o755)
	os.MkdirAll(projCur, 0o755)

	now := time.Now()
	nowRFC := now.UTC().Format(time.RFC3339)
	oldRFC := now.AddDate(0, -2, 0).UTC().Format(time.RFC3339)

	oldFile := filepath.Join(projOld, "a.jsonl")
	curFile := filepath.Join(projCur, "b.jsonl")
	lineOpus := func(ts string) string {
		return `{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"` + ts + `","sessionId":"s","cwd":"/x"}` + "\n"
	}
	os.WriteFile(oldFile, []byte(lineOpus(oldRFC)), 0o644)
	os.Chtimes(oldFile, now.AddDate(0, -2, 0), now.AddDate(0, -2, 0))
	os.WriteFile(curFile, []byte(lineOpus(nowRFC)), 0o644)

	table := pricing.Defaults()
	evCh := make(chan reader.Event, 64)
	r := reader.New(evCh)
	if err := r.InitialScan(root, firstOfMonth(now.Local())); err != nil {
		t.Fatal(err)
	}
	a := agg.New(table)
	for drained := true; drained; {
		select {
		case e := <-evCh:
			a.Apply(e)
		default:
			drained = false
		}
	}

	// reader.New defaults to the implicit "claude/claude" source
	// whenever InitialScan (rather than InitialScanSource) is used.
	key := agg.SeriesKey{Source: "claude/claude", Vendor: "claude", Model: "claude-opus-4-7"}

	snap := a.Snapshot()
	if snap.Day[key].USD == 0 {
		t.Fatalf("expected initial scan to count current-month opus: %+v", snap.Day)
	}
	beforeUSD := snap.Day[key].USD

	w, err := watcher.New()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.AddTree(root, time.Time{}); err != nil {
		t.Fatal(err)
	}

	go func() {
		for c := range w.Events() {
			if c.Kind == watcher.Remove {
				r.Forget(c.Path)
				continue
			}
			_ = r.OnChange(c.Path)
		}
	}()

	// Append to existing file.
	f, _ := os.OpenFile(curFile, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(lineOpus(nowRFC))
	f.Close()

	if !waitFor(t, 2*time.Second, func() bool {
		select {
		case e := <-evCh:
			a.Apply(e)
		default:
		}
		return a.Snapshot().Day[key].USD > beforeUSD
	}) {
		t.Fatal("append was not picked up")
	}
	afterAppend := a.Snapshot().Day[key].USD

	// Create a brand-new file in a new subdir.
	projNew := filepath.Join(root, "new")
	os.MkdirAll(projNew, 0o755)
	time.Sleep(200 * time.Millisecond)
	newFile := filepath.Join(projNew, "c.jsonl")
	os.WriteFile(newFile, []byte(lineOpus(nowRFC)), 0o644)

	if !waitFor(t, 2*time.Second, func() bool {
		select {
		case e := <-evCh:
			a.Apply(e)
		default:
		}
		return a.Snapshot().Day[key].USD > afterAppend
	}) {
		t.Fatal("new file in new subdir was not picked up")
	}
}

func waitFor(t *testing.T, d time.Duration, cond func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}
