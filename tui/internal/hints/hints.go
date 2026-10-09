// Package hints turns request samples into a short list of "this is
// costing you $X — here is the one-line fix" cards. A port of the
// macapp's Hints.swift.
//
// Each rule prices its own counterfactual from the logs at the pricing
// table's rates (flat, so the long-context premium is not included —
// estimates run low for 200k+ turns). The savings overlap (compacting
// earlier also shrinks resume rewrites), so callers must not add them up.
//
// Rules read ~/.claude/settings.json to say whether a fix is already in
// place. Read-only: nothing here ever writes the user's Claude settings.
package hints

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/perf"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

type Kind string

const (
	Compact       Kind = "compact"
	Resume        Kind = "resume"
	CacheTTL      Kind = "cacheTTL"
	SubagentModel Kind = "subagentModel"
	MainModel     Kind = "mainModel"
	Effort        Kind = "effort"
)

type Hint struct {
	ID    Kind   `json:"id"`
	Title string `json:"title"`
	// Finding is what the logs show, with the numbers.
	Finding string `json:"finding"`
	// SavingUSD is the estimated saving over the period, at API prices.
	SavingUSD float64 `json:"savingUSD"`
	// Fix is what to do, in a sentence.
	Fix string `json:"fix"`
	// Snippet is a copyable settings fragment or command ("" = none).
	Snippet string `json:"snippet"`
	// Caveat is the trade-off to weigh before applying.
	Caveat string `json:"caveat"`
	// Applied is non-empty when the user's settings already contain the fix.
	Applied string `json:"applied"`
}

// Settings is the handful of Claude Code settings the hints check against.
type Settings struct {
	AutoCompactWindow *int
	PromptCacheTTL    string
	SubagentModel     string
	Model             string
	EffortLevel       string
	ModelEffort       map[string]string
}

func UserSettingsPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "settings.json")
}

// LoadSettings reads path; a missing or unreadable file is an empty
// snapshot (nothing applied).
func LoadSettings(path string) Settings {
	data, err := os.ReadFile(path)
	if err != nil {
		return Settings{}
	}
	// Key by key, like the macapp: one odd value must not blank the rest.
	var obj map[string]any
	if json.Unmarshal(data, &obj) != nil {
		return Settings{}
	}
	str := func(m map[string]any, k string) string {
		s, _ := m[k].(string)
		return s
	}
	env, _ := obj["env"].(map[string]any)
	s := Settings{
		Model:         str(obj, "model"),
		EffortLevel:   str(obj, "effortLevel"),
		SubagentModel: str(env, "CLAUDE_CODE_SUBAGENT_MODEL"),
	}
	if f, ok := obj["autoCompactWindow"].(float64); ok {
		v := int(f)
		s.AutoCompactWindow = &v
	} else if v, err := strconv.Atoi(str(env, "CLAUDE_CODE_AUTO_COMPACT_WINDOW")); err == nil {
		s.AutoCompactWindow = &v
	}
	if v, ok := obj["promptCacheTtl"].(string); ok {
		s.PromptCacheTTL = v
	} else {
		s.PromptCacheTTL = str(env, "CLAUDE_CODE_PROMPT_CACHE_TTL")
	}
	ms, _ := obj["modelSettings"].(map[string]any)
	for m, v := range ms {
		if e := str(asMap(v), "effortLevel"); e != "" {
			if s.ModelEffort == nil {
				s.ModelEffort = map[string]string{}
			}
			s.ModelEffort[m] = e
		}
	}
	return s
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

// EffortFor is the effective effort for model: per-model setting, else
// global.
func (s Settings) EffortFor(model string) string {
	if e, ok := s.ModelEffort[model]; ok {
		return e
	}
	return s.EffortLevel
}

// MinSaving is the threshold below which a hint is noise, not advice.
const MinSaving = 2.0

// InPeriod returns the samples from the last days days.
func InPeriod(all []perf.Sample, days int, now time.Time) []perf.Sample {
	start := now.Add(-time.Duration(days) * 24 * time.Hour)
	var out []perf.Sample
	for _, x := range all {
		if !x.Time.Before(start) {
			out = append(out, x)
		}
	}
	return out
}

// Spend is what the samples cost at the table's prices.
func Spend(s []perf.Sample, p pricing.Table) float64 {
	total := 0.0
	for _, x := range s {
		total += x.Cost(p)
	}
	return total
}

// Build runs every rule over the last days days and returns the hints
// worth showing, biggest saving first.
func Build(all []perf.Sample, p pricing.Table, cfg Settings, days int, now time.Time) []Hint {
	s := InPeriod(all, days, now)
	if len(s) == 0 {
		return nil
	}
	var out []Hint
	for _, h := range []*Hint{
		compact(s, p, cfg), resume(s, p), cacheTTL(s, p, cfg),
		subagentModel(s, p, cfg), mainModel(s, p, cfg), effort(s, p, cfg),
	} {
		if h != nil && h.SavingUSD >= MinSaving {
			out = append(out, *h)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].SavingUSD > out[j].SavingUSD })
	return out
}

