package main

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/jverhoeks/claudecounter/tui/internal/phases"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/ui"
)

func pctOf(part, total float64) float64 {
	if total == 0 {
		return 0
	}
	return 100 * part / total
}

func runPhases(root string, table pricing.Table) {
	fmt.Fprintf(os.Stderr, "scanning %s …\n", root)

	rep, err := phases.Scan(root, table)
	if err != nil {
		fmt.Fprintf(os.Stderr, "phases scan: %v\n", err)
		os.Exit(1)
	}

	sep := strings.Repeat("─", 66)
	fmt.Printf("%s %d  ·  total %s  ·  main %s  ·  subagents %s\n",
		rep.Month, rep.Year,
		ui.FormatUSD(rep.Total),
		ui.FormatUSD(rep.MainUSD),
		ui.FormatUSD(rep.SubUSD))

	// ── by phase (subagents) ───────────────────────────────────────────────
	fmt.Println(sep)
	fmt.Println("By phase (subagents):")
	type kv struct {
		k string
		c *phases.Cell
	}
	var phaseRows []kv
	inOrder := map[string]bool{}
	for _, ph := range phases.PhaseOrder {
		inOrder[ph] = true
		if c, ok := rep.ByPhase[ph]; ok {
			phaseRows = append(phaseRows, kv{ph, c})
		}
	}
	for ph, c := range rep.ByPhase {
		if !inOrder[ph] {
			phaseRows = append(phaseRows, kv{ph, c})
		}
	}
	var phaseTotal float64
	for _, r := range phaseRows {
		phaseTotal += r.c.USD
		if r.c.Count == 0 {
			// orchestration: no per-agent breakdown
			fmt.Printf("  %-16s  %9s   (main sessions)\n", r.k, ui.FormatUSD(r.c.USD))
		} else {
			fmt.Printf("  %-16s  %9s   %4d agents   %7s/agent\n",
				r.k, ui.FormatUSD(r.c.USD), r.c.Count, ui.FormatUSD(r.c.USD/float64(r.c.Count)))
		}
	}
	fmt.Printf("  %-16s  %9s\n", "total", ui.FormatUSD(phaseTotal))

	// ── by spawn depth ────────────────────────────────────────────────────
	fmt.Println(sep)
	fmt.Println("By spawn depth (subagents):")
	type depthRow struct {
		key string
		c   *phases.Cell
	}
	var depthRows []depthRow
	for k, c := range rep.ByDepth {
		depthRows = append(depthRows, depthRow{k, c})
	}
	sort.Slice(depthRows, func(i, j int) bool { return depthRows[i].key < depthRows[j].key })
	depthLabel := map[string]string{
		"0": "top-level (Task tool or Workflow)",
		"1": "spawned from within a subagent",
	}
	for _, r := range depthRows {
		label := depthLabel[r.key]
		if label == "" {
			label = "nested depth " + r.key
		}
		fmt.Printf("  depth %-2s  %9s   %4d agents   %7s/agent   %s\n",
			r.key, ui.FormatUSD(r.c.USD), r.c.Count,
			ui.FormatUSD(r.c.USD/float64(r.c.Count)), label)
	}

	// ── by project (subagents) ────────────────────────────────────────────
	fmt.Println(sep)
	fmt.Println("By project (subagents):")
	type projRow struct {
		proj string
		c    *phases.Cell
	}
	var projRows []projRow
	for p, c := range rep.ByProj {
		projRows = append(projRows, projRow{p, c})
	}
	sort.Slice(projRows, func(i, j int) bool {
		return projRows[i].c.USD > projRows[j].c.USD
	})
	for _, pr := range projRows {
		fmt.Printf("  %-40s  %9s   %4d agents   %7s/agent\n",
			trimRight(shortProject(pr.proj), 40),
			ui.FormatUSD(pr.c.USD), pr.c.Count,
			ui.FormatUSD(pr.c.USD/float64(pr.c.Count)))
		// phases for this project, sorted by USD desc
		type ppRow struct {
			phase string
			c     *phases.Cell
		}
		var ppRows []ppRow
		for _, ph := range phases.PhaseOrder {
			k := phases.ProjPhaseKey{Project: pr.proj, Phase: ph}
			if c, ok := rep.ByProjPhase[k]; ok {
				ppRows = append(ppRows, ppRow{ph, c})
			}
		}
		sort.Slice(ppRows, func(i, j int) bool {
			return ppRows[i].c.USD > ppRows[j].c.USD
		})
		for _, pp := range ppRows {
			fmt.Printf("    %-14s  %9s   %4d agents   %7s/agent\n",
				pp.phase, ui.FormatUSD(pp.c.USD), pp.c.Count,
				ui.FormatUSD(pp.c.USD/float64(pp.c.Count)))
		}
	}

	// ── by language (subagents) ───────────────────────────────────────────
	if len(rep.ByLang) > 0 {
		fmt.Println(sep)
		fmt.Println("By language (subagents):")
		type langRow struct {
			lang string
			c    *phases.Cell
		}
		var langRows []langRow
		inLangOrder := map[string]bool{}
		for _, l := range phases.LangOrder {
			inLangOrder[l] = true
			if c, ok := rep.ByLang[l]; ok {
				langRows = append(langRows, langRow{l, c})
			}
		}
		for l, c := range rep.ByLang {
			if !inLangOrder[l] {
				langRows = append(langRows, langRow{l, c})
			}
		}
		for _, r := range langRows {
			fmt.Printf("  %-14s  %9s   %4d agents   %7s/agent\n",
				r.lang, ui.FormatUSD(r.c.USD), r.c.Count,
				ui.FormatUSD(r.c.USD/float64(r.c.Count)))
		}
	}

	// ── phase × lang × tier (subagents, top 25) ───────────────────────────
	fmt.Println(sep)
	fmt.Println("By phase × language × tier (subagents, top 25):")
	type keyRow struct {
		k phases.Key
		c *phases.Cell
	}
	var keyRows []keyRow
	for k, c := range rep.ByKey {
		keyRows = append(keyRows, keyRow{k, c})
	}
	sort.Slice(keyRows, func(i, j int) bool {
		if keyRows[i].c.USD != keyRows[j].c.USD {
			return keyRows[i].c.USD > keyRows[j].c.USD
		}
		a, b := keyRows[i].k, keyRows[j].k
		if a.Phase != b.Phase {
			return a.Phase < b.Phase
		}
		if a.Lang != b.Lang {
			return a.Lang < b.Lang
		}
		return a.Tier < b.Tier
	})
	limit := 25
	for i, r := range keyRows {
		if i >= limit {
			fmt.Printf("  … %d more rows\n", len(keyRows)-limit)
			break
		}
		label := fmt.Sprintf("%s / %s / %s", r.k.Phase, r.k.Lang, r.k.Tier)
		fmt.Printf("  %-38s  %9s   %4d agents   %7s/agent\n",
			label, ui.FormatUSD(r.c.USD), r.c.Count,
			ui.FormatUSD(r.c.USD/float64(r.c.Count)))
	}

	// ── orchestration deep-dive ───────────────────────────────────────────
	fmt.Println(sep)
	bd := rep.MainBreakdown
	total := bd.Total()
	fmt.Println("Orchestration (main sessions) — token cost breakdown:")
	fmt.Printf("  cache-read    %9s  %4.0f%%  ← long context re-reads\n",
		ui.FormatUSD(bd.CacheRead), pctOf(bd.CacheRead, total))
	fmt.Printf("  output        %9s  %4.0f%%\n", ui.FormatUSD(bd.Output), pctOf(bd.Output, total))
	fmt.Printf("  cache-write   %9s  %4.0f%%\n", ui.FormatUSD(bd.CacheWrite), pctOf(bd.CacheWrite, total))
	fmt.Printf("  input         %9s  %4.0f%%\n", ui.FormatUSD(bd.Input), pctOf(bd.Input, total))
	if pctOf(bd.CacheRead, total) >= 30 {
		fmt.Println("  ⚠  cache-read ≥30% — sessions are accumulating large contexts")
		fmt.Println("     consider breaking long sessions into shorter focused ones")
	}

	fmt.Println()
	fmt.Println("  By project:")
	type mainProjRow struct {
		proj string
		c    *phases.Cell
	}
	var mainProjRows []mainProjRow
	for p, c := range rep.MainByProj {
		mainProjRows = append(mainProjRows, mainProjRow{p, c})
	}
	sort.Slice(mainProjRows, func(i, j int) bool {
		return mainProjRows[i].c.USD > mainProjRows[j].c.USD
	})
	tierOrder := []string{"fable-5", "opus", "sonnet", "haiku", "other"}
	for _, pr := range mainProjRows {
		fmt.Printf("  %-40s  %9s   %4d sessions\n",
			trimRight(shortProject(pr.proj), 40),
			ui.FormatUSD(pr.c.USD), pr.c.Count)
		for _, tier := range tierOrder {
			k := phases.ProjModelKey{Project: pr.proj, Tier: tier}
			if c, ok := rep.MainByProjModel[k]; ok {
				fmt.Printf("    %-12s  %9s\n", tier, ui.FormatUSD(c.USD))
			}
		}
	}

	fmt.Println(sep)
	fmt.Println("Top 20 most expensive main sessions:")
	limit = 20
	if len(rep.TopSessions) < limit {
		limit = len(rep.TopSessions)
	}
	for _, s := range rep.TopSessions[:limit] {
		tiers := ""
		for _, tier := range tierOrder {
			if v, ok := s.ByTier[tier]; ok && v > 0 {
				tiers += fmt.Sprintf(" %s:%s", tier, ui.FormatUSD(v))
			}
		}
		crPct := pctOf(s.Breakdown.CacheRead, s.USD)
		crFlag := ""
		if crPct >= 40 {
			crFlag = fmt.Sprintf(" cr:%s(%.0f%%)", ui.FormatUSD(s.Breakdown.CacheRead), crPct)
		}
		rsp := ""
		if s.Responses > 0 {
			rsp = fmt.Sprintf(" %drsp", s.Responses)
		}
		fmt.Printf("  %9s  %-34s  %s%s  %s%s\n",
			ui.FormatUSD(s.USD),
			trimRight(shortProject(s.Project), 34),
			s.Start.Local().Format("01-02 15:04"),
			rsp,
			strings.TrimSpace(tiers),
			crFlag)
	}

	// ── top 20 most expensive individual agents ────────────────────────────
	fmt.Println(sep)
	fmt.Println("Top 20 most expensive subagents:")
	limit = 20
	if len(rep.TopAgents) < limit {
		limit = len(rep.TopAgents)
	}
	for _, a := range rep.TopAgents[:limit] {
		label := fmt.Sprintf("[%s/%s/%s]", a.Phase, a.Lang, a.Tier)
		fmt.Printf("  %9s  %-22s  %s\n",
			ui.FormatUSD(a.USD),
			label,
			trimRight(a.Description, 60))
	}
	fmt.Println(sep)
}
