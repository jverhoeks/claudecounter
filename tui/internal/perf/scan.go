package perf

import (
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

// Scan reads every Claude session file under roots modified since
// notBefore and returns their samples since notBefore, deduped and
// time-sorted. Main and subagent files repeat some requests; the first in
// walk order wins — the order the spend reader dedupes in. WalkDir's
// lexical order puts a session's "<uuid>" directory (its subagents)
// before its "<uuid>.jsonl", as the macapp's walk does.
//
// progress, if non-nil, is called with (done, total) as files finish.
func Scan(roots []string, notBefore time.Time, progress func(done, total int)) []Sample {
	var paths []string
	for _, root := range roots {
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() || !strings.HasSuffix(d.Name(), ".jsonl") {
				return nil
			}
			if info, err := d.Info(); err == nil && !info.ModTime().Before(notBefore) {
				paths = append(paths, path)
			}
			return nil
		})
	}
	total := len(paths)
	if progress != nil {
		progress(0, total)
	}

	results := make([][]Sample, total)
	workers := runtime.NumCPU()
	if workers < 2 {
		workers = 2
	}
	if workers > 8 {
		workers = 8
	}
	next := make(chan int)
	var wg sync.WaitGroup
	var mu sync.Mutex
	done := 0
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range next {
				if data, err := os.ReadFile(paths[i]); err == nil {
					results[i] = Parse(data, paths[i])
				}
				if progress != nil {
					mu.Lock()
					done++
					if done%50 == 0 || done == total {
						progress(done, total)
					}
					mu.Unlock()
				}
			}
		}()
	}
	for i := range paths {
		next <- i
	}
	close(next)
	wg.Wait()

	seen := map[string]struct{}{}
	var out []Sample
	for _, ss := range results {
		for _, s := range ss {
			if s.Time.Before(notBefore) {
				continue
			}
			if _, dup := seen[s.RequestID]; dup {
				continue
			}
			seen[s.RequestID] = struct{}{}
			out = append(out, s)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Time.Before(out[j].Time) })
	return out
}
