// Package safety aggregates permission-mode usage across the transcript
// corpus: which projects ran turns under bypassPermissions ("dangerous
// mode"), how often, and whether those sessions look like they ran inside a
// container. Like the ROI report, it scans on demand and never touches the
// live counting path.
package safety

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

// ModeOrder is the display order of permission-mode columns.
var ModeOrder = []string{"default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"}

// SessionInfo is the per-session result of a Scan: one main transcript's
// prompt-turn modes plus the context needed for grouping and heuristics.
type SessionInfo struct {
	Project    string // encoded project key (dir segment under projects/)
	Cwd        string
	Entrypoint string
	ModeTurns  map[string]int
}

// Row is one project's aggregated mode usage.
type Row struct {
	Project           string
	Turns             int
	Sessions          int
	ModeTurns         map[string]int
	BypassTurns       int
	BypassPct         float64
	ContainerSessions int // sessions whose cwd looks container-like
	Entrypoints       []string
}

// Summary is the headline across all rows.
type Summary struct {
	TotalTurns        int
	BypassTurns       int
	BypassPct         float64
	BypassProjects    int
	ContainerSessions int // container-likely sessions that used bypass
}

// LikelyContainer reports whether cwd looks like it belongs to a container
// rather than the host. Heuristic only — there is no hard signal in the
// transcripts: a cwd sharing the host home dir's parent (e.g. /Users on
// macOS) is treated as host; anything else (/workspace, /app, /root,
// /home/* on a darwin host, …) is container-likely. Empty cwd is never
// flagged.
func LikelyContainer(cwd, home string) bool {
	if cwd == "" || home == "" {
		return false
	}
	parent := filepath.Dir(home) // e.g. /Users
	if cwd == home || strings.HasPrefix(cwd, home+"/") || strings.HasPrefix(cwd, parent+"/") {
		return false
	}
	// Temp dirs are host convention too — macOS $TMPDIR lives under
	// /var/folders and /tmp resolves to /private/tmp.
	for _, p := range []string{"/tmp", "/private", "/var/folders"} {
		if cwd == p || strings.HasPrefix(cwd, p+"/") {
			return false
		}
	}
	return true
}

// Build groups sessions by project and computes per-project rows plus the
// headline summary. Rows are sorted by bypass share (desc), then turn
// volume, so the riskiest projects surface first.
func Build(sessions []SessionInfo, home string) ([]Row, Summary) {
	byProj := map[string]*Row{}
	entry := map[string]map[string]struct{}{}
	var sum Summary

	for _, s := range sessions {
		r := byProj[s.Project]
		if r == nil {
			r = &Row{Project: s.Project, ModeTurns: map[string]int{}}
			byProj[s.Project] = r
			entry[s.Project] = map[string]struct{}{}
		}
		r.Sessions++
		container := LikelyContainer(s.Cwd, home)
		if container {
			r.ContainerSessions++
		}
		if s.Entrypoint != "" {
			entry[s.Project][s.Entrypoint] = struct{}{}
		}
		for mode, n := range s.ModeTurns {
			r.ModeTurns[mode] += n
			r.Turns += n
			sum.TotalTurns += n
			if mode == "bypassPermissions" {
				r.BypassTurns += n
				sum.BypassTurns += n
				if container {
					sum.ContainerSessions++
					container = false // count each session once
				}
			}
		}
	}

	rows := make([]Row, 0, len(byProj))
	for proj, r := range byProj {
		if r.Turns > 0 {
			r.BypassPct = 100 * float64(r.BypassTurns) / float64(r.Turns)
		}
		if r.BypassTurns > 0 {
			sum.BypassProjects++
		}
		for e := range entry[proj] {
			r.Entrypoints = append(r.Entrypoints, e)
		}
		sort.Strings(r.Entrypoints)
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].BypassPct != rows[j].BypassPct {
			return rows[i].BypassPct > rows[j].BypassPct
		}
		if rows[i].Turns != rows[j].Turns {
			return rows[i].Turns > rows[j].Turns
		}
		return rows[i].Project < rows[j].Project
	})
	if sum.TotalTurns > 0 {
		sum.BypassPct = 100 * float64(sum.BypassTurns) / float64(sum.TotalTurns)
	}
	return rows, sum
}

// rawLine mirrors only the fields the safety scan reads.
type rawLine struct {
	Type           string    `json:"type"`
	Timestamp      time.Time `json:"timestamp"`
	Cwd            string    `json:"cwd"`
	Entrypoint     string    `json:"entrypoint"`
	PermissionMode string    `json:"permissionMode"`
}

// scanFile extracts one SessionInfo from a main transcript. Turns outside
// the window are dropped; a session with no in-window turns returns ok=false.
func scanFile(path, project string, notBefore time.Time) (SessionInfo, bool) {
	f, err := os.Open(path)
	if err != nil {
		return SessionInfo{}, false
	}
	defer f.Close()

	info := SessionInfo{Project: project, ModeTurns: map[string]int{}}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var r rawLine
		if err := json.Unmarshal(line, &r); err != nil {
			continue
		}
		if info.Cwd == "" && r.Cwd != "" {
			info.Cwd = r.Cwd
		}
		if info.Entrypoint == "" && r.Entrypoint != "" {
			info.Entrypoint = r.Entrypoint
		}
		if r.Type != "user" || r.PermissionMode == "" || r.Timestamp.Before(notBefore) {
			continue
		}
		info.ModeTurns[r.PermissionMode]++
	}
	if len(info.ModeTurns) == 0 {
		return SessionInfo{}, false
	}
	return info, true
}

// Scan walks root for main session transcripts (subagent files are skipped —
// their prompts are machine-generated by the Task tool) modified at or after
// notBefore, and extracts each session's mode turns. Files are read in
// parallel, mirroring reader.InitialScan's worker pool.
func Scan(root string, notBefore time.Time) ([]SessionInfo, error) {
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
	var out []SessionInfo
	var wg sync.WaitGroup
	wg.Add(workers)
	for i := 0; i < workers; i++ {
		go func() {
			defer wg.Done()
			for p := range paths {
				if info, ok := scanFile(p, projectUnder(root, p), notBefore); ok {
					mu.Lock()
					out = append(out, info)
					mu.Unlock()
				}
			}
		}()
	}
	wg.Wait()
	return out, <-walkErr
}

// projectUnder returns the encoded project key: the path segment directly
// under root (the projects dir). Same meaning as the reader's project key,
// but derived from root so it also works on non-standard --root locations.
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
