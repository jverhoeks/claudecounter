package watcher

import (
	"os"
	"path/filepath"

	"github.com/fsnotify/fsnotify"
)

type ChangeKind int

const (
	Create ChangeKind = iota
	Write
	Remove
)

type Change struct {
	Path string
	Kind ChangeKind
}

type Watcher struct {
	fs  *fsnotify.Watcher
	out chan Change
}

func New() (*Watcher, error) {
	fs, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	w := &Watcher{fs: fs, out: make(chan Change, 256)}
	go w.loop()
	return w, nil
}

func (w *Watcher) Events() <-chan Change { return w.out }

func (w *Watcher) Close() error { return w.fs.Close() }

// AddTree watches root and every directory beneath it (recursively).
// Recursion is necessary because subagent transcripts live nested at
// <root>/<project>/<session-uuid>/subagents/, two levels deeper than
// regular session jsonls. New subdirs created at any level are picked
// up by handle() on Create events.
func (w *Watcher) AddTree(root string) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			_ = w.fs.Add(path)
		}
		return nil
	})
}

func (w *Watcher) loop() {
	for {
		select {
		case ev, ok := <-w.fs.Events:
			if !ok {
				close(w.out)
				return
			}
			w.handle(ev)
		case _, ok := <-w.fs.Errors:
			if !ok {
				return
			}
		}
	}
}

func (w *Watcher) handle(ev fsnotify.Event) {
	if ev.Op&fsnotify.Create != 0 {
		if info, err := os.Stat(ev.Name); err == nil && info.IsDir() {
			_ = w.fs.Add(ev.Name)
			return
		}
	}

	if filepath.Ext(ev.Name) != ".jsonl" {
		return
	}

	switch {
	case ev.Op&fsnotify.Create != 0:
		w.out <- Change{Path: ev.Name, Kind: Create}
	case ev.Op&fsnotify.Write != 0:
		w.out <- Change{Path: ev.Name, Kind: Write}
	case ev.Op&(fsnotify.Remove|fsnotify.Rename) != 0:
		w.out <- Change{Path: ev.Name, Kind: Remove}
	}
}
