package reader

import (
	"encoding/json"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/pricing"
)

type Event struct {
	Timestamp time.Time
	SessionID string
	Cwd       string
	Model     string
	Usage     pricing.Usage
}

// rawLine mirrors only the fields we read from a JSONL event.
type rawLine struct {
	Type      string    `json:"type"`
	Timestamp time.Time `json:"timestamp"`
	SessionID string    `json:"sessionId"`
	Cwd       string    `json:"cwd"`
	Message   *struct {
		Model string `json:"model"`
		Usage *struct {
			InputTokens              uint64 `json:"input_tokens"`
			OutputTokens             uint64 `json:"output_tokens"`
			CacheCreationInputTokens uint64 `json:"cache_creation_input_tokens"`
			CacheReadInputTokens     uint64 `json:"cache_read_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

// parseLine returns (event, ok, err). ok=false means the line is valid JSON
// but not an assistant-usage event (skip it silently). err != nil means
// the line is not valid JSON at all.
func parseLine(line []byte) (Event, bool, error) {
	var r rawLine
	if err := json.Unmarshal(line, &r); err != nil {
		return Event{}, false, err
	}
	if r.Type != "assistant" || r.Message == nil || r.Message.Usage == nil {
		return Event{}, false, nil
	}
	u := r.Message.Usage
	return Event{
		Timestamp: r.Timestamp,
		SessionID: r.SessionID,
		Cwd:       r.Cwd,
		Model:     r.Message.Model,
		Usage: pricing.Usage{
			InputTokens:              u.InputTokens,
			OutputTokens:             u.OutputTokens,
			CacheCreationInputTokens: u.CacheCreationInputTokens,
			CacheReadInputTokens:     u.CacheReadInputTokens,
		},
	}, true, nil
}
