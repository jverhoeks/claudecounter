package report

import (
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/gitstat"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
)

// ScanStats reports parse/dedupe counters from a wide scan.
type ScanStats struct {
	ParseErrors int
	Dupes       int
}

// Scan reads every transcript under root modified at/after notBefore into a
// fresh aggregator and returns the per-project per-day cost rows. It does
// not touch the live aggregator, so the report can use a wider window than
// the live views without disturbing them.
func Scan(root string, table pricing.Table, notBefore time.Time) ([]agg.ProjDayCost, ScanStats, error) {
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

	if err := r.InitialScan(root, notBefore); err != nil {
		close(evCh)
		<-done
		return nil, ScanStats{}, err
	}
	close(evCh)
	<-done

	return a.ProjectDaily(), ScanStats{ParseErrors: r.ParseErrors(), Dupes: a.Dupes()}, nil
}

// Gather groups cost rows by git repo root, collects each repo's commits
// since `since`, and builds the report. Cost rows whose cwd is not inside a
// git work tree are dropped; skipped is their count. Repos sharing a root
// (worktrees/subdirs) merge into one.
func Gather(costs []agg.ProjDayCost, size BucketSize, since time.Time) (reports []RepoReport, skipped int) {
	// cwd -> repo root, memoised so we run rev-parse once per distinct cwd.
	rootOf := map[string]string{}
	resolve := func(cwd string) (string, bool) {
		if r, seen := rootOf[cwd]; seen {
			return r, r != ""
		}
		r, ok := gitstat.RepoRoot(cwd)
		if !ok {
			rootOf[cwd] = ""
			return "", false
		}
		rootOf[cwd] = r
		return r, true
	}

	costByRoot := map[string][]CostDay{}
	for _, c := range costs {
		root, ok := resolve(c.Cwd)
		if !ok {
			skipped++
			continue
		}
		costByRoot[root] = append(costByRoot[root], CostDay{Day: c.Day, USD: c.USD})
	}

	inputs := make([]RepoInput, 0, len(costByRoot))
	for root, days := range costByRoot {
		commits, err := gitstat.Collect(root, since, gitstat.MyEmail(root))
		if err != nil {
			// A repo that errors on log still appears with cost and no commits.
			commits = nil
		}
		inputs = append(inputs, RepoInput{Root: root, CostDays: days, Commits: commits})
	}

	return Build(inputs, size), skipped
}
