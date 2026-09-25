package insights

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

const minePromptCap = 60 // max prompts fed to the miner, to bound LLM input

// mineSchema constrains the miner's reply to rawMined's shape.
const mineSchema = `{"type":"object","properties":{"candidates":{"type":"array","items":{"type":"object","properties":{"suggestion":{"type":"string"},"evidence":{"type":"string"}},"required":["suggestion","evidence"]}}},"required":["candidates"]}`

// MemoryCandidate is one recurring instruction the miner suggests promoting to
// CLAUDE.md or persistent memory.
type MemoryCandidate struct {
	Suggestion string `json:"suggestion"`
	Evidence   string `json:"evidence"`
}

// ProjectMined is the miner's per-project result.
type ProjectMined struct {
	Project    string            `json:"project"`
	Candidates []MemoryCandidate `json:"candidates"`
	Available  bool              `json:"available"`
	Err        string            `json:"err,omitempty"`
	CostUSD    float64           `json:"cost_usd"`
}

// minePrompt builds the instruction for finding recurring, project-wide
// instructions across many sessions' prompts.
func minePrompt(project string, prompts []string) string {
	payload, _ := json.MarshalIndent(prompts, "", " ")
	var b strings.Builder
	b.WriteString("Below are user prompts collected across many Claude Code sessions in a single project.\n")
	b.WriteString("Find recurring instructions, preferences, or corrections the user repeats across sessions — ")
	b.WriteString("the kind of thing that should live in CLAUDE.md or persistent memory so they never have to repeat it.\n")
	b.WriteString("Ignore one-off task requests. Only surface patterns that recur or read as standing preferences.\n\n")
	b.WriteString("For each candidate, suggestion = the CLAUDE.md line to add; evidence = why (which repeated ask). Return no candidates if none recur.\n\n")
	fmt.Fprintf(&b, "PROJECT: %s\nPROMPTS:\n", project)
	b.Write(payload)
	return b.String()
}

type rawMined struct {
	Candidates []MemoryCandidate `json:"candidates"`
}

// MineProject collects up to minePromptCap prompts from the project's digests
// and asks the judge for CLAUDE.md/memory candidates.
func MineProject(ctx context.Context, j Judge, project string, digests []Digest) ProjectMined {
	var prompts []string
	for _, d := range digests {
		for _, p := range d.Prompts {
			prompts = append(prompts, p)
			if len(prompts) >= minePromptCap {
				break
			}
		}
		if len(prompts) >= minePromptCap {
			break
		}
	}

	res := ProjectMined{Project: project}
	if len(prompts) == 0 {
		res.Available = true // nothing to mine, but not an error
		return res
	}

	text, cost, err := j.Ask(ctx, minePrompt(project, prompts), mineSchema)
	res.CostUSD = cost
	if err != nil {
		res.Err = err.Error()
		return res
	}
	var rm rawMined
	if err := json.Unmarshal([]byte(text), &rm); err != nil {
		res.Err = fmt.Sprintf("decode reply: %v", err)
		return res
	}
	res.Candidates = rm.Candidates
	res.Available = true
	return res
}