// rates is USD per token for one token kind, via the public cost function.
type rates struct{ input, output, read, write5m, write1h float64 }

func ratesFor(model string, p pricing.Table) rates {
	one := func(u pricing.Usage) float64 { return p.Cost(model, u) / 1_000_000 }
	return rates{
		input:   one(pricing.Usage{InputTokens: 1_000_000}),
		output:  one(pricing.Usage{OutputTokens: 1_000_000}),
		read:    one(pricing.Usage{CacheReadInputTokens: 1_000_000}),
		write5m: one(pricing.Usage{CacheCreationInputTokens: 1_000_000}),
		write1h: one(pricing.Usage{CacheCreationInputTokens: 1_000_000, CacheCreation1hInputTokens: 1_000_000}),
	}
}

func mainSessions(s []perf.Sample) [][]perf.Sample {
	by := map[string][]perf.Sample{}
	var order []string
	for _, x := range s {
		if x.IsSubagent {
			continue
		}
		if _, ok := by[x.Session]; !ok {
			order = append(order, x.Session)
		}
		by[x.Session] = append(by[x.Session], x)
	}
	out := make([][]perf.Sample, 0, len(order))
	for _, k := range order {
		rows := by[k]
		sort.SliceStable(rows, func(i, j int) bool { return rows[i].Time.Before(rows[j].Time) })
		out = append(out, rows)
	}
	return out
}

func usd(v float64) string {
	if v >= 100 {
		return fmt.Sprintf("$%.0f", v)
	}
	return fmt.Sprintf("$%.2f", v)
}

func k(v float64) string { return fmt.Sprintf("%.0fk", v/1000) }

func short(m string) string { return strings.TrimPrefix(m, "claude-") }

func median(xs []float64) (float64, bool) { return perf.Quantile(xs, 0.5) }

// compactSaving replays each main session's context growth with
// auto-compact at limit: past it, one summary call reads the window and
// the session carries on from base. Both versions are priced with the
// same read-prefix / write-growth / output model, so the difference is
// fair even where that model is rough.
func compactSaving(sessions [][]perf.Sample, p pricing.Table, limit float64) (float64, int) {
	const base, summary = 40_000.0, 5_000.0
	saved, n := 0.0, 0
	for _, rows := range sessions {
		r := ratesFor(rows[0].Model, p)
		turn := func(prev, cur, out float64) float64 {
			return min(prev, cur)*r.read + max(cur-prev, 0)*r.write1h + out*r.output
		}
		var prevA, prevS, a, b float64
		for _, x := range rows {
			ctx, out := float64(x.Context), float64(x.Output)
			a += turn(prevA, ctx, out)
			grow := 0.0
			if ctx >= prevA {
				grow = ctx - prevA
			}
			var sim float64
			if ctx >= prevA {
				sim = prevS + grow
			} else {
				sim = min(prevS, ctx) // a real /compact or /clear resets too
			}
			if sim > limit {
				b += turn(prevS, prevS, summary) + base*r.write1h
				n++
				prevS = base
				sim = base + grow
			}
			b += turn(prevS, sim, out)
			prevA, prevS = ctx, sim
		}
		saved += a - b
	}
	return saved, n
}

