package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/jverhoeks/claudecounter/internal/agg"
	"github.com/jverhoeks/claudecounter/internal/pricing"
	"github.com/jverhoeks/claudecounter/internal/reader"
	"github.com/jverhoeks/claudecounter/internal/ui"
	"github.com/jverhoeks/claudecounter/internal/watcher"
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

func main() {
	pricingPath := flag.String("pricing", defaultPricingPath(), "path to pricing.toml")
	root := flag.String("root", defaultRoot(), "claude projects root")
	refresh := flag.Bool("refresh-pricing", false, "fetch pricing from the web and overwrite pricing.toml")
	once := flag.Bool("once", false, "scan once, print totals, and exit (no TUI, no watcher)")
	flag.Parse()

	if _, err := os.Stat(*root); err != nil {
		log.Fatalf("claude projects root not found: %s (%v)", *root, err)
	}

	table, pricingWarn := loadPricing(*pricingPath, *refresh)

	if *once {
		runOnce(*root, table, pricingWarn)
		return
	}
	runTUI(*root, table, pricingWarn)
}

// runOnce scans the projects tree once, prints a plain-text summary, and exits.
func runOnce(root string, table pricing.Table, pricingWarn string) {
	fmt.Fprintf(os.Stderr, "scanning %s …\n", root)
	start := time.Now()

	evCh := make(chan reader.Event, 1024)
	r := reader.New(evCh)
	a := agg.New(table)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for e := range evCh {
			a.Apply(e)
		}
	}()

	notBefore := scanCutoff(time.Now().Local())
	if err := r.InitialScan(root, notBefore); err != nil {
		log.Fatalf("initial scan: %v", err)
	}
	close(evCh)
	<-done

	fmt.Fprintf(os.Stderr, "scanned in %s\n\n", time.Since(start).Round(time.Millisecond))

	snap := a.Snapshot()
	if pricingWarn != "" {
		fmt.Println(pricingWarn)
	}
	printSummary(snap, a.Dupes(), r.ParseErrors())
}

func printSummary(snap agg.Totals, dupes, parseErrors int) {
	var dayT, monthT float64
	for _, v := range snap.Day {
		dayT += v.USD
	}
	for _, v := range snap.Month {
		monthT += v.USD
	}
	fmt.Printf("Today  %s\n", ui.FormatUSD(dayT))
	fmt.Printf("Month  %s\n", ui.FormatUSD(monthT))
	fmt.Println(strings.Repeat("─", 60))
	fmt.Println("By model (this month):")
	names := make([]string, 0, len(snap.Month))
	for n := range snap.Month {
		names = append(names, n)
	}
	sort.Slice(names, func(i, j int) bool {
		return snap.Month[names[i]].USD > snap.Month[names[j]].USD
	})
	for _, n := range names {
		md := snap.Month[n]
		fmt.Printf("  %-32s %9s   in=%d out=%d cache_write=%d cache_read=%d\n",
			n, ui.FormatUSD(md.USD),
			md.Tokens.In, md.Tokens.Out, md.Tokens.CacheCreate, md.Tokens.CacheRead)
	}
	fmt.Println(strings.Repeat("─", 60))
	fmt.Println("By project (this month) — total · main · subagent:")
	pnames := make([]string, 0, len(snap.MonthProj))
	for n := range snap.MonthProj {
		pnames = append(pnames, n)
	}
	sort.Slice(pnames, func(i, j int) bool {
		return snap.MonthProj[pnames[i]].USD() > snap.MonthProj[pnames[j]].USD()
	})
	for _, n := range pnames {
		p := snap.MonthProj[n]
		fmt.Printf("  %-40s %9s · main %9s · sub %9s\n",
			shortProject(n),
			ui.FormatUSD(p.USD()),
			ui.FormatUSD(p.MainUSD),
			ui.FormatUSD(p.SubUSD),
		)
	}
	fmt.Println(strings.Repeat("─", 60))
	fmt.Printf("deduped dupes=%d  parse_errors=%d  unknown_model_events=%d\n",
		dupes, parseErrors, snap.Unknown)
}

func shortProject(encoded string) string {
	if encoded == "" {
		return "(unknown)"
	}
	parts := strings.Split(strings.TrimPrefix(encoded, "-"), "-")
	if len(parts) <= 4 {
		return encoded
	}
	tail := strings.Join(parts[4:], "-")
	if tail == "" {
		return encoded
	}
	return tail
}

