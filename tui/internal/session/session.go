// Package session parses a single Claude Code session transcript (plus its
// subagent transcripts) into a rich event model: tool calls with matched
// results, permission-mode timeline, and deduped token totals. It is the
// shared foundation for the per-session scorecard and timeline reports and
// is deliberately separate from the live counting path (reader/agg).
package session

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

// ToolCall is one tool_use block, with its result (if seen) folded in.
type ToolCall struct {
	Time      time.Time
	Name      string
	Target    string // best-effort summary of the input (command, file_path, …)
	HasResult bool
	IsErr     bool
	Sub       bool // from a subagents/agent-*.jsonl transcript
}

// ModeChange is one permission-mode transition. From is "" for the first
// observed mode of the session.
type ModeChange struct {
	Time time.Time
	From string
	To   string
}

// Turn is one deduped, priced assistant response.
type Turn struct {
	Time  time.Time
	Model string
	Usage pricing.Usage
	Sub   bool
}

// Prompt is one real user prompt (filtered prose, main transcript only).
type Prompt struct {
	Time time.Time
	Mode string
	Text string
}

// Session is the parsed view of one session (main + subagent transcripts).
type Session struct {
	ID          string
	Path        string
	Cwd         string
	Entrypoint  string
	Start, End  time.Time
	Prompts     int            // real user prompt turns (main transcript only)
	ModeTurns   map[string]int // permissionMode -> prompt-turn count (main only)
	ModeChanges []ModeChange
	ToolCalls   []ToolCall
	Turns       []Turn
	UserPrompts []Prompt // real user prose (filtered), main transcript only
	HasPRLink   bool     // a pr-link event was recorded (a PR was opened)
	Tokens      pricing.Usage
	PeakContext uint64 // max input+cache tokens of a single request
}

// rawLine mirrors only the fields session parsing reads.
type rawLine struct {
	Type             string      `json:"type"`
	Timestamp        time.Time   `json:"timestamp"`
	Cwd              string      `json:"cwd"`
	Entrypoint       string      `json:"entrypoint"`
	PermissionMode   string      `json:"permissionMode"`
	RequestID        string      `json:"requestId"`
	IsMeta           bool        `json:"isMeta"`
	IsSidechain      bool        `json:"isSidechain"`
	IsCompactSummary bool        `json:"isCompactSummary"`
	Message          *rawMessage `json:"message"`
}

type rawMessage struct {
	ID      string          `json:"id"`
	Model   string          `json:"model"`
	Usage   *rawUsage       `json:"usage"`
	Content json.RawMessage `json:"content"` // string or []rawBlock
}

type rawUsage struct {
	InputTokens              uint64 `json:"input_tokens"`
	OutputTokens             uint64 `json:"output_tokens"`
	CacheCreationInputTokens uint64 `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     uint64 `json:"cache_read_input_tokens"`
}

type rawBlock struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Text      string          `json:"text"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
}

// toolTarget extracts a one-line summary from a tool_use input object,
// trying the most informative keys in order.
func toolTarget(input []byte) string {
	if len(input) == 0 {
		return ""
	}
	var m map[string]any
	if err := json.Unmarshal(input, &m); err != nil {
		return ""
	}
	for _, k := range []string{"command", "file_path", "path", "pattern", "url", "query", "skill", "prompt", "description"} {
		if v, ok := m[k].(string); ok && v != "" {
			return v
		}
	}
	return ""
}

// injectedTagPrefixes are the leading tags Claude Code injects into user
// turns — these are not real user prose and must be filtered out.
var injectedTagPrefixes = []string{
	"<task-notification>",
	"<command-name>",
	"<command-message>",
	"<command-args>",
	"<local-command-stdout>",
	"<local-command-stderr>",
	"<system-reminder>",
	"<user-prompt-submit-hook>",
}

// isInjectedTag reports whether trimmed text begins with a known injected tag.
func isInjectedTag(text string) bool {
	for _, p := range injectedTagPrefixes {
		if strings.HasPrefix(text, p) {
			return true
		}
	}
	return false
}