func compact(s []perf.Sample, p pricing.Table, cfg Settings) *Hint {
	var ctxs []float64
	peak := 0.0
	for _, x := range s {
		if !x.IsSubagent {
			ctxs = append(ctxs, float64(x.Context))
			peak = max(peak, float64(x.Context))
		}
	}
	med, ok := median(ctxs)
	if !ok || med <= 120_000 {
		return nil
	}
	total, big := 0.0, 0.0
	for _, x := range s {
		c := x.Cost(p)
		total += c
		if x.Context > 200_000 {
			big += c
		}
	}
	share := 0
	if total > 0 {
		share = int(big / total * 100)
	}
	saving, n := compactSaving(mainSessions(s), p, 190_000)
	applied := ""
	if w := cfg.AutoCompactWindow; w != nil && *w <= 250_000 {
		applied = fmt.Sprintf("autoCompactWindow is %s — new sessions compact early; this period's spend is from before.", k(float64(*w)))
	}
	return &Hint{
		ID: Compact, Title: "Compact before the context gets huge",
		Finding: fmt.Sprintf("Main-session turns ran at a median %s context (peak %s); %d%% of spend went on turns above 200k. Every turn re-reads the whole context.",
			k(med), k(peak), share),
		SavingUSD: saving,
		Fix:       fmt.Sprintf("Auto-compact at 200k instead of Opus 5.5's ~967k default (about %d compactions in this period), or /compact at natural breakpoints.", n),
		Snippet:   `"autoCompactWindow": 200000`,
		Caveat:    "Compaction replaces history with a summary; long intricate sessions can lose earlier decisions.",
		Applied:   applied,
	}
}

func resume(s []perf.Sample, p pricing.Table) *Hint {
	var writes []float64
	cost := 0.0
	for _, x := range s {
		if x.Rebuild != perf.RebuildAfterIdle {
			continue
		}
		// What the cache rewrite cost, minus what writing a fresh 40k
		// start would have.
		r := ratesFor(x.Model, p)
		w1 := float64(x.CacheWrite1h)
		w5 := float64(x.CacheWrite) - w1
		fresh := min(float64(x.CacheWrite), 40_000) * r.write1h
		cost += max(w1*r.write1h+w5*r.write5m-fresh, 0)
		writes = append(writes, float64(x.CacheWrite))
	}
	if len(writes) < 3 {
		return nil
	}
	med, _ := median(writes)
	return &Hint{
		ID: Resume, Title: "Don't resume big sessions after a break",
		Finding: fmt.Sprintf("%d times a session sat idle over an hour and the whole cache (median %s tokens) was written again at the cache-write rate.",
			len(writes), k(med)),
		SavingUSD: cost,
		Fix:       "Before stepping away, run /compact so less has to be rewritten; after a long break, /clear and continue from a short handoff note.",
		Snippet:   "/compact",
		Caveat:    "A fresh start loses whatever the handoff note doesn't capture.",
	}
}

