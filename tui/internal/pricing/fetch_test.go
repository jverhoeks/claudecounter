package pricing

import (
	"testing"
)

const liteLLMFixture = `{
  "claude-opus-4-8": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 5e-06,
    "output_cost_per_token": 2.5e-05,
    "cache_creation_input_token_cost": 6.25e-06,
    "cache_read_input_token_cost": 5e-07
  },
  "anthropic/claude-fable-5": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 1e-05,
    "output_cost_per_token": 5e-05,
    "cache_creation_input_token_cost": 1.25e-05,
    "cache_read_input_token_cost": 1e-06
  },
  "gpt-x": {
    "litellm_provider": "openai",
    "input_cost_per_token": 1e-05,
    "output_cost_per_token": 3e-05
  },
  "claude-placeholder": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 0,
    "output_cost_per_token": 0
  },
  "some-non-model-key": "ignore me"
}`

func TestParseLiteLLM(t *testing.T) {
	table, err := parseLiteLLM([]byte(liteLLMFixture))
	if err != nil {
		t.Fatal(err)
	}
	if len(table.Models) != 2 {
		t.Fatalf("models = %d, want 2 (non-anthropic + zero-priced dropped): %v", len(table.Models), table.Models)
	}
	p, ok := table.Models["claude-opus-4-8"]
	if !ok {
		t.Fatal("opus not parsed")
	}
	if p.InputPerMTok != 5.00 || p.OutputPerMTok != 25.00 ||
		p.CacheCreationPerMTok != 6.25 || p.CacheReadPerMTok != 0.50 {
		t.Fatalf("opus prices wrong: %+v", p)
	}
	// The anthropic/ prefix must be stripped.
	f, ok := table.Models["claude-fable-5"]
	if !ok {
		t.Fatal("fable not parsed (prefix not stripped?)")
	}
	if f.InputPerMTok != 10.00 || f.OutputPerMTok != 50.00 ||
		f.CacheCreationPerMTok != 12.50 || f.CacheReadPerMTok != 1.00 {
		t.Fatalf("fable prices wrong: %+v", f)
	}
}

func TestParseLiteLLM_NoAnthropicModels(t *testing.T) {
	if _, err := parseLiteLLM([]byte(`{"gpt-x":{"litellm_provider":"openai","input_cost_per_token":1e-05}}`)); err == nil {
		t.Fatal("expected error when no anthropic models present")
	}
}
