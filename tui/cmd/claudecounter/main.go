package main

import (
	"context"
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/limits"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
	"github.com/jverhoeks/claudecounter/tui/internal/report"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
	"github.com/jverhoeks/claudecounter/tui/internal/ui"
	"github.com/jverhoeks/claudecounter/tui/internal/watcher"
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
	sourcesPath := flag.String("sources-config", sources.DefaultConfigPath(), "path to sources.toml")
	refresh := flag.Bool("refresh-pricing", false, "fetch pricing from the web and overwrite pricing.toml")
	once := flag.Bool("once", false, "scan once, print totals, and exit (no TUI, no watcher)")
	reportFlag := flag.Bool("report", false, "scan once, print the git-activity report, and exit")
	days := flag.Int("days", 90, "report window in days (30/90/180)")
	bucket := flag.String("bucket", "week", "report bucket: day|week|month")
	csvFlag := flag.Bool("csv", false, "print the git-activity report as CSV to stdout and exit (implies --report; with --safety, exports the safety report)")
	safetyFlag := flag.Bool("safety", false, "scan once, print the permission-mode safety report, and exit")
	scorecardFlag := flag.Bool("scorecard", false, "print a per-session scorecard and exit")
	timelineFlag := flag.Bool("timeline", false, "print a per-session audit timeline and exit")
	sessionFlag := flag.String("session", "", "session id prefix for --scorecard/--timeline (default: most recent session)")
	phasesFlag := flag.Bool("phases", false, "print subagent spend by phase/language/model for this month and exit")
	limitsFlag := flag.Bool("limits", false, "scan once, print budget and plan-limit gauges, and exit")
	limitsPath := flag.String("limits-config", limits.DefaultConfigPath(), "path to limits.toml")
	flag.Parse()

	// rootSet tracks whether --root was passed explicitly, as opposed to
	// carrying its default. --once and --limits treat an explicit --root
	// as an override of the configured source list (a single implicit
	// source rooted there) — the pre-sources-feature contract that
	// --root always wins. The report-family one-shots below don't
	// consult sources at all; they keep using --root directly.
	rootSet := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "root" {
			rootSet = true
		}
	})
	home, _ := os.UserHomeDir()

	table, pricingWarn := loadPricing(*pricingPath, *refresh)

	if *once {
		runOnce(resolveSources(*sourcesPath, *root, rootSet, home), table, pricingWarn)
		return
	}
	if *limitsFlag {
		runLimits(resolveSources(*sourcesPath, *root, rootSet, home), table, *limitsPath)
		return
	}
	if *phasesFlag {
		requireRoot(*root)
		runPhases(*root, table)
		return
	}
	if *scorecardFlag {
		requireRoot(*root)
		runScorecard(*root, table, *sessionFlag)
		return
	}
	if *timelineFlag {
		requireRoot(*root)
		runTimeline(*root, table, *sessionFlag)
		return
	}
	if *safetyFlag {
		requireRoot(*root)
		if *csvFlag {
			runSafetyCSV(*root, *days)
		} else {
			runSafety(*root, *days)
		}
		return
	}
	if *csvFlag {
		requireRoot(*root)
		runReportCSV(*root, table, *days, parseBucket(*bucket))
		return
	}
	if *reportFlag {
		requireRoot(*root)
		runReport(*root, table, *days, parseBucket(*bucket))
		return
	}
	runTUI(*root, table, pricingWarn, *limitsPath, *sourcesPath)
}

// requireRoot fails fast if root doesn't exist. Used only by the
// report-family one-shot commands (--report, --safety, --scorecard,
// --timeline, --phases), which still take --root directly and are out
// of scope for --sources-config (Task 6 wires --once, --limits, and the
// live TUI). --once/--limits and the live TUI no longer need this: an
// absent configured root contributes nothing and is not an error,
// matching how an absent vendor already behaves.
func requireRoot(root string) {
	if _, err := os.Stat(root); err != nil {
		log.Fatalf("claude projects root not found: %s (%v)", root, err)
	}
}

// resolveSources returns the source list for the --once/--limits
// one-shot paths. An explicit --root overrides the configured list with
// a single implicit source, so a user who still passes --root sees
// exactly what they always have. Otherwise the configured list is used
// (Defaults(home) when no sources.toml exists — byte-identical to
// today's implicit single-source behaviour). A malformed sources.toml
// is fatal here: these are one-shot commands, so exiting non-zero with
// the parse error beats silently showing wrong or empty totals.
// Contrast runTUI, which must never exit on the same error.
func resolveSources(sourcesPath, root string, rootSet bool, home string) []sources.Source {
	if rootSet {
		return []sources.Source{{Vendor: "claude", Label: "claude", Root: root}}
	}
	return loadSourcesOrExit(sourcesPath, home)
}

