// Package perf reconstructs one sample per Claude API request from the
// session logs: latency, decode speed, cache behaviour and tool errors.
// It is a port of the macapp's Performance.swift and feeds the
// dashboards' Performance and Effort views and the Hints rules.
//
// What the logs can and cannot tell us: Claude Code appends one JSONL
// record per assistant *content block*, written when the block
// completes — never per streamed token. So one request's timeline is
//
//	user record (prompt or tool_result)   ← request sent
//	assistant record, block 0             ← first block complete
//	assistant record, block n             ← last block complete
//
// "Time to first block" and end-to-end duration are measured directly;
// time-to-first-token and inter-token latency are only *estimated*, per
// bucket, by Fit.
//
// Deliberately separate from reader/agg: pairing a request with the user
// record that started it needs parentUuid and user lines, which the spend
// pipeline neither reads nor should start carrying.
package perf

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

// Sample is one API request, reconstructed from a session file.
type Sample struct {
	RequestID string
	// Time is when the first content block completed.
	Time       time.Time
	Model      string
	IsSubagent bool
	// Effort is perTurnEffort, else effort; "" on clients that don't
	// record it.
	Effort string
	// FirstBlock is request sent → first block complete, seconds.
	FirstBlock float64
	// Duration is request sent → last block complete, seconds.
	Duration float64
	Output   uint64
	// Context is input + cache read + cache write: the whole prompt.
	Context   uint64
	CacheRead uint64
	// Thinking is nil when the client didn't report thinking tokens.
	Thinking    *uint64
	ToolCalls   int
	ToolErrors  ToolErrorCounts
	Interrupted bool
	Rebuild     CacheRebuild
	// Pricing inputs for the hints.
	Input      uint64
	CacheWrite uint64
	// CacheWrite1h is the part of CacheWrite written with the 1-hour TTL.
	CacheWrite1h uint64
	// Session is the file the request came from.
	Session string
}

// Cost is what the request cost at the table's rates (flat; no
// long-context premium).
func (s Sample) Cost(t pricing.Table) float64 {
	return t.Cost(s.Model, pricing.Usage{
		InputTokens:                s.Input,
		OutputTokens:               s.Output,
		CacheCreationInputTokens:   s.CacheWrite,
		CacheReadInputTokens:       s.CacheRead,
		CacheCreation1hInputTokens: s.CacheWrite1h,
	})
}

// Start is when the request went out. Used for concurrency.
func (s Sample) Start() time.Time {
	return s.Time.Add(-secs(s.FirstBlock))
}

func secs(v float64) time.Duration { return time.Duration(v * float64(time.Second)) }

type ToolErrorCounts struct {
	Misuse, Exit, Policy, Environment int
}

// CacheRebuild marks a main-session turn whose cache read collapsed and
// whose prefix was written again. AfterIdle = more than an hour since the
// previous turn, i.e. the 1h cache TTL ran out; MidFlow = the context
// changed under it.
type CacheRebuild int

const (
	RebuildNone CacheRebuild = iota
	RebuildMidFlow
	RebuildAfterIdle
)

// ToolErrorClass says which tool errors count against the model. Only
// Misuse is the model's own mistake (a stale Edit string, a file it never
// read, a bad path). Policy blocks and environment failures are not, and
// a nonzero exit is ambiguous — grep finding nothing exits 1.
type ToolErrorClass int

const (
	ClassMisuse ToolErrorClass = iota
	ClassExit
	ClassPolicy
	ClassEnvironment
)

var (
	policyMarkers = []string{"Permission", "denied", "doesn't want to proceed", "classifier", "Blocked:",
		"cannot be checked", "contains multiple operations", "cannot spawn", "unable to fetch",
		"protocol is blocked", "outside allowed roots", "requires approval",
		"changes directory before running git"}
	envMarkers = []string{"posix_spawn", "ENOTFOUND", "ECONNREFUSED", "ETIMEDOUT", "ECONNRESET", "ENOSPC",
		"timed out", "rate limit", "status code 5", "status code 429"}
)

func ClassifyToolError(body string) ToolErrorClass {
	head := body
	if r := []rune(body); len(r) > 400 {
		head = string(r[:400])
	}
	for _, m := range policyMarkers {
		if strings.Contains(head, m) {
			return ClassPolicy
		}
	}
	for _, m := range envMarkers {
		if strings.Contains(head, m) {
			return ClassEnvironment
		}
	}
	if strings.HasPrefix(body, "Exit code") {
		return ClassExit
	}
	return ClassMisuse
}