func cacheTTL(s []perf.Sample, p pricing.Table, cfg Settings) *Hint {
	waste, bridged := 0.0, 0.0
	quick, total1h := 0, 0
	for _, rows := range mainSessions(s) {
		for i := 0; i+1 < len(rows); i++ {
			a, b := rows[i], rows[i+1]
			if a.CacheWrite1h == 0 {
				continue
			}
			r := ratesFor(a.Model, p)
			gap := b.Time.Sub(a.Time)
			total1h++
			if gap < 5*time.Minute {
				// A 5-minute write would have been read in time.
				waste += float64(a.CacheWrite1h) * (r.write1h - r.write5m)
				quick++
			} else if gap < time.Hour {
				// Here the 1h TTL avoided rewriting what b read.
				bridged += float64(b.CacheRead) * (r.write5m - r.read)
			}
		}
	}
	if total1h == 0 || waste <= 2*bridged {
		return nil
	}
	applied := ""
	if cfg.PromptCacheTTL == "5m" {
		applied = "promptCacheTtl is 5m."
	}
	return &Hint{
		ID: CacheTTL, Title: "Use the 5-minute prompt cache",
		Finding: fmt.Sprintf("%d%% of 1-hour cache writes were read again within 5 minutes, so the cheaper 5-minute cache would have done. The 1-hour TTL bridged longer pauses worth only ~%s.",
			int(float64(quick)/float64(total1h)*100), usd(bridged)),
		SavingUSD: waste - bridged,
		Fix:       "Set the main conversation's cache TTL to 5 minutes (1h is the automatic choice on a subscription).",
		Snippet:   `"promptCacheTtl": "5m"`,
		Caveat:    "Any pause over 5 minutes then means rewriting the cache.",
		Applied:   applied,
	}
}

const cheapSubagentModel = "claude-sonnet-5"

func subagentModel(s []perf.Sample, p pricing.Table, cfg Settings) *Hint {
	cheap := ratesFor(cheapSubagentModel, p).input
	if cheap <= 0 {
		return nil
	}
	saving, spend := 0.0, 0.0
	byModel := map[string]float64{}
	for _, x := range s {
		if !x.IsSubagent {
			continue
		}
		c, r := x.Cost(p), ratesFor(x.Model, p).input
		if r <= cheap {
			continue
		}
		spend += c
		byModel[x.Model] += c
		saving += c * (1 - cheap/r)
	}
	if spend <= 0 {
		return nil
	}
	applied := ""
	if cfg.SubagentModel != "" {
		applied = fmt.Sprintf("CLAUDE_CODE_SUBAGENT_MODEL is %s.", cfg.SubagentModel)
	}
	return &Hint{
		ID: SubagentModel, Title: "Run subagents on Sonnet",
		Finding: fmt.Sprintf("Subagents spent %s on models pricier than Sonnet (%s). Most subagent work is search and summarising.",
			usd(spend), topSpend(byModel, 3)),
		SavingUSD: saving,
		Fix:       "Default subagents to Sonnet; give a specific agent a bigger model in its frontmatter (model: opus) when it needs one.",
		Snippet:   fmt.Sprintf(`"env": { "CLAUDE_CODE_SUBAGENT_MODEL": "%s" }`, cheapSubagentModel),
		Caveat:    "Harder delegated tasks (reviews, design) may do worse on a smaller model.",
		Applied:   applied,
	}
}

func topSpend(by map[string]float64, n int) string {
	type kv struct {
		k string
		v float64
	}
	var xs []kv
	for k, v := range by {
		xs = append(xs, kv{k, v})
	}
	sort.Slice(xs, func(i, j int) bool { return xs[i].v > xs[j].v })
	var parts []string
	for i, x := range xs {
		if i == n {
			break
		}
		parts = append(parts, short(x.k)+" "+usd(x.v))
	}
	return strings.Join(parts, ", ")
}

