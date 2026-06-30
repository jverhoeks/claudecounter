package insights

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// judgePromptVersion is bumped whenever a Tier-2 prompt changes, so cached LLM
// answers from an older prompt are transparently invalidated.
const judgePromptVersion = 1

// Correction is one user-pushback turn the judge identified.
type Correction struct {
	Quote string `json:"quote"`
	Issue string `json:"issue"`
}

// Judgment is the LLM's per-session coaching verdict.
type Judgment struct {
	SessionID         string       `json:"session_id"`
	Friction          int          `json:"friction"`           // 0-10
	PromptSpecificity int          `json:"prompt_specificity"` // 0-10
	Corrections       []Correction `json:"corrections"`
	Loops             []string     `json:"loops"`
	RootCause         string       `json:"root_cause"`
	Advice            string       `json:"advice"`
	Available         bool         `json:"available"`
	Err               string       `json:"err,omitempty"`
	CostUSD           float64      `json:"cost_usd"`
}

// sessionJudgePrompt builds the instruction + digest payload for one session.
func sessionJudgePrompt(d Digest) string {
	payload, _ := json.MarshalIndent(struct {
		Prompts []string     `json:"user_prompts"`
		Tools   []DigestTool `json:"tool_calls"`
	}{d.Prompts, d.Tools}, "", " ")

	var b strings.Builder
	b.WriteString("You are reviewing one Claude Code coding session to coach the USER on working more effectively.\n")
	b.WriteString("Below are the user's real prompts (machine/injected turns already removed) and the tool-call sequence.\n\n")
	b.WriteString("Identify:\n")
	b.WriteString("- corrections: turns where the user pushed back, corrected, or re-asked because the assistant got it wrong.\n")
	b.WriteString("- loops: repeated unproductive cycles (same fix retried, thrashing).\n")
	b.WriteString("- friction (0-10): how much rework/frustration this session shows (0 smooth, 10 painful).\n")
	b.WriteString("- prompt_specificity (0-10): how clear/specific the user's FIRST prompt was.\n")
	b.WriteString("- root_cause: the main reason for friction, if any.\n")
	b.WriteString("- advice: one or two concrete tips for the user to get better results next time.\n\n")
	b.WriteString("Respond with ONLY a JSON object, no prose, with keys: ")
	b.WriteString(`friction (int), prompt_specificity (int), corrections (array of {quote, issue}), loops (array of strings), root_cause (string), advice (string).`)
	b.WriteString("\n\nSESSION DATA:\n")
	b.Write(payload)
	return b.String()
}

// rawJudgment is the on-the-wire shape (no metadata fields).
type rawJudgment struct {
	Friction          int          `json:"friction"`
	PromptSpecificity int          `json:"prompt_specificity"`
	Corrections       []Correction `json:"corrections"`
	Loops             []string     `json:"loops"`
	RootCause         string       `json:"root_cause"`
	Advice            string       `json:"advice"`
}

// JudgeSession asks the judge to coach one session. Any error (LLM failure or
// unparseable reply) yields an unavailable Judgment with Err set — never panics.
func JudgeSession(ctx context.Context, j Judge, d Digest) Judgment {
	text, cost, err := j.Ask(ctx, sessionJudgePrompt(d))
	res := Judgment{SessionID: d.ID, CostUSD: cost}
	if err != nil {
		res.Err = err.Error()
		return res
	}
	obj, ok := extractJSON(text)
	if !ok {
		res.Err = "no JSON object in reply"
		return res
	}
	var rj rawJudgment
	if err := json.Unmarshal(obj, &rj); err != nil {
		res.Err = fmt.Sprintf("decode reply: %v", err)
		return res
	}
	res.Friction = rj.Friction
	res.PromptSpecificity = rj.PromptSpecificity
	res.Corrections = rj.Corrections
	res.Loops = rj.Loops
	res.RootCause = rj.RootCause
	res.Advice = rj.Advice
	res.Available = true
	return res
}