// perfLine is the minimal view of a session record. Content stays raw so
// the (often huge) tool bodies are only decoded for user records that
// answer a known request.
type perfLine struct {
	Type              string  `json:"type"`
	UUID              string  `json:"uuid"`
	ParentUUID        *string `json:"parentUuid"`
	Timestamp         string  `json:"timestamp"`
	RequestID         string  `json:"requestId"`
	IsSidechain       bool    `json:"isSidechain"`
	IsAPIErrorMessage bool    `json:"isApiErrorMessage"`
	Effort            string  `json:"effort"`
	PerTurnEffort     string  `json:"perTurnEffort"`
	Message           *struct {
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
		Usage   *struct {
			Input               uint64 `json:"input_tokens"`
			Output              uint64 `json:"output_tokens"`
			CacheCreate         uint64 `json:"cache_creation_input_tokens"`
			CacheRead           uint64 `json:"cache_read_input_tokens"`
			OutputTokensDetails *struct {
				Thinking *uint64 `json:"thinking_tokens"`
			} `json:"output_tokens_details"`
			CacheCreation *struct {
				Ephemeral1h uint64 `json:"ephemeral_1h_input_tokens"`
			} `json:"cache_creation"`
		} `json:"usage"`
	} `json:"message"`
}

type contentBlock struct {
	Type    string          `json:"type"`
	Text    string          `json:"text"`
	IsError bool            `json:"is_error"`
	Content json.RawMessage `json:"content"`
}

// body is a tool_result's content: a string, or [{type:text,text:…}].
func (b contentBlock) body() string {
	var s string
	if json.Unmarshal(b.Content, &s) == nil {
		return s
	}
	var parts []struct {
		Text *string `json:"text"`
	}
	if json.Unmarshal(b.Content, &parts) == nil {
		texts := make([]string, 0, len(parts))
		for _, p := range parts {
			if p.Text != nil {
				texts = append(texts, *p.Text)
			}
		}
		return strings.Join(texts, "\n")
	}
	return ""
}

func parseTime(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, s)
	return t, err == nil
}

// IsSubagentPath mirrors reader's rule: subagent transcripts live under a
// fixed "subagents" directory.
func IsSubagentPath(path string) bool {
	return strings.Contains(filepath.ToSlash(path), "/subagents/")
}

