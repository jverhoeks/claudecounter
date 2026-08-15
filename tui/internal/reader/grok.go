package reader

import (
	"encoding/json"
	"net/url"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

// nanoDollarsPerUSD converts Grok's costUsdTicks. Confirmed by
// elimination against a known billing period: only the nano reading is
// physically possible for one week of usage.
const nanoDollarsPerUSD = 1e9

// grokUsage is the token+cost block Grok emits, at both the turn level
// and once per entry of modelUsage.
//
// inputTokens INCLUDES cachedReadTokens and outputTokens INCLUDES
// reasoningTokens — totalTokens equals inputTokens+outputTokens on every
// live record, which leaves no room for either to be additive. Mapping
// them additively would inflate token charts by roughly the cache-hit
// rate, which on real sessions is most of the input.
type grokUsage struct {
	InputTokens      uint64               `json:"inputTokens"`
	OutputTokens     uint64               `json:"outputTokens"`
	CachedReadTokens uint64               `json:"cachedReadTokens"`
	CostUsdTicks     float64              `json:"costUsdTicks"`
	ModelUsage       map[string]grokUsage `json:"modelUsage"`
}

func (u grokUsage) toUsage() pricing.Usage {
	in := u.InputTokens
	if in >= u.CachedReadTokens {
		in -= u.CachedReadTokens
	} else {
		// Defensive: a vendor that changes the semantics under us must
		// not underflow a uint64 into a nonsense figure.
		in = 0
	}
	return pricing.Usage{
		InputTokens:          in,
		OutputTokens:         u.OutputTokens,
		CacheReadInputTokens: u.CachedReadTokens,
		// Grok reports no cache-creation figure.
		CacheCreationInputTokens: 0,
	}
}

type grokLine struct {
	Timestamp int64 `json:"timestamp"`
	Params    *struct {
		SessionID string `json:"sessionId"`
		Update    *struct {
			SessionUpdate string     `json:"sessionUpdate"`
			PromptID      string     `json:"prompt_id"`
			Usage         *grokUsage `json:"usage"`
		} `json:"update"`
	} `json:"params"`
}

type grokParser struct{}

// Walkable restricts the scan to updates.jsonl. Grok writes other files
// under sessions/, and their _meta.totalTokens is a cumulative per-prompt
// context total, not usage — summing it would be a large silent overcount.
func (grokParser) Walkable(name string) bool { return name == "updates.jsonl" }

// Parse emits one coverage event per turn_completed plus one usage event
// per entry of modelUsage.
//
// The top-level usage block is the sum across modelUsage, so it is used
// only when modelUsage is empty — emitting both would double every
// figure. When modelUsage is absent the model is unknown to us, and the
// cell is recorded under the bare vendor name rather than dropped: a
// turn we cannot attribute to a model is still money spent.
func (p grokParser) Parse(line []byte, slashPath string) ([]Event, error) {
	var l grokLine
	if err := json.Unmarshal(line, &l); err != nil {
		return nil, err
	}
	if l.Params == nil || l.Params.Update == nil {
		return nil, nil
	}
	u := l.Params.Update
	if u.SessionUpdate != "turn_completed" {
		return nil, nil
	}

	ts := time.Unix(l.Timestamp, 0)
	base := Event{
		Timestamp: ts,
		SessionID: l.Params.SessionID,
	}

	cov := base
	cov.CoverageOnly = true
	// A turn counts as covered only when it carries a usable cost. Three
	// records in the live corpus have real tokens and costUsdTicks == 0;
	// treating those as covered would let a known-incomplete figure
	// present itself as complete, which is the exact failure this tally
	// exists to catch.
	cov.HasUsage = u.Usage != nil && u.Usage.CostUsdTicks != 0
	// Coverage events carry no MessageID, so they would slip past the
	// aggregator's dedupe and inflate on any re-scan. prompt_id plus a
	// sentinel reuses that machinery verbatim.
	cov.MessageID = u.PromptID
	cov.RequestID = "coverage"
	out := []Event{cov}

	if u.Usage == nil {
		return out, nil
	}

	emit := func(model string, gu grokUsage) {
		ev := base
		ev.Model = model
		// prompt_id is unique per usage record; pairing it with the
		// model keeps a multi-model turn's cells distinct under the
		// aggregator's existing MessageID:RequestID dedupe.
		ev.MessageID = u.PromptID
		ev.RequestID = model
		ev.Usage = gu.toUsage()
		ev.CostUSD = gu.CostUsdTicks / nanoDollarsPerUSD
		ev.Costed = true
		out = append(out, ev)
	}

	if len(u.Usage.ModelUsage) == 0 {
		emit("grok", *u.Usage)
		return out, nil
	}
	for model, mu := range u.Usage.ModelUsage {
		emit(model, mu)
	}
	return out, nil
}

// Project derives the project key from the session directory, which is
// the percent-encoded working directory. Decoding it and re-encoding the
// Claude way (every '/' and '.' becomes '-') keeps one working directory
// one row in the per-project table no matter which vendor produced the
// spend.
func (grokParser) Project(slashPath string) string { return grokProjectKey(slashPath) }

func grokProjectKey(slashPath string) string {
	idx := strings.Index(slashPath, "/sessions/")
	if idx < 0 {
		return ""
	}
	rest := slashPath[idx+len("/sessions/"):]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		rest = rest[:i]
	}
	decoded, err := url.PathUnescape(rest)
	if err != nil {
		// Undecodable is still a stable key; better a slightly ugly row
		// than a project's spend vanishing into the empty-key bucket.
		decoded = rest
	}
	return strings.NewReplacer("/", "-", ".", "-").Replace(decoded)
}

// IsSubagent flags Grok's per-subagent worktree sessions, which live in
// a directory named subagent-<that session's own id>.
//
// They are counted, not skipped: a parent turn does NOT include its
// subagents' cost. Established on the live corpus 2026-08-15 — parent
// session 01a005ba reports $0.901 across 2 model calls for a turn
// completing 21s after a subagent turn of $1.081 across 16 calls. An
// inclusive parent could not report fewer calls or fewer dollars than
// the child it supposedly contains. (The spec's original probe, which
// found one usage event across eight subagent files, is stale — there
// are now many.)
//
// The match is on the final path segment rather than anywhere in the
// path, so a user whose own worktree happens to be named "subagent-foo"
// does not get their main-session spend filed under the subagent column.
func (grokParser) IsSubagent(slashPath string) bool {
	idx := strings.Index(slashPath, "/sessions/")
	if idx < 0 {
		return false
	}
	rest := slashPath[idx+len("/sessions/"):]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		rest = rest[:i]
	}
	decoded, err := url.PathUnescape(rest)
	if err != nil {
		decoded = rest
	}
	last := decoded
	if i := strings.LastIndexByte(decoded, '/'); i >= 0 {
		last = decoded[i+1:]
	}
	return strings.HasPrefix(last, "subagent-")
}
