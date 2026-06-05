package ui

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/jverhoeks/claudecounter/tui/internal/report"
)

func bucketName(size report.BucketSize) string {
	switch size {
	case report.BucketDay:
		return "day"
	case report.BucketMonth:
		return "month"
	default:
		return "week"
	}
}

// fmtRatio renders a ratio as a dollar figure, or "—" when zero (no
// denominator) so empty buckets don't read as "free".
func fmtRatio(v float64) string {
	if v <= 0 {
		return "—"
	}
	return FormatUSD(v)
}

// viewReport renders the git-activity report. days/size describe the active
// window; skipped is the count of non-repo projects dropped; loading shows
// the spinner line instead of the table; errText (when non-empty) replaces
// the table with an error line while keeping the header + hint visible.
func viewReport(reports []report.RepoReport, days int, size report.BucketSize, skipped int, loading bool, errText string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n",
		styleHead.Render(fmt.Sprintf("Git activity & ROI — last %d days, by %s", days, bucketName(size))))
	b.WriteString(styleDim.Render("d/w/m: bucket   [/]: window   ratios are temporal, not causal") + "\n\n")

	if errText != "" {
		b.WriteString("  report error: " + errText + "\n")
		return b.String()
	}
	if loading {
		b.WriteString("  collecting git stats…\n")
		return b.String()
	}
	if len(reports) == 0 {
		b.WriteString("  No git activity found for projects in this window.\n")
		return b.String()
	}

	for _, r := range reports {
		name := filepath.Base(r.Root)
		fmt.Fprintf(&b, "%s  %s · %d commits (mine) / %d all · %s%d %s%d · %d files\n",
			styleHead.Render(name),
			styleMoney.Render(FormatUSD(r.Total.USD)),
			r.Total.CommitsMine, r.Total.CommitsAll,
			styleDim.Render("+"), r.Total.Added,
			styleDim.Render("-"), r.Total.Deleted,
			r.Total.Files,
		)
		fmt.Fprintf(&b, "  %-12s %10s  %12s  %8s %8s %6s  %9s %9s\n",
			"bucket", "$", "commits", "+lines", "-lines", "files", "$/commit", "$/line")
		for _, bk := range r.Buckets {
			fmt.Fprintf(&b, "  %-12s %10s  %12s  %8d %8d %6d  %9s %9s\n",
				bk.Label,
				FormatUSD(bk.USD),
				fmt.Sprintf("%d / %d", bk.CommitsMine, bk.CommitsAll),
				bk.Added, bk.Deleted, bk.Files,
				fmtRatio(bk.USDPerCommit), fmtRatio(bk.USDPerLine),
			)
		}
		b.WriteString("\n")
	}

	if skipped > 0 {
		b.WriteString(styleDim.Render(fmt.Sprintf("(%d non-git projects skipped)", skipped)) + "\n")
	}
	return b.String()
}
