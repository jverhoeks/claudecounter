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

// reportHeader renders the fixed (non-scrolling) title + key-hint lines that
// sit above the scrollable viewport.
func reportHeader(days int, size report.BucketSize) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n",
		styleHead.Render(fmt.Sprintf("Git activity & ROI — last %d days, by %s", days, bucketName(size))))
	b.WriteString(styleDim.Render("d/w/m: bucket   [/]: window   ↑/↓ PgUp/PgDn g/G: scroll   ratios are temporal, not causal") + "\n\n")
	return b.String()
}

// emptyReportLine is shown when the report resolved no git repos.
func emptyReportLine(skipped int) string {
	if skipped > 0 {
		return fmt.Sprintf("  No git activity found. %d project dirs were not git repos, or git is unavailable.\n", skipped)
	}
	return "  No git activity found for projects in this window.\n"
}

// reportTables renders the scrollable per-repo body (no header). This is the
// string fed into the viewport.
func reportTables(reports []report.RepoReport, skipped int) string {
	var b strings.Builder
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
