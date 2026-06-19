package insights

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

// Category labels a finding's kind.
type Category string

const (
	CatWaste   Category = "waste"
	CatAbuse   Category = "abuse"
	CatSkill   Category = "skill"
	CatContext Category = "context"
	CatLoop    Category = "loop"
	CatSprawl  Category = "sprawl"
	CatRouting Category = "routing"
)

// Finding is one structural observation about a session. USD is an estimated
// wasted-cost attribution where meaningful, else 0.
type Finding struct {
	Category Category `json:"category"`
	Detail   string   `json:"detail"`
	Count    int      `json:"count"`
	USD      float64  `json:"usd,omitempty"`
}

// SessionReport is the full structural analysis of one parsed session.
type SessionReport struct {
	ID          string        `json:"id"`
	Project     string        `json:"project"`
	Cwd         string        `json:"cwd"`
	Model       string        `json:"model"`
	Start       time.Time     `json:"start"`
	End         time.Time     `json:"end"`
	Tokens      pricing.Usage `json:"tokens"`
	USD         float64       `json:"usd"`
	Prompts     int           `json:"prompts"`
	ToolCalls   int           `json:"tool_calls"`
	PeakContext uint64        `json:"peak_context"`
	CtxPct      float64       `json:"ctx_pct"`
	HasPRLink   bool          `json:"has_pr_link"`
	Findings    []Finding     `json:"findings"`
	WasteUSD    float64       `json:"waste_usd"`
	Score       float64       `json:"score"`
}

// Thresholds tune the heuristics. All callers should start from
// DefaultThresholds() and override fields as needed.
type Thresholds struct {
	RepeatToolN   int     // same (Name+Target) called >= N => abuse finding
	LoopMin       int     // a tool subsequence repeated >= N times => loop
	ReadDupN      int     // same Read target read >= N times => waste finding
	CtxHighPct    float64 // peak context >= this % of window => overload finding
	HighCtxTokens uint64  // a turn whose input+cache >= this ...
	TinyOutput    uint64  // ... and whose output <= this is a high-ctx/tiny-out waste

	SprawlPrompts    int     // >= this many prompts => sprawl finding
	SprawlHours      float64 // session duration >= this many hours => sprawl
	RoutingMaxTokens uint64  // a session lighter than this (in+out) ...
	RoutingMaxTools  int     // ... and with <= this many tool calls on Opus => routing
}

// DefaultThresholds returns conservative starting values; see the design spec
// — these are tuned-by-experience starting points, not laws.
func DefaultThresholds() Thresholds {
	return Thresholds{
		RepeatToolN:      3,
		LoopMin:          3,
		ReadDupN:         2,
		CtxHighPct:       80,
		HighCtxTokens:    50_000,
		TinyOutput:       100,
		SprawlPrompts:    60,
		SprawlHours:      4,
		RoutingMaxTokens: 20_000,
		RoutingMaxTools:  5,
	}
}

const skillOverloadDistinct = 3 // > this many distinct skills in one session is a smell

// newTokenUSD prices only the genuinely-new tokens of a turn (input +
// cache-creation + output), excluding cache-read. Cache-read is the cheap,
// intended path for continuing a long conversation — attributing it as "waste"
// would flag every turn of a healthy cached session. All waste estimates use
// this so the dollar figures reflect avoidable spend, not unavoidable reuse.
func newTokenUSD(table pricing.Table, model string, u pricing.Usage) float64 {
	return table.Cost(model, pricing.Usage{
		InputTokens:              u.InputTokens,
		CacheCreationInputTokens: u.CacheCreationInputTokens,
		OutputTokens:             u.OutputTokens,
	})
}

// avgTurnNewUSD is the session's mean new-token cost per turn (0 if none).
func avgTurnNewUSD(s *session.Session, table pricing.Table) float64 {
	if len(s.Turns) == 0 {
		return 0
	}
	var total float64
	for _, t := range s.Turns {
		total += newTokenUSD(table, t.Model, t.Usage)
	}
	return total / float64(len(s.Turns))
}