func loadSourcesOrExit(cfgPath, home string) []sources.Source {
	cfg, err := sources.Load(cfgPath, home)
	if err != nil {
		fmt.Fprintln(os.Stderr, "sources config:", err)
		os.Exit(1)
	}
	return cfg.Sources
}

// runOnce scans every configured source once, prints a plain-text
// summary, and exits.
func runOnce(srcs []sources.Source, table pricing.Table, pricingWarn string) {
	for _, s := range srcs {
		fmt.Fprintf(os.Stderr, "scanning %s (%s) …\n", s.Root, s.ID())
	}
	start := time.Now()

	snap, dupes, parseErrors := scanSnapshotSources(srcs, table)

	fmt.Fprintf(os.Stderr, "scanned in %s\n\n", time.Since(start).Round(time.Millisecond))

	if pricingWarn != "" {
		fmt.Println(pricingWarn)
	}
	printSummary(snap, dupes, parseErrors)
}

// scanSnapshotFromConfig loads the source list and scans every
// configured root into one aggregator. A malformed config is fatal
// here (the one-shot paths exit non-zero); the live TUI path must not
// be, and handles the error separately — see runTUI.
func scanSnapshotFromConfig(cfgPath, home string, table pricing.Table) agg.Totals {
	snap, _, _ := scanSnapshotSources(loadSourcesOrExit(cfgPath, home), table)
	return snap
}

