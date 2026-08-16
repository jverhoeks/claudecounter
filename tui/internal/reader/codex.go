package reader

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

// codexFallbackModel resolves the model for a session that never emits
// thread_settings_applied — 25 of 74 files in the corpus probed on
// 2026-08-16, from an older CLI. parent_thread_id discriminates them
// exactly: across all 49 sessions that DO declare, no-parent always
// meant gpt-5.6-sol (25 files) and has-parent always meant
// codex-auto-review (24 files), with zero exceptions.
//
// Data, not logic, because these mappings are as much a moving target as
// pricing.modelAliases, which resolves codex-auto-review's pricing the
// same way, for the same reason.
var codexFallbackModel = map[bool]string{false: "gpt-5.6-sol", true: "codex-auto-review"}

// codexModelForSession resolves the model in effect for one token_count
// event. A declared thread_settings.model always wins; only a session
// that has declared none at all falls back to codexFallbackModel, keyed
// on whether session_meta carried a parent_thread_id.
func codexModelForSession(declared string, hasParent bool) string {
	if declared != "" {
		return declared
	}
	return codexFallbackModel[hasParent]
}

// codexTokenUsage mirrors info.total_token_usage (and, identically
// shaped, info.last_token_usage, which this parser never reads — see
// codexParser.deltaEvent). Verified on live records: total_tokens ==
// input_tokens + output_tokens, so cached_input_tokens is a subset of
// input_tokens and reasoning_output_tokens a subset of output_tokens.
// reasoning_output_tokens is therefore never added on top of
// output_tokens.
type codexTokenUsage struct {
	InputTokens           uint64 `json:"input_tokens"`
	CachedInputTokens     uint64 `json:"cached_input_tokens"`
	OutputTokens          uint64 `json:"output_tokens"`
	ReasoningOutputTokens uint64 `json:"reasoning_output_tokens"`
	TotalTokens           uint64 `json:"total_tokens"`
}