func wasteFindings(s *session.Session, table pricing.Table, th Thresholds) []Finding {
	var out []Finding

	// 1. Failed tool calls.
	failed := 0
	for _, c := range s.ToolCalls {
		if c.IsErr {
			failed++
		}
	}
	if failed > 0 {
		out = append(out, Finding{
			Category: CatWaste,
			Detail:   fmt.Sprintf("%d failed tool call(s) — each burns a round-trip", failed),
			Count:    failed,
			USD:      avgTurnNewUSD(s, table) * float64(failed),
		})
	}

	// 2. Redundant reads of the same target.
	reads := map[string]int{}
	for _, c := range s.ToolCalls {
		if c.Name == "Read" && c.Target != "" {
			reads[c.Target]++
		}
	}
	extra := 0
	files := 0
	for _, n := range reads {
		if n >= th.ReadDupN {
			extra += n - 1
			files++
		}
	}
	if extra > 0 {
		out = append(out, Finding{
			Category: CatWaste,
			Detail:   fmt.Sprintf("%d redundant Read(s) across %d file(s)", extra, files),
			Count:    extra,
		})
	}

	// 3. High-NEW-context / tiny-output turns. Trigger on input+cache_create
	// (the tokens freshly fed this turn), NOT cache_read — a turn that drags a
	// big cached conversation forward while emitting a small tool-call block is
	// the normal, healthy pattern, not waste. This fires only when a turn
	// injects a lot of *new* content and gets almost nothing back.
	hc := 0
	var hcUSD float64
	for _, t := range s.Turns {
		newCtx := t.Usage.InputTokens + t.Usage.CacheCreationInputTokens
		if newCtx >= th.HighCtxTokens && t.Usage.OutputTokens <= th.TinyOutput {
			hc++
			hcUSD += newTokenUSD(table, t.Model, t.Usage)
		}
	}
	if hc > 0 {
		out = append(out, Finding{
			Category: CatWaste,
			Detail:   fmt.Sprintf("%d turn(s) injected big new context but produced tiny output", hc),
			Count:    hc,
			USD:      hcUSD,
		})
	}
	return out
}

func abuseFindings(s *session.Session, th Thresholds) []Finding {
	type key struct{ name, target string }
	counts := map[key]int{}
	for _, c := range s.ToolCalls {
		counts[key{c.Name, c.Target}]++
	}
	var out []Finding
	// Stable order: emit worst (highest count) first.
	type kc struct {
		k key
		n int
	}
	var rows []kc
	for k, n := range counts {
		if n >= th.RepeatToolN && k.target != "" {
			rows = append(rows, kc{k, n})
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].n != rows[j].n {
			return rows[i].n > rows[j].n
		}
		return rows[i].k.name+rows[i].k.target < rows[j].k.name+rows[j].k.target
	})
	// Cap the detailed rows — a hot session can repeat hundreds of distinct
	// targets, which would flood every output. Keep the worst, roll up the rest.
	for i, r := range rows {
		if i >= maxAbuseRows {
			extra := 0
			for _, rr := range rows[i:] {
				extra += rr.n
			}
			out = append(out, Finding{
				Category: CatAbuse,
				Detail:   fmt.Sprintf("…and %d more repeated-call pattern(s) (%d calls)", len(rows)-i, extra),
				Count:    len(rows) - i,
			})
			break
		}
		out = append(out, Finding{
			Category: CatAbuse,
			Detail:   fmt.Sprintf("%s %q called %d×", r.k.name, trunc(r.k.target, 60), r.n),
			Count:    r.n,
		})
	}
	return out
}

const maxAbuseRows = 8

func skillFindings(s *session.Session) []Finding {
	distinct := map[string]struct{}{}
	for _, c := range s.ToolCalls {
		if c.Name == "Skill" && c.Target != "" {
			distinct[c.Target] = struct{}{}
		}
	}
	if len(distinct) <= skillOverloadDistinct {
		return nil
	}
	return []Finding{{
		Category: CatSkill,
		Detail:   fmt.Sprintf("%d distinct skills invoked in one session", len(distinct)),
		Count:    len(distinct),
	}}
}