// Parse turns one whole session file into request samples, in time order
// for a main session (file order for a subagent), with cache rebuilds
// flagged.
func Parse(data []byte, path string) []Sample {
	type node struct {
		isUser bool
		parent string
		time   time.Time
	}
	type block struct {
		parent                                             string
		time                                               time.Time
		model                                              string
		input, output, cacheRead, cacheWrite, cacheWrite1h uint64
		thinking                                           *uint64
		sidechain                                          bool
		effort                                             string
	}
	type outcome struct {
		tools       int
		errors      ToolErrorCounts
		interrupted bool
	}

	isSub := IsSubagentPath(path)
	nodes := map[string]node{}
	requestOf := map[string]string{} // assistant uuid → requestId
	blocks := map[string][]block{}
	var ridOrder []string
	outcomes := map[string]*outcome{}

	for len(data) > 0 {
		nl := bytes.IndexByte(data, '\n')
		if nl < 0 {
			// Only complete lines count, the same rule as the reader:
			// a tail without its newline is still being written.
			break
		}
		lineBytes := data[:nl]
		data = data[nl+1:]
		if len(bytes.TrimSpace(lineBytes)) == 0 {
			continue
		}
		var line perfLine
		if json.Unmarshal(lineBytes, &line) != nil || line.UUID == "" {
			continue
		}
		t, ok := parseTime(line.Timestamp)
		if !ok {
			continue
		}
		parent := ""
		if line.ParentUUID != nil {
			parent = *line.ParentUUID
		}
		nodes[line.UUID] = node{isUser: line.Type == "user", parent: parent, time: t}

		if line.Type == "assistant" {
			if line.RequestID == "" || line.IsAPIErrorMessage {
				continue
			}
			rid := line.RequestID
			requestOf[line.UUID] = rid
			b := block{parent: parent, time: t, sidechain: line.IsSidechain, effort: line.PerTurnEffort}
			if b.effort == "" {
				b.effort = line.Effort
			}
			if m := line.Message; m != nil {
				b.model = m.Model
				if u := m.Usage; u != nil {
					b.input, b.output, b.cacheRead, b.cacheWrite = u.Input, u.Output, u.CacheRead, u.CacheCreate
					if u.CacheCreation != nil {
						b.cacheWrite1h = u.CacheCreation.Ephemeral1h
					}
					if u.OutputTokensDetails != nil {
						b.thinking = u.OutputTokensDetails.Thinking
					}
				}
			}
			if _, seen := blocks[rid]; !seen {
				ridOrder = append(ridOrder, rid)
			}
			blocks[rid] = append(blocks[rid], b)
			continue
		}

		// Tool results and interrupts are user records whose parent is
		// the assistant record that made the call — that's how an
		// outcome is charged to the request that caused it.
		if line.Type != "user" || parent == "" || line.Message == nil {
			continue
		}
		rid, ok := requestOf[parent]
		if !ok {
			continue
		}
		o := outcomes[rid]
		if o == nil {
			o = &outcome{}
			outcomes[rid] = o
		}
		var text string
		if json.Unmarshal(line.Message.Content, &text) == nil {
			if strings.HasPrefix(text, "[Request interrupted by user") {
				o.interrupted = true
			}
			continue
		}
		var bs []contentBlock
		if json.Unmarshal(line.Message.Content, &bs) != nil {
			continue
		}
		for _, b := range bs {
			if strings.HasPrefix(b.Text, "[Request interrupted by user") {
				o.interrupted = true
			}
			if b.Type != "tool_result" {
				continue
			}
			o.tools++
			if !b.IsError {
				continue
			}
			switch ClassifyToolError(b.body()) {
			case ClassMisuse:
				o.errors.Misuse++
			case ClassExit:
				o.errors.Exit++
			case ClassPolicy:
				o.errors.Policy++
			case ClassEnvironment:
				o.errors.Environment++
			}
		}
	}

	out := make([]Sample, 0, len(ridOrder))
	for _, rid := range ridOrder {
		bl := blocks[rid]
		first, last := bl[0], bl[len(bl)-1]
		if last.model == "" || last.model == "<synthetic>" {
			continue
		}
		// Request start: walk up the parent chain to the nearest user
		// record written before the first block. Attachment and system
		// records sit in between and are often written *after* the
		// request went out, so the direct parent is not good enough.
		cur, ok := nodes[first.parent]
		for hops := 0; ok && hops < 40; hops++ {
			if cur.isUser && cur.time.Sub(first.time).Seconds() <= -0.02 {
				break
			}
			cur, ok = nodes[cur.parent]
		}
		if !ok || !cur.isUser {
			continue
		}
		duration := last.time.Sub(cur.time).Seconds()
		if duration <= 0 {
			continue
		}
		var o outcome
		if p := outcomes[rid]; p != nil {
			o = *p
		}
		var thinking *uint64
		for i := len(bl) - 1; i >= 0; i-- {
			if bl[i].thinking != nil {
				v := *bl[i].thinking
				thinking = &v
				break
			}
		}
		// Top-level output_tokens, not the iterations[] sum the spend
		// reader uses: this is about how long *this* request streamed.
		out = append(out, Sample{
			RequestID: rid, Time: first.time, Model: last.model,
			IsSubagent: isSub || first.sidechain, Effort: first.effort,
			FirstBlock: first.time.Sub(cur.time).Seconds(), Duration: duration,
			Output: last.output, Context: last.input + last.cacheRead + last.cacheWrite,
			CacheRead: last.cacheRead, Thinking: thinking,
			ToolCalls: o.tools, ToolErrors: o.errors, Interrupted: o.interrupted,
			Input: last.input, CacheWrite: last.cacheWrite, CacheWrite1h: last.cacheWrite1h,
			Session: path,
		})
	}

	// Cache rebuilds only make sense along one main session's sequence.
	if isSub {
		return out
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Time.Before(out[j].Time) })
	for i := 1; i < len(out); i++ {
		a, b := out[i-1], out[i]
		prevRead := float64(a.CacheRead)
		written := float64(b.Context - b.CacheRead)
		if prevRead >= 20_000 && float64(b.CacheRead) < 0.5*prevRead && written >= 0.5*prevRead {
			if b.Time.Sub(a.Time) > time.Hour {
				out[i].Rebuild = RebuildAfterIdle
			} else {
				out[i].Rebuild = RebuildMidFlow
			}
		}
	}
	return out
}
