package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/gitstat"
	"github.com/jverhoeks/claudecounter/tui/internal/insights"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

const deliveryMinUSD = 20.0 // only check delivery for sessions costing at least this

// gitDelivery counts commits that landed in [start,end] in the repo containing
// cwd. It backs insights.DeliveryFn; ok=false when cwd is not a git repo.
func gitDelivery(cwd string, start, end time.Time) (int, bool) {
	if cwd == "" || start.IsZero() {
		return 0, false
	}
	root, ok := gitstat.RepoRoot(cwd)
	if !ok {
		return 0, false
	}
	commits, err := gitstat.Collect(root, start.Add(-time.Minute), "")
	if err != nil {
		return 0, false
	}
	n := 0
	for _, c := range commits {
		if !c.Date.Before(start) && !c.Date.After(end.Add(time.Minute)) {
			n++
		}
	}
	return n, true
}

// runLLM scores the worst flagged sessions locally with Laya, sends only the
// rough ones to the text judge, mines CLAUDE.md candidates for those sessions'
// projects, and synthesizes a consolidated action list, honoring the cache and
// the llmMax cap. It returns the mined results so the caller can run --apply.
// Progress goes to stderr; results are rendered to w.
func runLLM(w io.Writer, root string, table pricing.Table, th insights.Thresholds,
	c insights.CorpusReport, cache *insights.Cache, refresh bool, llmMax int,
	scorer insights.Scorer, judge insights.Judge) []insights.ProjectMined {

	ctx := context.Background()

	// Flagged = worst-first sessions with at least one finding, capped.
	var flagged []insights.SessionReport
	for _, s := range c.Sessions {
		if len(s.Findings) == 0 {
			continue
		}
		flagged = append(flagged, s)
		if len(flagged) >= llmMax {
			break
		}
	}
	if len(flagged) == 0 {
		fmt.Fprintln(w, "\nLLM coaching: no flagged sessions to judge.")
		return nil
	}

	var totalCost float64
	var judgments []insights.Judgment
	var projects []string // parallel to judgments
	var misses []insights.Digest
	var missAt []int // index into judgments for each miss

	for _, sr := range flagged {
		s, err := session.Parse(filepath.Join(root, sr.Project, sr.ID+".jsonl"))
		if err != nil {
			continue
		}
		d := insights.BuildDigest(s, sr, digestMaxPrompts, digestMaxTools, digestMaxRunes)
		j, hit := insights.Judgment{}, false
		if !refresh {
			j, hit = cache.GetJudgment(insights.DigestHash(d))
		}
		if !hit {
			misses = append(misses, d)
			missAt = append(missAt, len(judgments))
		}
		judgments = append(judgments, j)
		projects = append(projects, sr.Project)
	}

	// One Laya batch for every uncached session, so the model loads once.
	if len(misses) > 0 {
		fmt.Fprintf(os.Stderr, "  laya scoring %d session(s) …\n", len(misses))
		fresh, layaErr := insights.JudgeHybrid(ctx, scorer, judge, misses)
		if layaErr != nil {
			fmt.Fprintf(os.Stderr, "  laya unavailable, judged every session with claude -p: %v\n", layaErr)
		}
		for k, j := range fresh {
			cache.PutJudgment(insights.DigestHash(misses[k]), j)
			totalCost += j.CostUSD
			judgments[missAt[k]] = j
		}
	}

	// Mine only projects where a session got the full text judgment: those
	// are the rough ones, and mining is a claude -p call per project.
	projectsToMine := map[string]struct{}{}
	for i, j := range judgments {
		if j.Advice != "" {
			projectsToMine[projects[i]] = struct{}{}
		}
	}

	// Mine CLAUDE.md candidates once per flagged project, but feed the miner
	// prompts from ALL the project's sessions (cheap prompt-only parse) — not
	// just the flagged ones — so it can actually detect cross-session recurrence.
	var mined []insights.ProjectMined
	for proj := range projectsToMine {
		fmt.Fprintf(os.Stderr, "  llm mine %s …\n", shortProj(proj))
		prompts := collectProjectPrompts(root, proj, c)
		dig := insights.Digest{ID: "mine:" + proj, Prompts: prompts}
		hash := insights.DigestHash(dig)
		m, hit := insights.ProjectMined{}, false
		if !refresh {
			m, hit = cache.GetMined(hash)
		}
		if !hit {
			m = insights.MineProject(ctx, judge, proj, []insights.Digest{dig})
			cache.PutMined(hash, m)
			totalCost += m.CostUSD
		}
		mined = append(mined, m)
	}

	// Consolidated action list: one synthesis call over the judgments, cached
	// by the judged-session set.
	var ids []string
	for _, j := range judgments {
		ids = append(ids, j.SessionID)
	}
	actHash := insights.DigestHash(insights.Digest{ID: "actions", Prompts: ids})
	actions, hit := insights.ActionList{}, false
	if !refresh {
		actions, hit = cache.GetActions(actHash)
	}
	if !hit {
		fmt.Fprintln(os.Stderr, "  llm synthesize actions …")
		actions = insights.SynthesizeActions(ctx, judge, judgments)
		cache.PutActions(actHash, actions)
		totalCost += actions.CostUSD
	}

	writeLLM(w, judgments, mined, totalCost)
	writeActions(w, actions)
	return mined
}

