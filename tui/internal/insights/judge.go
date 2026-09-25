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
// reply as JSON matching schema, plus the call's USD cost.
type Judge interface {
	Ask(ctx context.Context, prompt, schema string) (jsonText string, costUSD float64, err error)
}

// CLIJudge runs the user's local `claude -p` binary. No API token needed — it
// uses whatever auth the CLI already has.
type CLIJudge struct {
	Bin     string
	Model   string // --model; empty uses Claude Code's default
	Effort  string // --effort; empty uses the model's default
	Timeout time.Duration
}

// NewCLIJudge returns a CLIJudge with sensible defaults. The model is pinned
// so judgments don't shift when the user's Claude Code default does; effort
// is set explicitly because Opus 5.5 defaults to medium, not high. Judging is one
// tool-free turn, so tools are disabled and the session isn't persisted (a
// saved session would be re-read as user prompts on the next insights run).
func NewCLIJudge() *CLIJudge {
	return &CLIJudge{Bin: "claude", Model: "claude-opus-5-5", Effort: "medium", Timeout: 240 * time.Second}
}

// Ask pipes prompt to `<bin> -p` on stdin with schema as --json-schema, and
// returns the validated structured_output. A non-zero exit, timeout, is_error
// reply, or missing structured_output is returned as err.
func (c *CLIJudge) Ask(ctx context.Context, prompt, schema string) (string, float64, error) {
	cctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()
	args := []string{"-p", "--output-format=json", "--json-schema", schema,
		"--tools", "", "--no-session-persistence"}
	if c.Model != "" {
		args = append(args, "--model", c.Model)
	}
	if c.Effort != "" {
		args = append(args, "--effort", c.Effort)
	}
	cmd := exec.CommandContext(cctx, c.Bin, args...)
	cmd.Stdin = strings.NewReader(prompt)
	out, err := cmd.Output()
	if err != nil {
		return "", 0, fmt.Errorf("claude -p: %w", err)
	}
	return parseCLIResult(out)
}

// cliWrapper mirrors the fields we read from `claude -p --output-format=json`.
type cliWrapper struct {
	Structured json.RawMessage `json:"structured_output"`
	TotalCost  float64         `json:"total_cost_usd"`
	IsError    bool            `json:"is_error"`
	ErrStatus  string          `json:"api_error_status"`
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
	if len(w.Structured) == 0 || string(w.Structured) == "null" {
		return "", w.TotalCost, fmt.Errorf("claude returned no structured_output")
	}
	return string(w.Structured), w.TotalCost, nil
}