// scanSnapshotSources scans each configured source's root, in turn,
// into one shared aggregator so dedupe still spans every source. Each
// source gets its own Reader: a Reader tags every event it emits with
// one fixed source field guarded by its own mutex, so scanning two
// sources concurrently on a single shared Reader could momentarily
// mis-tag events with the wrong source mid-scan. Giving every source
// its own Reader removes that hazard structurally rather than relying
// on scans staying sequential (which they are here, but runTUI's
// watcher path is not).
func scanSnapshotSources(srcs []sources.Source, table pricing.Table) (agg.Totals, int, int) {
	evCh := make(chan reader.Event, 1024)
	a := agg.New(table)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for e := range evCh {
			a.Apply(e)
		}
	}()

	notBefore := scanCutoff(time.Now().Local())
	readers := make([]*reader.Reader, 0, len(srcs))
	for _, s := range srcs {
		// A configured root that does not exist contributes nothing and
		// is not an error — same rule as an absent vendor.
		if _, err := os.Stat(s.Root); err != nil {
			continue
		}
		r := reader.New(evCh)
		if err := r.InitialScanSource(s, notBefore); err != nil {
			log.Fatalf("initial scan %s: %v", s.ID(), err)
		}
		readers = append(readers, r)
	}
	close(evCh)
	<-done

	parseErrors := 0
	for _, r := range readers {
		parseErrors += r.ParseErrors()
	}
	return a.Snapshot(), a.Dupes(), parseErrors
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
	// Collapse by model across every source: --once may now span more
	// than one configured source (a plain --root still produces exactly
	// one), and this plain-text report has always shown one line per
	// model, not per source — merging keeps that unchanged.
	byModel := agg.Group(snap.Month, agg.GroupModel)
	names := make([]string, 0, len(byModel))
	for n := range byModel {
		names = append(names, n)
	}
	sort.Slice(names, func(i, j int) bool {
		return byModel[names[i]].USD > byModel[names[j]].USD
	})
	for _, n := range names {
		md := byModel[n]
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

// gaugeRefreshInterval is how often the live TUI re-scans budgets and
// vendor plan logs. It is decoupled from the aggregator's sub-second
// dirty-flush cadence on purpose: a gauge refresh walks the Codex
// sessions directory and reads the Grok log, and running that on every
// 250ms flush during a 47k-event backfill risks stalling the counting
// pipeline itself. Budgets and plan windows do not change fast enough
// to need better than this.
const gaugeRefreshInterval = 30 * time.Second

// runTUI starts the interactive dashboard.
func runTUI(root string, table pricing.Table, pricingWarn string, limitsCfgPath string, sourcesCfgPath string) {
	home, _ := os.UserHomeDir()
	cfg, srcErr := sources.Load(sourcesCfgPath, home)
	if srcErr != nil {
		// A malformed sources.toml must never take the live TUI down:
		// fall back to the default source list (today's implicit
		// single-source behaviour) and surface the error as a footer
		// warning, the same way a malformed pricing.toml already does
		// (both ride SnapshotMsg.PricingWarn). Contrast resolveSources /
		// scanSnapshotFromConfig, the one-shot paths, which exit
		// non-zero on the same error.
		warn := fmt.Sprintf("⚠ sources config: %v (using defaults)", srcErr)
		if pricingWarn != "" {
			pricingWarn += "\n" + warn
		} else {
			pricingWarn = warn
		}
		cfg = sources.Config{Sources: sources.Defaults(home)}
	}
	srcs := cfg.Sources
	rsrcs := resolveSourceRoots(srcs)

	evCh := make(chan reader.Event, 1024)
	a := agg.New(table)
	// One Reader per configured source (see scanSnapshotSources): the
	// backfill goroutine below and the pipeline's watcher-event loop run
	// concurrently, and each may be working a different source at the
	// same instant. A single shared Reader's source field would then be
	// a data race that tags events with whichever source last won the
	// mutex — silent mis-attribution of spend, not a crash. Separate
	// Reader instances make that structurally impossible instead of
	// relying on careful serialization that the next change could break.
	readers := make(map[string]*reader.Reader, len(srcs))
	for _, s := range srcs {
		readers[s.ID()] = reader.New(evCh)
	}

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
	m.SetReportFunc(func(days int, size report.BucketSize) ui.ReportMsg {
		reports, skipped, err := gatherReport(root, table, days, size)
		return ui.ReportMsg{Reports: reports, Skipped: skipped, Days: days, Bucket: size, Err: err}
	})
	m.SetSafetyFunc(func(days int) ui.SafetyMsg {
		rows, sum, err := gatherSafety(root, days)
		return ui.SafetyMsg{Rows: rows, Sum: sum, Days: days, Err: err}
	})
	prog := tea.NewProgram(m, tea.WithAltScreen())

	// liveTail is closed by the backfill goroutine once every source's
	// InitialScanSource completes. Until then the pipeline only updates
	// the aggregator — it does NOT emit RecentEventMsg per backfill event
	// (47k+ events would flood bubbletea's message queue and delay first
	// paint).
	liveTail := make(chan struct{})
	go pipeline(w, readers, rsrcs, a, evCh, prog, table, pricingWarn, liveTail)

	// NOTE: bubbletea's program.Send blocks on an unbuffered channel
	// until prog.Run() is reading. Anything that calls Send must run
	// in a goroutine that will only fire AFTER Run has started — the
	// pipeline ticker (250 ms), the gauge ticker below (fires no sooner
	// than gaugeRefreshInterval), and the backfill completion send
	// (which only runs after InitialScan) all satisfy that. Don't send
	// synchronously from this point.

	// refreshGauges re-scans budgets and vendor plan logs and pushes the
	// result to the UI (see gaugeRefreshInterval for why this runs on
	// its own cadence rather than piggybacking on the aggregator's
	// dirty flush). A malformed limits.toml is carried in GaugesMsg.Err
	// rather than logged or exited: the live counting path must never
	// go down, or spam stderr under the alt screen, over a config typo.
	// The model turns Err into a footer warning and leaves the
	// last-good gauge block on screen. Contrast runLimits, the
	// one-shot, which exits non-zero on the same error.
	refreshGauges := func() {
		out, err := gatherGauges(limitsCfgPath, a.Snapshot().Daily, time.Now())
		prog.Send(ui.GaugesMsg{Gauges: out, Err: err})
	}
	go func() {
		ticker := time.NewTicker(gaugeRefreshInterval)
		defer ticker.Stop()
		for range ticker.C {
			refreshGauges()
		}
	}()

	go func() {
		notBefore := scanCutoff(time.Now().Local())
		// Register fsnotify watchers in parallel with the initial
		// scan: AddTree is mostly syscall-bound, InitialScanSource is
		// I/O-bound, so both running concurrently roughly halves the
		// cold-start time. A configured root that does not exist
		// contributes nothing and is not an error, matching how an
		// absent vendor already behaves.
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			for _, s := range srcs {
				if _, err := os.Stat(s.Root); err != nil {
					continue
				}
				if err := w.AddTree(s.Root, notBefore); err != nil {
					log.Printf("watcher add %s: %v", s.ID(), err)
				}
			}
		}()
		for _, s := range srcs {
			if _, err := os.Stat(s.Root); err != nil {
				continue
			}
			if err := readers[s.ID()].InitialScanSource(s, notBefore); err != nil {
				log.Printf("initial scan %s: %v", s.ID(), err)
			}
		}
		wg.Wait()
		// Push the post-backfill snapshot once, then run the first gauge
		// refresh from real (fully backfilled) totals — not before, or
		// a configured budget would briefly show a confident but wrong
		// 0% off an empty Daily series — then unblock the live tail and
		// tell the UI to drop the spinner.
		prog.Send(ui.SnapshotMsg{
			Totals:      a.Snapshot(),
			ParseErrors: sumParseErrors(readers),
			Dupes:       a.Dupes(),
			PricingWarn: pricingWarn,
		})
		refreshGauges()
		prog.Send(ui.BackfillDoneMsg{})
		close(liveTail)
	}()

	if _, err := prog.Run(); err != nil {
		log.Fatal(err)
	}
}

