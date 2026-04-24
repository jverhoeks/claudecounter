package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/jjverhoeks/claudecounter/internal/agg"
	"github.com/jjverhoeks/claudecounter/internal/pricing"
	"github.com/jjverhoeks/claudecounter/internal/reader"
	"github.com/jjverhoeks/claudecounter/internal/ui"
	"github.com/jjverhoeks/claudecounter/internal/watcher"
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
	flag.Parse()

	if _, err := os.Stat(*root); err != nil {
		log.Fatalf("claude projects root not found: %s (%v)", *root, err)
	}

	table, pricingWarn := loadPricing(*pricingPath, *refresh)

	evCh := make(chan reader.Event, 256)
	r := reader.New(evCh)
	a := agg.New(table)

	w, err := watcher.New()
	if err != nil {
		log.Fatalf("watcher: %v", err)
	}
	defer w.Close()
	if err := w.AddTree(*root); err != nil {
		log.Fatalf("watcher add: %v", err)
	}

	m := ui.NewModel()
	prog := tea.NewProgram(m, tea.WithAltScreen())

	// Start the event pipeline BEFORE InitialScan — the reader emits
	// synchronously into evCh, so without a consumer the channel would
	// fill during backfill and deadlock the scan.
	go pipeline(w, r, a, evCh, prog, table, pricingWarn)

	notBefore := firstOfMonth(time.Now().Local())
	if err := r.InitialScan(*root, notBefore); err != nil {
		log.Fatalf("initial scan: %v", err)
	}

	prog.Send(ui.SnapshotMsg{
		Totals:      a.Snapshot(),
		ParseErrors: r.ParseErrors(),
		PricingWarn: pricingWarn,
	})

	if _, err := prog.Run(); err != nil {
		log.Fatal(err)
	}
}

func firstOfMonth(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, t.Location())
}

func pipeline(w *watcher.Watcher, r *reader.Reader, a *agg.Aggregator,
	evCh chan reader.Event, prog *tea.Program, table pricing.Table, pricingWarn string) {

	debounce := time.NewTimer(time.Hour)
	debounce.Stop()
	dirty := false

	flush := func() {
		if !dirty {
			return
		}
		prog.Send(ui.SnapshotMsg{
			Totals:      a.Snapshot(),
			ParseErrors: r.ParseErrors(),
			PricingWarn: pricingWarn,
		})
		dirty = false
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
			cost := table.Cost(e.Model, e.Usage)
			prog.Send(ui.RecentEventMsg{
				Line: fmt.Sprintf("%s  %-12s %-8s %s",
					e.Timestamp.Local().Format("15:04:05"),
					filepath.Base(e.Cwd),
					shortModelTag(e.Model),
					ui.FormatUSD(cost),
				),
			})
			dirty = true
			debounce.Reset(50 * time.Millisecond)
		case <-debounce.C:
			flush()
		}
	}
}

func shortModelTag(id string) string {
	switch {
	case contains(id, "opus"):
		return "opus"
	case contains(id, "sonnet"):
		return "sonnet"
	case contains(id, "haiku"):
		return "haiku"
	}
	return id
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// loadPricing resolves the price table in order: refresh flag > load file > fetch > defaults.
// Returns the table plus a user-facing warning (empty if all is well).
func loadPricing(path string, refresh bool) (pricing.Table, string) {
	if !refresh {
		if t, err := pricing.Load(path); err == nil && len(t.Models) > 0 {
			return t, ""
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