// trunc shortens s to n runes with an ellipsis.
func trunc(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// sprawlFindings flags sessions that ran too long or accumulated too many
// prompt-turns — a signal to split work into focused sessions or delegate to
// subagents.
func sprawlFindings(s *session.Session, th Thresholds) []Finding {
	hours := s.End.Sub(s.Start).Hours()
	if s.Prompts < th.SprawlPrompts && hours < th.SprawlHours {
		return nil
	}
	return []Finding{{
		Category: CatSprawl,
		Detail: fmt.Sprintf("long session: %d prompts over %.1fh — consider splitting or delegating to subagents",
			s.Prompts, hours),
		Count: s.Prompts,
	}}
}

// routingFindings flags a light session that ran on Opus, where a cheaper
// model (Sonnet/Haiku) or Fast mode would likely have sufficed.
func routingFindings(s *session.Session, model string, th Thresholds) []Finding {
	if !strings.Contains(model, "opus") {
		return nil
	}
	work := s.Tokens.InputTokens + s.Tokens.OutputTokens
	if work >= th.RoutingMaxTokens || len(s.ToolCalls) > th.RoutingMaxTools {
		return nil
	}
	return []Finding{{
		Category: CatRouting,
		Detail:   "light session ran on Opus — Sonnet/Haiku or Fast mode may suffice",
		Count:    1,
	}}
}

// dominantModel returns the model with the most turns (empty if none).
func dominantModel(s *session.Session) string {
	counts := map[string]int{}
	for _, t := range s.Turns {
		counts[t.Model]++
	}
	best, bestN := "", 0
	for m, n := range counts {
		if n > bestN || (n == bestN && (best == "" || m < best)) {
			best, bestN = m, n
		}
	}
	return best
}

// AnalyzeSession runs every structural heuristic over one parsed session and
// returns a single report. Pure: no I/O, no clock.
func AnalyzeSession(s *session.Session, table pricing.Table, th Thresholds) SessionReport {
	model := dominantModel(s)
	var usd float64
	for _, t := range s.Turns {
		usd += table.Cost(t.Model, t.Usage)
	}

	r := SessionReport{
		ID:          s.ID,
		Cwd:         s.Cwd,
		Model:       model,
		Start:       s.Start,
		End:         s.End,
		Tokens:      s.Tokens,
		USD:         usd,
		Prompts:     s.Prompts,
		ToolCalls:   len(s.ToolCalls),
		PeakContext: s.PeakContext,
		HasPRLink:   s.HasPRLink,
	}

	if win := EffectiveWindow(model, s.PeakContext); win > 0 {
		r.CtxPct = 100 * float64(s.PeakContext) / float64(win)
		// A handful of usage lines aggregate internal iterations, so the
		// per-line token sum can exceed the real window. Clamp rather than
		// print an impossible >100% (the raw peak token count stays in JSON).
		if r.CtxPct > 100 {
			r.CtxPct = 100
		}
	}

	r.Findings = append(r.Findings, wasteFindings(s, table, th)...)
	r.Findings = append(r.Findings, abuseFindings(s, th)...)
	r.Findings = append(r.Findings, skillFindings(s)...)
	r.Findings = append(r.Findings, loopFindings(s, th)...)
	r.Findings = append(r.Findings, sprawlFindings(s, th)...)
	r.Findings = append(r.Findings, routingFindings(s, model, th)...)
	if r.CtxPct >= th.CtxHighPct {
		r.Findings = append(r.Findings, Finding{
			Category: CatContext,
			Detail:   fmt.Sprintf("peak context %.0f%% of %s window", r.CtxPct, model),
			Count:    1,
		})
	}

	for _, f := range r.Findings {
		r.WasteUSD += f.USD
	}
	r.Score = r.WasteUSD + float64(len(r.Findings))
	return r
}