func sumParseErrors(readers map[string]*reader.Reader) int {
	total := 0
	for _, r := range readers {
		total += r.ParseErrors()
	}
	return total
}

// resolvedSource pairs a configured source with its symlink-resolved
// root. macOS's default TMPDIR (and hence the real ~/.claude/projects
// on some setups) can sit behind a symlink, and fsnotify reports events
// under whichever path the OS resolved — which may not be byte-equal to
// the configured root even though it's the same file. Resolving once at
// startup, rather than trusting a raw string-prefix match, keeps a
// symlinked root from silently failing to match any source (which would
// drop the event on the floor rather than mis-attribute it, but is
// exactly as much a correctness bug for this feature).
type resolvedSource struct {
	sources.Source
	resolvedRoot string
}

func resolveSourceRoots(srcs []sources.Source) []resolvedSource {
	out := make([]resolvedSource, len(srcs))
	for i, s := range srcs {
		root := s.Root
		if r, err := filepath.EvalSymlinks(root); err == nil {
			root = r
		}
		out[i] = resolvedSource{Source: s, resolvedRoot: root}
	}
	return out
}

// sourceForPath finds the source whose (resolved) root is the longest
// matching prefix of path. sources.Load's overlap check guarantees at
// most one source's root can contain a given path, so the longest match
// is also the only match.
func sourceForPath(rsrcs []resolvedSource, path string) (sources.Source, bool) {
	resolved := path
	if r, err := filepath.EvalSymlinks(path); err == nil {
		resolved = r
	}
	best := -1
	var bestSrc sources.Source
	for _, rs := range rsrcs {
		if resolved == rs.resolvedRoot || strings.HasPrefix(resolved, rs.resolvedRoot+string(filepath.Separator)) {
			if len(rs.resolvedRoot) > best {
				best = len(rs.resolvedRoot)
				bestSrc = rs.Source
			}
		}
	}
	return bestSrc, best >= 0
}

// handleWatchChange dispatches one filesystem change to the Reader that
// owns its source. Factored out of pipeline so the path-to-source
// mapping is unit-testable without a running bubbletea program.
func handleWatchChange(c watcher.Change, rsrcs []resolvedSource, readers map[string]*reader.Reader) {
	src, ok := sourceForPath(rsrcs, c.Path)
	if !ok {
		// Should not happen: the watcher only ever watches configured
		// roots. Log rather than silently drop — a swallowed event here
		// is spend silently lost, not just mis-attributed.
		log.Printf("watcher: %s does not match any configured source root; ignoring", c.Path)
		return
	}
	r := readers[src.ID()]
	switch c.Kind {
	case watcher.Create, watcher.Write:
		_ = r.OnChangeSource(src, c.Path)
	case watcher.Remove:
		r.Forget(c.Path)
	}
}

func parseBucket(s string) report.BucketSize {
	switch s {
	case "day":
		return report.BucketDay
	case "month":
		return report.BucketMonth
	default:
		return report.BucketWeek
	}
}

// reportSince converts a day-count window into the scan/commit cutoff.
func reportSince(now time.Time, days int) time.Time {
	if days <= 0 {
		days = 90
	}
	return now.AddDate(0, 0, -days)
}

// gatherReport runs the wide scan + git collect for a window. Shared by the
// CLI and the TUI's injected ReportFunc.
func gatherReport(root string, table pricing.Table, days int, size report.BucketSize) ([]report.RepoReport, int, error) {
	since := reportSince(time.Now().Local(), days)
	costs, _, err := report.Scan(root, table, since)
	if err != nil {
		return nil, 0, err
	}
	reports, skipped := report.Gather(costs, size, since)
	return reports, skipped, nil
}