// writeActions renders the consolidated "Top actions" section.
func writeActions(w io.Writer, a insights.ActionList) {
	fmt.Fprintln(w, "\n══ Top actions (what to change in how you work) ══")
	if !a.Available {
		fmt.Fprintf(w, "  unavailable (%s)\n", a.Err)
		return
	}
	if len(a.Items) == 0 {
		fmt.Fprintln(w, "  (no recurring actions found)")
		return
	}
	for i, it := range a.Items {
		seen := ""
		if it.Sessions > 0 {
			seen = fmt.Sprintf(" [seen in %d session(s)]", it.Sessions)
		}
		fmt.Fprintf(w, "  %d. %s%s\n", i+1, it.Action, seen)
		if it.Why != "" {
			fmt.Fprintf(w, "       ↳ %s\n", it.Why)
		}
	}
}

// collectProjectPrompts gathers real user prompts across all of a project's
// sessions (worst-first), stopping once enough are collected to mine. This is a
// prompt-only parse — no extra LLM cost — that gives the miner a broad enough
// sample to spot instructions repeated across sessions.
func collectProjectPrompts(root, project string, c insights.CorpusReport) []string {
	const promptCap = 80
	var out []string
	for _, sr := range c.Sessions {
		if sr.Project != project {
			continue
		}
		s, err := session.Parse(filepath.Join(root, sr.Project, sr.ID+".jsonl"))
		if err != nil {
			continue
		}
		for _, p := range s.UserPrompts {
			out = append(out, p.Text)
			if len(out) >= promptCap {
				return out
			}
		}
	}
	return out
}

// writeLLM renders the Tier-2 coaching section. Pure (takes io.Writer).
func writeLLM(w io.Writer, judgments []insights.Judgment, mined []insights.ProjectMined, costUSD float64) {
	fmt.Fprintf(w, "\n══ LLM coaching (Laya local scores + claude -p on rough sessions · $%.2f this run) ══\n", costUSD)

	for _, j := range judgments {
		if !j.Available {
			fmt.Fprintf(w, "\n%s — unavailable (%s)\n", shortID(j.SessionID), j.Err)
			continue
		}
		fmt.Fprintf(w, "\n%s — friction %d/10 · first-prompt clarity %d/10",
			shortID(j.SessionID), j.Friction, j.PromptSpecificity)
		if j.Laya != nil {
			fmt.Fprintf(w, " · p(correction) %.2f · p(loop) %.2f", j.Laya.PCorrection, j.Laya.PLoop)
		}
		fmt.Fprintln(w)
		if j.Laya != nil && j.Advice == "" {
			fmt.Fprintln(w, "  (scored locally; below the threshold for a text judgment)")
		}
		if j.RootCause != "" {
			fmt.Fprintf(w, "  root cause: %s\n", j.RootCause)
		}
		for _, c := range j.Corrections {
			fmt.Fprintf(w, "  ✗ %s — %s\n", trimRunes(c.Quote, 60), c.Issue)
		}
		for _, l := range j.Loops {
			fmt.Fprintf(w, "  ↻ %s\n", l)
		}
		if j.Advice != "" {
			fmt.Fprintf(w, "  → %s\n", j.Advice)
		}
	}

	fmt.Fprintln(w, "\nCLAUDE.md / memory candidates:")
	any := false
	for _, m := range mined {
		if !m.Available || len(m.Candidates) == 0 {
			continue
		}
		fmt.Fprintf(w, "  [%s]\n", shortProj(m.Project))
		for _, cand := range m.Candidates {
			fmt.Fprintf(w, "    • %s  (%s)\n", cand.Suggestion, cand.Evidence)
			any = true
		}
	}
	if !any {
		fmt.Fprintln(w, "  (none found)")
	}
}