// codexLine mirrors the three top-level record shapes a rollout file
// mixes: session_meta (once, carrying cwd and parent_thread_id),
// event_msg (carrying, among other things, token_count and
// thread_settings_applied), and turn_context (carries neither a model
// nor usage and is otherwise ignored). payload is left raw because its
// shape depends on type.
type codexLine struct {
	Timestamp time.Time       `json:"timestamp"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

// codexSessionMetaPayload is session_meta's payload. It appears once,
// normally as line 1, and is the only source of the session's working
// directory — see codexParser.Project for why the path itself cannot
// supply it.
type codexSessionMetaPayload struct {
	SessionID      string `json:"session_id"`
	Cwd            string `json:"cwd"`
	ParentThreadID string `json:"parent_thread_id"`
}

// codexEventMsgPayload is event_msg's payload. Only two of its `type`
// values matter here: token_count (carries info.total_token_usage) and
// thread_settings_applied (carries thread_settings.model). Any other
// value — turn events, reasoning summaries, etc. — carries neither and
// is ignored.
type codexEventMsgPayload struct {
	Type string `json:"type"`
	Info *struct {
		TotalTokenUsage *codexTokenUsage `json:"total_token_usage"`
	} `json:"info"`
	ThreadSettings *struct {
		Model string `json:"model"`
	} `json:"thread_settings"`
}

// codexParser is stateful, unlike claudeParser and grokParser: a delta
// needs the previous cumulative reading, the model needs the last
// thread_settings_applied, and the project and subagent flag come from
// session_meta, which appears only on line 1. None of that can be
// recovered from a single line in isolation.
//
// Lifecycle (the owning Reader's responsibility — see Task 3):
//   - One codexParser per file path, kept alive for as long as the
//     Reader tracks that path.
//   - Parse is called once per line, in file order. OnChange may resume
//     a growing file mid-stream from a byte offset on a later call;
//     reusing the SAME codexParser instance across those calls is what
//     keeps the running totals and declared model correct. Using a
//     fresh parser per call would make every resumed read's first delta
//     equal to the session's entire total-so-far — a large silent
//     over-count that grows with activity — and would forget
//     session_meta, losing project and subagent attribution for the
//     rest of the file.
//   - Reset must be called, and the zero value substituted, whenever a
//     path starts being read from byte offset 0 for a reason OTHER than
//     "we have never seen this path before": specifically, when the
//     underlying file has shrunk or been replaced. A fresh path needs no
//     explicit reset — its codexParser is simply constructed as a zero
//     value.
//   - Never share one codexParser instance across two different paths:
//     it would attribute one session's totals, model, and cwd to
//     another.
type codexParser struct {
	// running totals from the most recently seen token_count reading;
	// meaningful only when havePrev is true.
	havePrev   bool
	prevInput  uint64
	prevCached uint64
	prevOutput uint64
	prevTotal  uint64
	model      string // most recent declared thread_settings.model; "" if none yet
	cwd        string // from session_meta; "" until seen
	sessionID  string // from session_meta; "" until seen
	hasParent  bool   // parent_thread_id was present on session_meta
}

// Reset discards all per-file state. Call it (and only it — never
// construct a new codexParser mid-file) when the Reader starts reading
// a previously-seen path from byte offset 0 again, i.e. the file
// shrank or was replaced. See the type's doc comment for the full
// lifecycle.
func (p *codexParser) Reset() {
	*p = codexParser{}
}

// Walkable restricts the scan to rollout files. Codex writes other
// bookkeeping under ~/.codex/sessions that carries neither a model nor
// usage.
func (*codexParser) Walkable(name string) bool {
	return strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, ".jsonl")
}

// Parse turns one rollout line into zero or one usage events. A
// malformed line is a parse error; every recognised-but-irrelevant line
// (turn_context, an event_msg whose payload is neither token_count nor
// thread_settings_applied, a token_count with no total_token_usage)
// yields nothing without erroring.
func (p *codexParser) Parse(line []byte, _ string) ([]Event, error) {
	var l codexLine
	if err := json.Unmarshal(line, &l); err != nil {
		return nil, err
	}

	switch l.Type {
	case "session_meta":
		var meta codexSessionMetaPayload
		if err := json.Unmarshal(l.Payload, &meta); err != nil {
			return nil, err
		}
		p.cwd = meta.Cwd
		p.sessionID = meta.SessionID
		p.hasParent = meta.ParentThreadID != ""
		return nil, nil

	case "event_msg":
		var ev codexEventMsgPayload
		if err := json.Unmarshal(l.Payload, &ev); err != nil {
			return nil, err
		}
		switch ev.Type {
		case "thread_settings_applied":
			if ev.ThreadSettings != nil && ev.ThreadSettings.Model != "" {
				p.model = ev.ThreadSettings.Model
			}
			return nil, nil
		case "token_count":
			if ev.Info == nil || ev.Info.TotalTokenUsage == nil {
				// total_token_usage absent: skip the event but leave the
				// running total untouched, so the next reading still
				// deltas against the last real one.
				return nil, nil
			}
			return p.deltaEvent(*ev.Info.TotalTokenUsage, l.Timestamp), nil
		default:
			return nil, nil
		}

	default:
		// turn_context and anything else carries no model and no usage.
		return nil, nil
	}
}

// saturatingSub returns a-b, clamped to 0 rather than wrapping, mirroring
// grokUsage.toUsage's defensive subtraction. Every caller here is
// subtracting two values this parser has already reasoned should not
// invert; the clamp exists for the case where that reasoning is wrong,
// because these are uint64s and a wrong number here is not a slightly
// wrong number — it is a wraparound to near 2^64 flowing straight into
// a dollar figure.
func saturatingSub(a, b uint64) uint64 {
	if a < b {
		return 0
	}
	return a - b
}

// deltaEvent is the central rule this parser exists to implement:
// total_token_usage is cumulative per session and was verified
// monotonic in 69 of 69 corpus files, so consecutive differences
// telescope to the session's final total exactly. Summing
// last_token_usage instead overshoots it by 0.86% corpus-wide, which is
// what the superseded design tried to fix with a dedupe key that does
// not exist in the data.
//
// A repeated reading yields a zero delta and is dropped, which is why
// no dedupe key is needed. A decrease means the session restarted its
// counter: adopt the new value and contribute nothing, because a
// negative cell would be a wrong number rather than a missing one.
//
// Day attribution is the local day of THIS event — the closing reading
// — via the timestamp the caller passes in, per the design's rule that
// a delta belongs to whichever event reports the new total.
func (p *codexParser) deltaEvent(cur codexTokenUsage, ts time.Time) []Event {
	first := !p.havePrev
	decreased := p.havePrev && cur.TotalTokens < p.prevTotal

	var deltaInput, deltaCached, deltaOutput uint64
	switch {
	case first:
		// The session's first reading deltas against an implicit
		// baseline of zero, i.e. it is its own value.
		deltaInput, deltaCached, deltaOutput = cur.InputTokens, cur.CachedInputTokens, cur.OutputTokens
	case decreased:
		// Restart: adopt the new reading as the running total but
		// contribute nothing. Handled below after the totals are saved.
	default:
		// Saturating, not plain subtraction, even though the total_tokens
		// check above already ruled out a whole-session decrease: these
		// are uint64s, and the guard here is against a subfield
		// decreasing while the total does not (never observed in the
		// corpus, but not provably impossible for a future CLI version).
		// A wrong number that degrades to zero is recoverable; a wrong
		// number that wraps to near 2^64 and flows straight into a
		// dollar figure is not, and this project's rule is that a
		// failure must degrade to fewer cells, never to a wrong one.
		deltaInput = saturatingSub(cur.InputTokens, p.prevInput)
		deltaCached = saturatingSub(cur.CachedInputTokens, p.prevCached)
		deltaOutput = saturatingSub(cur.OutputTokens, p.prevOutput)
	}

	p.prevInput, p.prevCached, p.prevOutput, p.prevTotal = cur.InputTokens, cur.CachedInputTokens, cur.OutputTokens, cur.TotalTokens
	p.havePrev = true

	if decreased {
		return nil
	}
	if !first && deltaInput == 0 && deltaCached == 0 && deltaOutput == 0 {
		// The duplicate case: identical totals telescope to a zero
		// delta with no need for a dedupe key.
		return nil
	}

	in := saturatingSub(deltaInput, deltaCached)

	return []Event{{
		Timestamp:  ts,
		SessionID:  p.sessionID,
		Cwd:        p.cwd,
		Model:      codexModelForSession(p.model, p.hasParent),
		IsSubagent: p.hasParent,
		Usage: pricing.Usage{
			InputTokens:          in,
			OutputTokens:         deltaOutput,
			CacheReadInputTokens: deltaCached,
			// Codex reports no cache-creation figure.
			CacheCreationInputTokens: 0,
		},
	}}
}

// Project returns the encoded cwd captured from session_meta, not
// something derived from slashPath: unlike Claude's and Grok's layouts,
// which both encode the project into the transcript path itself,
// Codex's is ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl — dated, not
// project-keyed. The path carries no project information at all, so
// the in-file cwd is the only source. This is the one point where
// codexParser's vendorParser methods read the parser's state instead of
// their root/slashPath arguments.
func (p *codexParser) Project(_, _ string) string {
	return strings.NewReplacer("/", "-", ".", "-").Replace(p.cwd)
}

// IsSubagent reads the same session_meta state Project does, for the
// same reason: parent_thread_id, not the path, is Codex's subagent
// marker.
func (p *codexParser) IsSubagent(_, _ string) bool {
	return p.hasParent
}
