package insights

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

// Scan walks root for main session transcripts modified at/after notBefore,
// parses + analyzes each in parallel, and returns one SessionReport per
// session. Subagent files (under /subagents/) are skipped here because
// session.Parse folds them into their main transcript.
func Scan(root string, table pricing.Table, th Thresholds, notBefore time.Time) ([]SessionReport, error) {
	paths := make(chan string, 256)
	walkErr := make(chan error, 1)
	go func() {
		walkErr <- filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if filepath.Ext(d.Name()) != ".jsonl" {
				return nil
			}
			if strings.Contains(filepath.ToSlash(path), "/subagents/") {
				return nil
			}
			info, err := d.Info()
			if err != nil || info.ModTime().Before(notBefore) {
				return nil
			}
			paths <- path
			return nil
		})
		close(paths)
	}()

	workers := runtime.NumCPU()
	if workers < 2 {
		workers = 2
	}
	if workers > 8 {
		workers = 8
	}
	var mu sync.Mutex
	var out []SessionReport
	var wg sync.WaitGroup
	wg.Add(workers)
	for i := 0; i < workers; i++ {
		go func() {
			defer wg.Done()
			for p := range paths {
				s, err := session.Parse(p)
				if err != nil {
					continue
				}
				r := AnalyzeSession(s, table, th)
				r.Project = projectUnder(root, p)
				mu.Lock()
				out = append(out, r)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	return out, <-walkErr
}

// projectUnder returns the path segment directly under root (the encoded
// project key). Same logic as safety.projectUnder, duplicated to keep the
// insights package self-contained.
func projectUnder(root, path string) string {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return ""
	}
	rel = filepath.ToSlash(rel)
	if i := strings.IndexByte(rel, '/'); i >= 0 {
		return rel[:i]
	}
	return ""
}