// stripSystemReminders removes any <system-reminder>…</system-reminder> spans
// embedded inside an otherwise-real prompt.
func stripSystemReminders(text string) string {
	const open, close = "<system-reminder>", "</system-reminder>"
	for {
		i := strings.Index(text, open)
		if i < 0 {
			return text
		}
		j := strings.Index(text[i:], close)
		if j < 0 {
			return text[:i] // unterminated: drop the rest
		}
		text = text[:i] + text[i+j+len(close):]
	}
}

// promptText extracts plain text from a user message's content, which is
// either a JSON string or an array of blocks (we join the "text" blocks).
// ok=false for tool_result-only / image-only / empty content.
func promptText(content json.RawMessage) (string, bool) {
	trimmed := strings.TrimSpace(string(content))
	if trimmed == "" {
		return "", false
	}
	switch trimmed[0] {
	case '"':
		var s string
		if err := json.Unmarshal(content, &s); err != nil {
			return "", false
		}
		return s, s != ""
	case '[':
		var blocks []rawBlock
		if err := json.Unmarshal(content, &blocks); err != nil {
			return "", false
		}
		var parts []string
		for _, b := range blocks {
			if b.Type == "text" && b.Text != "" {
				parts = append(parts, b.Text)
			}
		}
		joined := strings.Join(parts, "\n")
		return joined, joined != ""
	}
	return "", false
}

// parseState carries cross-file accumulators while parsing one session.
type parseState struct {
	s        *Session
	seenMsg  map[string]struct{} // messageID:requestID dedupe (mirrors agg)
	seenTool map[string]int      // tool_use block id -> index into s.ToolCalls
	lastMode string
}

// Parse reads the main transcript at mainPath plus any sibling
// <session>/subagents/agent-*.jsonl files and returns the merged session.
// Unparseable lines are skipped silently, matching the counter's tolerance.
func Parse(mainPath string) (*Session, error) {
	st := &parseState{
		s: &Session{
			ID:        strings.TrimSuffix(filepath.Base(mainPath), ".jsonl"),
			Path:      mainPath,
			ModeTurns: map[string]int{},
		},
		seenMsg:  map[string]struct{}{},
		seenTool: map[string]int{},
	}

	if err := st.parseFile(mainPath, false); err != nil {
		return nil, err
	}
	subDir := filepath.Join(strings.TrimSuffix(mainPath, ".jsonl"), "subagents")
	subs, _ := filepath.Glob(filepath.Join(subDir, "*.jsonl"))
	sort.Strings(subs)
	for _, p := range subs {
		// A vanished/unreadable subagent file shouldn't sink the report.
		_ = st.parseFile(p, true)
	}

	sort.SliceStable(st.s.ToolCalls, func(i, j int) bool {
		return st.s.ToolCalls[i].Time.Before(st.s.ToolCalls[j].Time)
	})
	sort.SliceStable(st.s.Turns, func(i, j int) bool {
		return st.s.Turns[i].Time.Before(st.s.Turns[j].Time)
	})
	return st.s, nil
}

func (st *parseState) parseFile(path string, sub bool) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20) // transcript lines can be huge
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var r rawLine
		if err := json.Unmarshal(line, &r); err != nil {
			continue
		}
		st.apply(&r, sub)
	}
	return sc.Err()
}