// runTUI starts the interactive dashboard.
func runTUI(root string, table pricing.Table, pricingWarn string) {
	evCh := make(chan reader.Event, 1024)
	r := reader.New(evCh)
	a := agg.New(table)

	w, err := watcher.New()
	if err != nil {
		log.Fatalf("watcher: %v", err)
	}
	defer w.Close()
	// AddTree is deferred to the background goroutine below — registering
	// fsnotify watchers for thousands of subdirs is slow and would block
	// prog.Run() (i.e. the alt-screen never opens). Live updates start
	// working once that goroutine completes the AddTree pass.

	m := ui.NewModel()
	prog := tea.NewProgram(m, tea.WithAltScreen())

	// liveTail is closed by the backfill goroutine once InitialScan
	// completes. Until then the pipeline only updates the aggregator —
	// it does NOT emit RecentEventMsg per backfill event (47k+ events
	// would flood bubbletea's message queue and delay first paint).
	liveTail := make(chan struct{})
	go pipeline(w, r, a, evCh, prog, table, pricingWarn, liveTail)

	// Seed an initial snapshot so any pricing warnings show in the
	// footer immediately — totals are zero until the backfill makes
	// progress, which the spinner header signals.
	prog.Send(ui.SnapshotMsg{
		Totals:      a.Snapshot(),
		ParseErrors: r.ParseErrors(),
		Dupes:       a.Dupes(),
		PricingWarn: pricingWarn,
	})

	go func() {
		notBefore := scanCutoff(time.Now().Local())
		// Register fsnotify watchers in parallel with the initial
		// scan: AddTree is mostly syscall-bound, InitialScan is
		// I/O-bound, so both running concurrently roughly halves the
		// cold-start time.
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := w.AddTree(root, notBefore); err != nil {
				log.Printf("watcher add: %v", err)
			}
		}()
		if err := r.InitialScan(root, notBefore); err != nil {
			log.Printf("initial scan: %v", err)
		}
		wg.Wait()
		// Push the post-backfill snapshot once, then unblock the live
		// tail and tell the UI to drop the spinner.
		prog.Send(ui.SnapshotMsg{
			Totals:      a.Snapshot(),
			ParseErrors: r.ParseErrors(),
			Dupes:       a.Dupes(),
			PricingWarn: pricingWarn,
		})
		prog.Send(ui.BackfillDoneMsg{})
		close(liveTail)
	}()

	if _, err := prog.Run(); err != nil {
		log.Fatal(err)
	}
}

func firstOfMonth(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, t.Location())
}

// scanCutoff returns the mtime threshold for InitialScan: the earlier of
// (start of current calendar month) and (now − 35 days). The wider window
// guarantees we never miss an event near midnight on the 1st of a new
// month, and gives us slack for future "rolling 30-day" views without
// touching the scan code.
func scanCutoff(now time.Time) time.Time {
	fom := firstOfMonth(now)
	rolling := now.AddDate(0, 0, -35)
	if rolling.Before(fom) {
		return rolling
	}
	return fom
}

func pipeline(w *watcher.Watcher, r *reader.Reader, a *agg.Aggregator,
	evCh chan reader.Event, prog *tea.Program, table pricing.Table, pricingWarn string,
	liveTail <-chan struct{}) {

	// Periodic flush tick keeps the UI moving during heavy bursts
	// (e.g. the backfill) where an event-only debounce would keep resetting.
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()

	dirty := false
	flush := func() {
		if !dirty {
			return
		}
		prog.Send(ui.SnapshotMsg{
			Totals:      a.Snapshot(),
			ParseErrors: r.ParseErrors(),
			Dupes:       a.Dupes(),
			PricingWarn: pricingWarn,
		})
		dirty = false
	}

	tailOpen := func() bool {
		select {
		case <-liveTail:
			return true
		default:
			return false
		}
	}

	for {
		select {
		case c, ok := <-w.Events():
			if !ok {
				return
			}
			switch c.Kind {
			case watcher.Create, watcher.Write:
				_ = r.OnChange(c.Path)
			case watcher.Remove:
				r.Forget(c.Path)
			}
		case e := <-evCh:
			a.Apply(e)
			// Only stream events into the live tail AFTER backfill
			// is complete — otherwise the 47k+ backfill events flood
			// bubbletea's message queue and delay first paint.
			if tailOpen() {
				cost := table.Cost(e.Model, e.Usage)
				tag := ""
				if e.IsSubagent {
					tag = " (sub)"
				}
				prog.Send(ui.RecentEventMsg{
					Cost: cost,
					Line: fmt.Sprintf("%s  %-22s %-8s %s%s",
						e.Timestamp.Local().Format("15:04:05"),
						trimRight(filepath.Base(e.Cwd), 22),
						shortModelTag(e.Model),
						ui.FormatUSD(cost),
						tag,
					),
				})
			}
			dirty = true
		case <-tick.C:
			flush()
		}
	}
}

func trimRight(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func shortModelTag(id string) string {
	switch {
	case strings.Contains(id, "opus"):
		return "opus"
	case strings.Contains(id, "sonnet"):
		return "sonnet"
	case strings.Contains(id, "haiku"):
		return "haiku"
	}
	return id
}

// loadPricing resolves the price table in order: refresh flag > load file > fetch > defaults.
// Returns the table plus a user-facing warning (empty if all is well).
func loadPricing(path string, refresh bool) (pricing.Table, string) {
	if !refresh {
		if t, err := pricing.Load(path); err == nil && len(t.Models) > 0 {
			return t, ""
		} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
			log.Printf("pricing: %s unreadable (%v); falling back", path, err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	t, err := pricing.Fetch(ctx)
	if err == nil && len(t.Models) > 0 {
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		_ = pricing.SaveTOML(t, path)
		return t, ""
	}
	return pricing.Defaults(),
		fmt.Sprintf("⚠ pricing: using built-in defaults from %s", pricing.DefaultsDate)
}
