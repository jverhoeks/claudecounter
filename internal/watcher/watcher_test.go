package watcher

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWatcher_EmitsWriteEvent(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "projA"), 0o755)

	w, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.AddTree(dir); err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(dir, "projA", "s.jsonl")
	os.WriteFile(path, []byte("hi\n"), 0o644)

	if !waitFor(w.Events(), 2*time.Second,
		func(c Change) bool { return c.Path == path }) {
		t.Fatal("expected change for new file")
	}
}

func TestWatcher_PicksUpNewSubdir(t *testing.T) {
	dir := t.TempDir()
	w, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.AddTree(dir); err != nil {
		t.Fatal(err)
	}

	newSub := filepath.Join(dir, "projNew")
	os.MkdirAll(newSub, 0o755)

	time.Sleep(200 * time.Millisecond)

	path := filepath.Join(newSub, "s.jsonl")
	os.WriteFile(path, []byte("hi\n"), 0o644)

	if !waitFor(w.Events(), 2*time.Second,
		func(c Change) bool { return c.Path == path }) {
		t.Fatal("expected change for file in newly-created subdir")
	}
}

func waitFor(ch <-chan Change, d time.Duration, pred func(Change) bool) bool {
	deadline := time.After(d)
	for {
		select {
		case c := <-ch:
			if pred(c) {
				return true
			}
		case <-deadline:
			return false
		}
	}
}