func (st *parseState) apply(r *rawLine, sub bool) {
	s := st.s
	if !r.Timestamp.IsZero() {
		if s.Start.IsZero() || r.Timestamp.Before(s.Start) {
			s.Start = r.Timestamp
		}
		if r.Timestamp.After(s.End) {
			s.End = r.Timestamp
		}
	}
	if s.Cwd == "" && r.Cwd != "" && !sub {
		s.Cwd = r.Cwd
	}
	if s.Entrypoint == "" && r.Entrypoint != "" && !sub {
		s.Entrypoint = r.Entrypoint
	}
	if r.Type == "pr-link" {
		s.HasPRLink = true
	}

	// Real user prompt turns carry permissionMode; tool_result user events
	// don't. Mode accounting tracks the main transcript only — subagent
	// prompts are machine-generated by the Task tool.
	if r.Type == "user" && r.PermissionMode != "" && !sub {
		s.Prompts++
		s.ModeTurns[r.PermissionMode]++
		if r.PermissionMode != st.lastMode {
			s.ModeChanges = append(s.ModeChanges, ModeChange{
				Time: r.Timestamp, From: st.lastMode, To: r.PermissionMode,
			})
			st.lastMode = r.PermissionMode
		}
		// Capture real user prose for downstream coaching analysis. Skip
		// machine/injected turns (meta, sidechain, compact summaries) and
		// injected-tag bodies (task-notifications, command expansions, …).
		if !r.IsMeta && !r.IsSidechain && !r.IsCompactSummary && r.Message != nil {
			if text, ok := promptText(r.Message.Content); ok {
				text = strings.TrimSpace(stripSystemReminders(text))
				if text != "" && !isInjectedTag(text) {
					s.UserPrompts = append(s.UserPrompts, Prompt{
						Time: r.Timestamp, Mode: r.PermissionMode, Text: text,
					})
				}
			}
		}
	}

	if r.Message == nil {
		return
	}

	// Token accounting: same permissive filter + dedupe rule as the counter.
	if u := r.Message.Usage; u != nil && r.Message.Model != "<synthetic>" {
		count := true
		if r.Message.ID != "" && r.RequestID != "" {
			key := r.Message.ID + ":" + r.RequestID
			if _, seen := st.seenMsg[key]; seen {
				count = false
			} else {
				st.seenMsg[key] = struct{}{}
			}
		}
		if count {
			s.Tokens.InputTokens += u.InputTokens
			s.Tokens.OutputTokens += u.OutputTokens
			s.Tokens.CacheCreationInputTokens += u.CacheCreationInputTokens
			s.Tokens.CacheReadInputTokens += u.CacheReadInputTokens
			if ctx := u.InputTokens + u.CacheCreationInputTokens + u.CacheReadInputTokens; ctx > s.PeakContext {
				s.PeakContext = ctx
			}
			s.Turns = append(s.Turns, Turn{
				Time:  r.Timestamp,
				Model: r.Message.Model,
				Usage: pricing.Usage{
					InputTokens:              u.InputTokens,
					OutputTokens:             u.OutputTokens,
					CacheCreationInputTokens: u.CacheCreationInputTokens,
					CacheReadInputTokens:     u.CacheReadInputTokens,
				},
				Sub: sub,
			})
		}
	}

	var blocks []rawBlock
	if len(r.Message.Content) > 0 && r.Message.Content[0] == '[' {
		if err := json.Unmarshal(r.Message.Content, &blocks); err != nil {
			return
		}
	}
	for _, b := range blocks {
		switch b.Type {
		case "tool_use":
			if b.ID != "" {
				if _, seen := st.seenTool[b.ID]; seen {
					continue // streaming re-serialisation duplicates blocks
				}
				st.seenTool[b.ID] = len(s.ToolCalls)
			}
			s.ToolCalls = append(s.ToolCalls, ToolCall{
				Time:   r.Timestamp,
				Name:   b.Name,
				Target: toolTarget(b.Input),
				Sub:    sub,
			})
		case "tool_result":
			if i, ok := st.seenTool[b.ToolUseID]; ok {
				s.ToolCalls[i].HasResult = true
				s.ToolCalls[i].IsErr = b.IsError
			}
		}
	}
}

// Find resolves a session transcript under root (the projects dir). With an
// empty idPrefix it returns the most recently modified main session file;
// otherwise the newest file whose name starts with idPrefix. Subagent
// transcripts (which live two levels deeper) never match.
func Find(root, idPrefix string) (string, error) {
	matches, err := filepath.Glob(filepath.Join(root, "*", "*.jsonl"))
	if err != nil {
		return "", err
	}
	var best string
	var bestMod time.Time
	for _, p := range matches {
		name := strings.TrimSuffix(filepath.Base(p), ".jsonl")
		if idPrefix != "" && !strings.HasPrefix(name, idPrefix) {
			continue
		}
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		if info.ModTime().After(bestMod) {
			best, bestMod = p, info.ModTime()
		}
	}
	if best == "" {
		if idPrefix != "" {
			return "", fmt.Errorf("no session matching %q under %s", idPrefix, root)
		}
		return "", errors.New("no session transcripts found under " + root)
	}
	return best, nil
}
