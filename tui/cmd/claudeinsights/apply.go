package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

// applyResult is the outcome of merging candidates into one project's CLAUDE.md.
type applyResult struct {
	Project string
	Path    string
	Diff    string
	Wrote   bool
	Skipped bool
	Note    string
}

// projectCwd finds the real working directory for a project from its session
// reports (first non-empty Cwd).
func projectCwd(c insights.CorpusReport, project string) string {
	for _, s := range c.Sessions {
		if s.Project == project && s.Cwd != "" {
			return s.Cwd
		}
	}
	return ""
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// atomicWrite writes content to path via a temp file in the same dir + rename,
// so a failure never leaves a partially-written CLAUDE.md.
func atomicWrite(path, content string) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".claudemd-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

// applyClaudeMd merges each flagged project's mined candidates into its
// <cwd>/CLAUDE.md. Dry-run (doWrite=false) only computes diffs; doWrite writes
// atomically. Projects whose cwd is gone, or with no candidates, are skipped.
func applyClaudeMd(c insights.CorpusReport, mined []insights.ProjectMined,
	j insights.Judge, doWrite bool) []applyResult {

	ctx := context.Background()
	var out []applyResult
	for _, m := range mined {
		res := applyResult{Project: m.Project}
		if !m.Available || len(m.Candidates) == 0 {
			res.Skipped, res.Note = true, "no candidates"
			out = append(out, res)
			continue
		}
		cwd := projectCwd(c, m.Project)
		if cwd == "" || !isDir(cwd) {
			res.Skipped, res.Note = true, "project dir not found locally"
			out = append(out, res)
			continue
		}
		res.Path = filepath.Join(cwd, "CLAUDE.md")

		existing := ""
		if b, err := os.ReadFile(res.Path); err == nil {
			existing = string(b)
		}
		fmt.Fprintf(os.Stderr, "  apply merge %s …\n", shortProj(m.Project))
		merged, _, err := insights.MergeClaudeMd(ctx, j, existing, m.Candidates)
		if err != nil {
			res.Skipped, res.Note = true, "merge failed: "+err.Error()
			out = append(out, res)
			continue
		}
		if merged == "" || merged == existing {
			res.Skipped, res.Note = true, "no changes"
			out = append(out, res)
			continue
		}
		res.Diff = insights.UnifiedDiff(existing, merged, res.Path)
		if doWrite {
			if err := atomicWrite(res.Path, merged); err != nil {
				res.Skipped, res.Note = true, "write failed: "+err.Error()
			} else {
				res.Wrote = true
			}
		}
		out = append(out, res)
	}
	return out
}

// writeApply renders the apply results: diffs in dry-run, confirmations on write.
func writeApply(w io.Writer, results []applyResult, doWrite bool) {
	mode := "DRY-RUN (no files changed; pass --write to apply)"
	if doWrite {
		mode = "WRITE"
	}
	fmt.Fprintf(w, "\n══ Apply to CLAUDE.md — %s ══\n", mode)
	for _, r := range results {
		if r.Skipped {
			fmt.Fprintf(w, "\n%s — skipped (%s)\n", shortProj(r.Project), r.Note)
			continue
		}
		if r.Wrote {
			fmt.Fprintf(w, "\n%s — wrote %s\n", shortProj(r.Project), r.Path)
		} else {
			fmt.Fprintf(w, "\n%s — would update %s:\n", shortProj(r.Project), r.Path)
		}
		fmt.Fprint(w, r.Diff)
	}
}
