package main

import (
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func defaultPricingPath() string {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "claudecounter", "pricing.toml")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "claudecounter", "pricing.toml")
}

func defaultRoot() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "projects")
}

// windowStart returns the mtime cutoff for "last N days". Non-positive days
// means no lower bound (scan everything).
func windowStart(now time.Time, days int) time.Time {
	if days <= 0 {
		return time.Time{}
	}
	return now.AddDate(0, 0, -days)
}

func loadPricing(path string) pricing.Table {
	if t, err := pricing.Load(path); err == nil && len(t.Models) > 0 {
		return t
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
		log.Printf("pricing: %s unreadable (%v); using defaults", path, err)
	}
	return pricing.Defaults()
}

func main() {
	root := flag.String("root", defaultRoot(), "claude projects root")
	pricingPath := flag.String("pricing", defaultPricingPath(), "path to pricing.toml")
	days := flag.Int("days", 90, "analysis window in days")
	sessionFlag := flag.String("session", "", "drill into one session (id prefix; default: corpus mode)")
	jsonFlag := flag.Bool("json", false, "emit JSON")
	csvFlag := flag.Bool("csv", false, "emit CSV (one row per finding)")
	digestFlag := flag.Bool("digest", false, "with --session: print the session's compact JSON digest")
	topN := flag.Int("top", 15, "how many worst sessions to list in corpus mode")
	noCache := flag.Bool("no-cache", false, "ignore and do not write the on-disk cache")
	refresh := flag.Bool("refresh", false, "recompute and overwrite cache entries")
	llm := flag.Bool("llm", false, "run the local claude -p coaching pass on flagged sessions (costs ~$0.10/session)")
	llmMax := flag.Int("llm-max", 10, "max sessions to send to the LLM judge")
	apply := flag.Bool("apply", false, "merge mined CLAUDE.md candidates into each project's CLAUDE.md (implies --llm; dry-run unless --write)")
	write := flag.Bool("write", false, "with --apply: actually write the merged CLAUDE.md files (default is dry-run diff)")
	flag.Parse()

	if *apply {
		*llm = true // --apply needs the mined candidates
	}
	if *write && !*apply {
		log.Println("warning: --write has no effect without --apply; ignoring")
	}

	if _, err := os.Stat(*root); err != nil {
		log.Fatalf("claude projects root not found: %s (%v)", *root, err)
	}
	table := loadPricing(*pricingPath)
	th := insights.DefaultThresholds()
	cache := insights.OpenCache(!*noCache)

	// Per-session drill-down.
	if *sessionFlag != "" {
		path, err := session.Find(*root, *sessionFlag)
		if err != nil {
			log.Fatalf("session: %v", err)
		}
		s, err := session.Parse(path)
		if err != nil {
			log.Fatalf("parse %s: %v", path, err)
		}
		r := insights.AnalyzeSession(s, table, th)
		r.Project = filepath.Base(filepath.Dir(path))
		switch {
		case *digestFlag:
			d := insights.BuildDigest(s, r, digestMaxPrompts, digestMaxTools, digestMaxRunes)
			_ = writeDigest(os.Stdout, d)
		case *jsonFlag:
			_ = writeJSON(os.Stdout, insights.CorpusReport{Sessions: []insights.SessionReport{r}})
		default:
			writeSession(os.Stdout, r)
		}
		if *llm {
			judge := insights.NewCLIJudge()
			one := insights.CorpusReport{Sessions: []insights.SessionReport{r}}
			mined := runLLM(os.Stdout, *root, table, th, one, cache, *refresh, *llmMax, judge)
			if *apply {
				writeApply(os.Stdout, applyClaudeMd(one, mined, judge, *write), *write)
			}
		}
		return
	}

	// Corpus mode. The window is exactly "last N days" (mtime-filtered); unlike
	// the counter we have no month-aligned aggregation to anchor to.
	notBefore := windowStart(time.Now().Local(), *days)
	fmt.Fprintf(os.Stderr, "scanning %s (last %d days) …\n", *root, *days)
	reports, err := insights.Scan(*root, table, th, notBefore, cache, *refresh)
	if err != nil {
		log.Fatalf("scan: %v", err)
	}
	// Cost-without-delivery: git-check only the expensive sessions.
	insights.ApplyDelivery(reports, gitDelivery, deliveryMinUSD)
	c := insights.BuildCorpus(reports)
	switch {
	case *jsonFlag:
		_ = writeJSON(os.Stdout, c)
	case *csvFlag:
		_ = writeCSV(os.Stdout, c)
	default:
		writeCorpus(os.Stdout, c, *topN)
	}
	if *llm {
		judge := insights.NewCLIJudge()
		mined := runLLM(os.Stdout, *root, table, th, c, cache, *refresh, *llmMax, judge)
		if *apply {
			writeApply(os.Stdout, applyClaudeMd(c, mined, judge, *write), *write)
		}
	}
}
