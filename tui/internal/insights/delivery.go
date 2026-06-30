package insights

import (
	"fmt"
	"time"
)

// CatDelivery flags spend that produced no visible deliverable.
const CatDelivery Category = "delivery"

// DeliveryFn reports how many commits landed in [start,end] in the repo at cwd.
// ok=false means delivery couldn't be determined (cwd not a git repo, git
// unavailable) — treated as "unknown", never as "no delivery".
type DeliveryFn func(cwd string, start, end time.Time) (commits int, ok bool)

// deliveryFinding flags an expensive session that shows no deliverable: no
// pr-link event AND zero commits in its window. When delivery is unknown
// (non-git cwd) we do NOT flag — absence of git evidence isn't evidence of
// waste. minUSD gates this to sessions worth worrying about.
func deliveryFinding(cwd string, start, end time.Time, hasPR bool, usd float64, deliver DeliveryFn, minUSD float64) []Finding {
	if usd < minUSD || hasPR {
		return nil
	}
	commits, ok := deliver(cwd, start, end)
	if !ok || commits > 0 {
		return nil
	}
	return []Finding{{
		Category: CatDelivery,
		Detail:   fmt.Sprintf("%s session with no commit and no PR — did the work land?", fmtUSD(usd)),
		Count:    1,
		USD:      0, // not "waste" spend, a delivery flag — keep it out of waste $
	}}
}

// fmtUSD is a tiny local money formatter (the ui formatter lives in the cmd
// layer, which insights must not import).
func fmtUSD(v float64) string {
	return fmt.Sprintf("$%.2f", v)
}

// ApplyDelivery appends a cost-without-delivery finding to each report whose
// USD is at/above minUSD, using deliver to check git. Reports are updated in
// place; the count flagged is returned. Cheap reports are skipped without a
// git call, so this only shells out for the handful of expensive sessions.
func ApplyDelivery(reports []SessionReport, deliver DeliveryFn, minUSD float64) int {
	flagged := 0
	for i := range reports {
		r := &reports[i]
		fs := deliveryFinding(r.Cwd, r.Start, r.End, r.HasPRLink, r.USD, deliver, minUSD)
		if len(fs) == 0 {
			continue
		}
		r.Findings = append(r.Findings, fs...)
		r.Score += float64(len(fs))
		flagged++
	}
	return flagged
}
