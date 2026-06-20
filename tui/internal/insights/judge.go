package insights

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Judge abstracts an LLM that answers a single prompt. The real implementation
// shells to the local `claude -p` CLI; tests inject a fake. Ask returns the
// model's text reply plus the call's USD cost.
type Judge interface {
	Ask(ctx context.Context, prompt string) (text string, costUSD float64, err error)
}

// CLIJudge runs the user's local `claude -p` binary. No API token needed — it
// uses whatever auth the CLI already has.
type CLIJudge struct {
	Bin     string
	Timeout time.Duration
}

// NewCLIJudge returns a CLIJudge with sensible defaults. The timeout is
// generous: `claude -p` runs a full agent with a large system prompt, so big
// prompts (session judgments, CLAUDE.md merges) routinely take 1–3 minutes.
func NewCLIJudge() *CLIJudge {
	return &CLIJudge{Bin: "claude", Timeout: 240 * time.Second}
}

// Ask pipes prompt to `<bin> -p --output-format=json` on stdin and parses the
// JSON wrapper. A non-zero exit, timeout, or is_error reply is returned as err.
func (c *CLIJudge) Ask(ctx context.Context, prompt string) (string, float64, error) {
	cctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, c.Bin, "-p", "--output-format=json")
	cmd.Stdin = strings.NewReader(prompt)
	out, err := cmd.Output()
	if err != nil {
		return "", 0, fmt.Errorf("claude -p: %w", err)
	}
	return parseCLIResult(out)
}

// cliWrapper mirrors the fields we read from `claude -p --output-format=json`.
type cliWrapper struct {
	Result    string  `json:"result"`
	TotalCost float64 `json:"total_cost_usd"`
	IsError   bool    `json:"is_error"`
	ErrStatus string  `json:"api_error_status"`
}

func parseCLIResult(stdout []byte) (string, float64, error) {
	var w cliWrapper
	if err := json.Unmarshal(stdout, &w); err != nil {
		return "", 0, fmt.Errorf("parse claude output: %w", err)
	}
	if w.IsError {
		msg := w.ErrStatus
		if msg == "" {
			msg = "claude reported is_error"
		}
		return "", w.TotalCost, fmt.Errorf("claude error: %s", msg)
	}
	return w.Result, w.TotalCost, nil
}

// extractJSON returns the first balanced {…} object in s. LLMs sometimes wrap
// JSON in prose or ```json fences, so we don't assume the whole reply is JSON.
func extractJSON(s string) ([]byte, bool) {
	start := strings.IndexByte(s, '{')
	if start < 0 {
		return nil, false
	}
	depth := 0
	inStr := false
	esc := false
	for i := start; i < len(s); i++ {
		ch := s[i]
		if inStr {
			switch {
			case esc:
				esc = false
			case ch == '\\':
				esc = true
			case ch == '"':
				inStr = false
			}
			continue
		}
		switch ch {
		case '"':
			inStr = true
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return []byte(s[start : i+1]), true
			}
		}
	}
	return nil, false
}