func mainModel(s []perf.Sample, p pricing.Table, cfg Settings) *Hint {
	// The cheapest Opus actually in use is the reference; anything over
	// 1.5× its input price is "premium".
	ref, refIn := "", 0.0
	seen := map[string]bool{}
	for _, x := range s {
		if x.IsSubagent || seen[x.Model] || !strings.Contains(x.Model, "opus") {
			continue
		}
		seen[x.Model] = true
		in := ratesFor(x.Model, p).input
		if ref == "" || in < refIn || (in == refIn && x.Model < ref) {
			ref, refIn = x.Model, in
		}
	}
	if ref == "" || refIn <= 0 {
		return nil
	}
	spend, saving, n := 0.0, 0.0, 0
	names := map[string]bool{}
	for _, x := range s {
		if x.IsSubagent {
			continue
		}
		r := ratesFor(x.Model, p).input
		if r <= 1.5*refIn {
			continue
		}
		c := x.Cost(p)
		spend += c
		saving += c * (1 - refIn/r)
		n++
		names[short(x.Model)] = true
	}
	if n == 0 {
		return nil
	}
	var list []string
	for m := range names {
		list = append(list, m)
	}
	sort.Strings(list)
	applied := ""
	if cfg.Model == ref {
		applied = fmt.Sprintf("model is %s.", ref)
	}
	return &Hint{
		ID: MainModel, Title: fmt.Sprintf("Keep %s as the default model", short(ref)),
		Finding: fmt.Sprintf("%d main-session requests (%s) ran on %s, at over 1.5× %s's price per token.",
			n, usd(spend), strings.Join(list, ", "), short(ref)),
		SavingUSD: saving,
		Fix:       fmt.Sprintf("Make %s the default and switch with /model only for the problems that need the bigger model.", short(ref)),
		Snippet:   fmt.Sprintf(`"model": "%s"`, ref),
		Caveat:    "The bigger model may solve hard problems in fewer turns; switch per task rather than never.",
		Applied:   applied,
	}
}

func effort(s []perf.Sample, p pricing.Table, cfg Settings) *Hint {
	var high []perf.Sample
	var hiOuts, medOuts []float64
	for _, x := range s {
		switch x.Effort {
		case "high", "xhigh":
			high = append(high, x)
			hiOuts = append(hiOuts, float64(x.Output))
		case "medium":
			medOuts = append(medOuts, float64(x.Output))
		}
	}
	// Need both sides to measure what dropping a level does to output.
	if len(high) < 200 || len(medOuts) < 200 {
		return nil
	}
	hiOut, _ := median(hiOuts)
	medOut, _ := median(medOuts)
	if hiOut <= medOut {
		return nil
	}
	shrink := 1 - medOut/hiOut
	saving := 0.0
	byModel := map[string]int{}
	for _, x := range high {
		saving += float64(x.Output) * ratesFor(x.Model, p).output * shrink
		byModel[x.Model]++
	}
	top, topN := "", -1
	for m, n := range byModel {
		if n > topN || (n == topN && m < top) {
			top, topN = m, n
		}
	}
	applied := ""
	if cfg.EffortFor(top) == "medium" {
		applied = fmt.Sprintf("%s is set to medium.", short(top))
	}
	return &Hint{
		ID: Effort, Title: "Lower the effort level",
		Finding: fmt.Sprintf("%d requests ran at high/xhigh effort (mostly %s). They produced a median %d output tokens vs %d at medium.",
			len(high), short(top), int(hiOut), int(medOut)),
		SavingUSD: saving,
		Fix:       fmt.Sprintf("Run %s at medium by default and raise it with /effort for hard problems.", short(top)),
		Snippet:   fmt.Sprintf(`"modelSettings": { "%s": { "effortLevel": "medium" } }`, top),
		Caveat:    "Only counts output tokens; harder problems may need the extra thinking.",
		Applied:   applied,
	}
}

// Disclaimer is shown above the cards on every surface.
const Disclaimer = "Estimates from your session logs, at flat API prices (no long-context premium, so turns above 200k run a little higher). Savings overlap — compacting earlier also shrinks resume rewrites — so don't add them up. Fixes are settings for ~/.claude/settings.json; this app only reads that file."

// Periods are the period picker's choices, in days.
var Periods = []int{7, 30, 90}

// PerMonth scales a saving over days to 30 days.
func PerMonth(saving float64, days int) float64 { return saving * 30 / float64(max(days, 1)) }
