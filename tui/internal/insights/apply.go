package insights

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// ActionItem is one concrete, deduped recommendation rolled up across sessions.
type ActionItem struct {
	Action   string `json:"action"`
	Why      string `json:"why"`
	Sessions int    `json:"sessions"`
}

// ActionList is the synthesized "what to change in how you work" summary.
type ActionList struct {
	Items     []ActionItem `json:"items"`
	Available bool         `json:"available"`
	Err       string       `json:"err,omitempty"`
	CostUSD   float64      `json:"cost_usd"`
}

// actionsPrompt asks the judge to roll up many sessions' advice into a ranked,
// deduped action list.
func actionsPrompt(js []Judgment) string {
	type entry struct {
		Session     string       `json:"session"`
		Advice      string       `json:"advice"`
		RootCause   string       `json:"root_cause"`
		Corrections []Correction `json:"corrections"`
		Loops       []string     `json:"loops"`
	}
	var entries []entry
	for _, j := range js {
		if !j.Available {
			continue
		}
		entries = append(entries, entry{j.SessionID, j.Advice, j.RootCause, j.Corrections, j.Loops})
	}
	payload, _ := json.MarshalIndent(entries, "", " ")

	var b strings.Builder
	b.WriteString("You are coaching a developer based on several reviewed Claude Code sessions.\n")
	b.WriteString("Below is per-session advice, root causes, corrections, and loops.\n")
	b.WriteString("Roll them up into a SHORT, deduped, prioritized list of concrete actions the developer should take to work better — merge similar advice, rank by recurrence and impact.\n\n")
	b.WriteString("Respond with ONLY a JSON object: {\"actions\":[{\"action\":string,\"why\":string,\"sessions\":int}]}. ")
	b.WriteString("action = the concrete thing to do; why = the payoff/evidence; sessions = how many sessions show this pattern. Order most important first.\n\n")
	b.WriteString("SESSIONS:\n")
	b.Write(payload)
	return b.String()
}

type rawActions struct {
	Actions []ActionItem `json:"actions"`
}

// SynthesizeActions produces the consolidated action list from judgments. No
// available judgments → available with no items (nothing to do). Any LLM or
// parse failure → unavailable with Err.
func SynthesizeActions(ctx context.Context, j Judge, js []Judgment) ActionList {
	any := false
	for _, x := range js {
		if x.Available {
			any = true
			break
		}
	}
	if !any {
		return ActionList{Available: true}
	}

	text, cost, err := j.Ask(ctx, actionsPrompt(js))
	res := ActionList{CostUSD: cost}
	if err != nil {
		res.Err = err.Error()
		return res
	}
	obj, ok := extractJSON(text)
	if !ok {
		res.Err = "no JSON object in reply"
		return res
	}
	var ra rawActions
	if err := json.Unmarshal(obj, &ra); err != nil {
		res.Err = fmt.Sprintf("decode reply: %v", err)
		return res
	}
	res.Items = ra.Actions
	res.Available = true
	return res
}

// mergePrompt instructs the judge to fold candidates into an existing CLAUDE.md
// without losing anything.
func mergePrompt(existing string, cands []MemoryCandidate) string {
	payload, _ := json.MarshalIndent(cands, "", " ")
	var b strings.Builder
	b.WriteString("You are updating a project's CLAUDE.md file (instructions Claude Code reads every session).\n")
	b.WriteString("RULES:\n")
	b.WriteString("- Preserve ALL existing content verbatim. Never delete or reword existing lines.\n")
	b.WriteString("- Add the new suggested instructions below, but SKIP any that are already covered by existing content.\n")
	b.WriteString("- Put genuinely-new additions under a section titled '## Insights (auto-suggested)' (create it if absent, append to it if present).\n")
	b.WriteString("- Return ONLY the complete updated file content. No code fences, no commentary.\n\n")
	b.WriteString("EXISTING CLAUDE.md (may be empty):\n")
	b.WriteString("<<<EXISTING\n")
	b.WriteString(existing)
	b.WriteString("\nEXISTING\n\n")
	b.WriteString("SUGGESTED INSTRUCTIONS (JSON):\n")
	b.Write(payload)
	return b.String()
}

// stripFence removes a single leading/trailing ``` fence if the model wrapped
// the file in one despite instructions.
func stripFence(s string) string {
	t := strings.TrimSpace(s)
	if !strings.HasPrefix(t, "```") {
		return s
	}
	if i := strings.IndexByte(t, '\n'); i >= 0 {
		t = t[i+1:]
	}
	t = strings.TrimSuffix(strings.TrimRight(t, "\n"), "```")
	return strings.TrimRight(t, "\n")
}

// MergeClaudeMd asks the judge to fold candidates into existing CLAUDE.md text,
// returning the full merged file. No candidates → existing unchanged, no call.
func MergeClaudeMd(ctx context.Context, j Judge, existing string, cands []MemoryCandidate) (string, float64, error) {
	if len(cands) == 0 {
		return existing, 0, nil
	}
	text, cost, err := j.Ask(ctx, mergePrompt(existing, cands))
	if err != nil {
		return "", cost, err
	}
	return stripFence(text), cost, nil
}

// unifiedDiff renders a minimal line-based diff for human preview (not a
// patchable format). Common leading/trailing lines are trimmed; the remaining
// old lines are shown with '-' and new lines with '+'.
func unifiedDiff(oldText, newText, path string) string {
	oldLines := splitLines(oldText)
	newLines := splitLines(newText)

	// Trim common prefix.
	p := 0
	for p < len(oldLines) && p < len(newLines) && oldLines[p] == newLines[p] {
		p++
	}
	// Trim common suffix.
	so, sn := len(oldLines), len(newLines)
	for so > p && sn > p && oldLines[so-1] == newLines[sn-1] {
		so--
		sn--
	}

	var b strings.Builder
	fmt.Fprintf(&b, "--- %s (current)\n+++ %s (merged)\n", path, path)
	if p > 0 {
		fmt.Fprintf(&b, "  … %d unchanged line(s)\n", p)
	}
	for _, l := range oldLines[p:so] {
		fmt.Fprintf(&b, "- %s\n", l)
	}
	for _, l := range newLines[p:sn] {
		fmt.Fprintf(&b, "+ %s\n", l)
	}
	tail := len(oldLines) - so
	if tail > 0 {
		fmt.Fprintf(&b, "  … %d unchanged line(s)\n", tail)
	}
	return b.String()
}

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
}