func runReport(root string, table pricing.Table, days int, size report.BucketSize) {
	fmt.Fprintf(os.Stderr, "scanning %s (last %d days) …\n", root, days)
	reports, skipped, err := gatherReport(root, table, days, size)
	if err != nil {
		log.Fatalf("report scan: %v", err)
	}
	if len(reports) == 0 {
		msg := "No git activity found for projects in this window."
		if skipped > 0 {
			msg += fmt.Sprintf(" (%d project dirs were not git repos, or git is unavailable.)", skipped)
		}
		fmt.Println(msg)
		return
	}
	for _, r := range reports {
		fmt.Printf("\n%s   %s · %d commits (mine) / %d all · +%d -%d · %d files · %s tok\n",
			r.Root, ui.FormatUSD(r.Total.USD),
			r.Total.CommitsMine, r.Total.CommitsAll,
			r.Total.Added, r.Total.Deleted, r.Total.Files,
			ui.FormatTokShort(r.Total.Tokens))
		fmt.Printf("  %-12s %10s %14s %9s %9s %7s %10s %10s %11s %11s\n",
			"bucket", "$", "commits(m/all)", "+lines", "-lines", "files", "$/commit", "$/line", "tok/commit", "tok/line")
		for _, bk := range r.Buckets {
			pc, pl := "—", "—"
			if bk.USDPerCommit > 0 {
				pc = ui.FormatUSD(bk.USDPerCommit)
			}
			if bk.USDPerLine > 0 {
				pl = fmt.Sprintf("$%.4f", bk.USDPerLine)
			}
			tc, tl := "—", "—"
			if bk.TokPerCommit > 0 {
				tc = ui.FormatTokShort(uint64(bk.TokPerCommit))
			}
			if bk.TokPerLine > 0 {
				tl = ui.FormatTokShort(uint64(bk.TokPerLine))
			}
			fmt.Printf("  %-12s %10s %14s %9d %9d %7d %10s %10s %11s %11s\n",
				bk.Label, ui.FormatUSD(bk.USD),
				fmt.Sprintf("%d/%d", bk.CommitsMine, bk.CommitsAll),
				bk.Added, bk.Deleted, bk.Files, pc, pl, tc, tl)
		}
	}
	if skipped > 0 {
		fmt.Printf("\n(%d non-git projects skipped)\n", skipped)
	}
}

// ratioCSV renders a ratio for CSV: empty when undefined (zero denominator),
// otherwise a plain decimal (no $ or thousands separators).
func ratioCSV(v float64) string {
	if v <= 0 {
		return ""
	}
	return strconv.FormatFloat(v, 'f', 4, 64)
}

// writeReportCSV emits one row per (repo, bucket). Pure (takes an io.Writer)
// so it's testable without touching stdout.
func writeReportCSV(w io.Writer, reports []report.RepoReport) error {
	cw := csv.NewWriter(w)
	if err := cw.Write([]string{
		"repo", "bucket", "usd", "commits_mine", "commits_all",
		"added", "deleted", "files", "usd_per_commit", "usd_per_line",
		"tokens", "tokens_per_commit", "tokens_per_line",
	}); err != nil {
		return err
	}
	for _, r := range reports {
		for _, b := range r.Buckets {
			if err := cw.Write([]string{
				r.Root, b.Label,
				strconv.FormatFloat(b.USD, 'f', 2, 64),
				strconv.Itoa(b.CommitsMine), strconv.Itoa(b.CommitsAll),
				strconv.Itoa(b.Added), strconv.Itoa(b.Deleted), strconv.Itoa(b.Files),
				ratioCSV(b.USDPerCommit), ratioCSV(b.USDPerLine),
				strconv.FormatUint(b.Tokens, 10), ratioCSV(b.TokPerCommit), ratioCSV(b.TokPerLine),
			}); err != nil {
				return err
			}
		}
	}
	cw.Flush()
	return cw.Error()
}

func runReportCSV(root string, table pricing.Table, days int, size report.BucketSize) {
	reports, _, err := gatherReport(root, table, days, size)
	if err != nil {
		log.Fatalf("report scan: %v", err)
	}
	if err := writeReportCSV(os.Stdout, reports); err != nil {
		log.Fatalf("csv: %v", err)
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

func pipeline(w *watcher.Watcher, readers map[string]*reader.Reader, rsrcs []resolvedSource, a *agg.Aggregator,
	evCh chan reader.Event, prog *tea.Program, table pricing.Table, pricingWarn string,
	liveTail <-chan struct{}) {

	// Periodic flush tick keeps the UI moving during heavy bursts
	// (e.g. the backfill) where an event-only debounce would keep resetting.
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()

	// Start dirty=true so the very first tick (~250 ms after Run starts)
	// flushes an initial snapshot — that's how pricing warnings reach
	// the footer without a synchronous Send before Run.
	dirty := true
	flush := func() {
		if !dirty {
			return
		}
		prog.Send(ui.SnapshotMsg{
			Totals:      a.Snapshot(),
			ParseErrors: sumParseErrors(readers),
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
			handleWatchChange(c, rsrcs, readers)
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
