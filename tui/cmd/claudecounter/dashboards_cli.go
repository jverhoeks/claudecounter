package main

import (
	"fmt"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/jverhoeks/claudecounter/tui/internal/dashtui"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/dashboard"
	"github.com/jverhoeks/claudecounter/tui/internal/hints"
	"github.com/jverhoeks/claudecounter/tui/internal/perf"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
	"github.com/jverhoeks/claudecounter/tui/internal/ui"
)

// dashboardScanDays is how far back --hints and the dashboards read.
// The range pickers go to a year, so spend history reaches that far;
// the per-request performance parse is heavier and its views stop at 90
// days.
const (
	dashboardSpendDays = 366
	dashboardPerfDays  = 90
)

// perfRoots is the Claude sources' roots: the per-request parse reads
// Claude Code's JSONL only.
func perfRoots(srcs []sources.Source) []string {
	var out []string
	for _, s := range srcs {
		if s.Vendor == "claude" {
			out = append(out, s.Root)
		}
	}
	return out
}

// loadDashboardData scans srcs for spend history and per-request samples
// at once — the two walk the same files — and reads the Claude settings
// the hints check against. withSpend=false skips the spend history
// (--hints needs only samples).
func loadDashboardData(srcs []sources.Source, table pricing.Table, withSpend bool, progress func(done, total int)) dashboard.Data {
	scannable, warnings := splitReachable(srcs)
	now := time.Now()
	d := dashboard.Data{Sources: srcs, Warnings: warnings, Pricing: table, Settings: hints.LoadSettings(hints.UserSettingsPath())}
	var wg sync.WaitGroup
	if withSpend {
		wg.Add(1)
		go func() {
			defer wg.Done()
			h, err := dashboard.Collect(scannable, table, now.AddDate(0, 0, -dashboardSpendDays))
			if err != nil {
				d.Warnings = append(d.Warnings, "⚠ "+err.Error())
			}
			d.Spend = h.Snapshot(now)
		}()
	}
	d.Samples = perf.Scan(perfRoots(scannable), now.AddDate(0, 0, -dashboardPerfDays), progress)
	wg.Wait()
	return d
}

// runHints prints the improvement hints for the last days days.
func runHints(srcs []sources.Source, table pricing.Table, days int) {
	fmt.Fprintln(os.Stderr, "scanning session logs …")
	d := loadDashboardData(srcs, table, false, nil)
	for _, w := range d.Warnings {
		fmt.Fprintln(os.Stderr, w)
	}
	now := time.Now()
	period := hints.InPeriod(d.Samples, days, now)
	hs := hints.Build(d.Samples, table, d.Settings, days, now)

	fmt.Printf("Hints · last %d days · %s spent at API prices\n", days, ui.FormatUSD(hints.Spend(period, table)))
	fmt.Println(wrap(hints.Disclaimer, 78, ""))
	sep := strings.Repeat("─", 78)
	if len(hs) == 0 {
		fmt.Println(sep)
		fmt.Println("✓ Nothing worth changing in this period.")
		return
	}
	for _, h := range hs {
		fmt.Println(sep)
		fmt.Printf("%s\n", h.Title)
		if days == 30 {
			fmt.Printf("  ≈ %s in 30 days\n", ui.FormatUSD(h.SavingUSD))
		} else {
			fmt.Printf("  ≈ %s in %d days · ≈ %s/month\n", ui.FormatUSD(h.SavingUSD), days, ui.FormatUSD(hints.PerMonth(h.SavingUSD, days)))
		}
		fmt.Println(wrap(h.Finding, 78, "  "))
		fmt.Println(wrap("Fix: "+h.Fix, 78, "  "))
		if h.Snippet != "" {
			fmt.Printf("    %s\n", h.Snippet)
		}
		if h.Applied != "" {
			fmt.Println(wrap("✓ Applied: "+h.Applied, 78, "  "))
		} else {
			fmt.Println(wrap("⚠ Trade-off: "+h.Caveat, 78, "  "))
		}
	}
}

// wrap breaks s into lines of at most width runes, each prefixed with
// indent.
func wrap(s string, width int, indent string) string {
	var b strings.Builder
	line := indent
	for _, w := range strings.Fields(s) {
		if len([]rune(line)) > len(indent) && len([]rune(line))+1+len([]rune(w)) > width {
			b.WriteString(line + "\n")
			line = indent
		}
		if len([]rune(line)) > len(indent) {
			line += " "
		}
		line += w
	}
	b.WriteString(line)
	return b.String()
}

// runDashboards opens the full-screen analytics dashboard.
func runDashboards(load dashboard.Loader) {
	p := tea.NewProgram(dashtui.New(load), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "dashboards:", err)
		os.Exit(1)
	}
}
