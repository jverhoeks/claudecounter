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
	// opus, fable, and gpt-x (openai is now priced too) survive; only the
	// zero-cost anthropic placeholder is dropped.
	if len(table.Models) != 3 {
		t.Fatalf("models = %d, want 3 (zero-priced dropped): %v", len(table.Models), table.Models)
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
	// gpt-x is an openai entry with no cache fields at all — this is the
	// shape of the 52 live LiteLLM entries that omit
	// cache_read_input_token_cost. It must still come through (at $0
	// cache rates, not be dropped).
	g, ok := table.Models["gpt-x"]
	if !ok {
		t.Fatal("gpt-x (openai) not parsed")
	}
	if g.InputPerMTok != 10.00 || g.OutputPerMTok != 30.00 ||
		g.CacheCreationPerMTok != 0 || g.CacheReadPerMTok != 0 {
		t.Fatalf("gpt-x prices wrong: %+v", g)
	}
}

// TestParseLiteLLM_OpenAI verifies the provider widening directly: an
// anthropic entry, a fully-priced openai entry, a zero-cost openai entry,
// and an azure entry (still unsupported). Only the priced entries from the
// two admitted providers should survive.
func TestParseLiteLLM_OpenAI(t *testing.T) {
	const fixture = `{
  "claude-opus-4-8": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 5e-06,
    "output_cost_per_token": 2.5e-05,
    "cache_creation_input_token_cost": 6.25e-06,
    "cache_read_input_token_cost": 5e-07
  },
  "gpt-5.6-sol": {
    "litellm_provider": "openai",
    "input_cost_per_token": 1.5e-06,
    "output_cost_per_token": 6e-06,
    "cache_creation_input_token_cost": 0,
    "cache_read_input_token_cost": 1.5e-07
  },
  "gpt-5.6-zero": {
    "litellm_provider": "openai",
    "input_cost_per_token": 0,
    "output_cost_per_token": 0
  },
  "azure-gpt-5.6": {
    "litellm_provider": "azure",
    "input_cost_per_token": 1.5e-06,
    "output_cost_per_token": 6e-06
  }
}`
	table, err := parseLiteLLM([]byte(fixture))
	if err != nil {
		t.Fatal(err)
	}
	if len(table.Models) != 2 {
		t.Fatalf("models = %d, want 2 (anthropic + openai; zero-cost and azure dropped): %v", len(table.Models), table.Models)
	}
	a, ok := table.Models["claude-opus-4-8"]
	if !ok {
		t.Fatal("anthropic model not parsed")
	}
	if a.InputPerMTok != 5.00 || a.OutputPerMTok != 25.00 ||
		a.CacheCreationPerMTok != 6.25 || a.CacheReadPerMTok != 0.50 {
		t.Fatalf("anthropic prices wrong (must be unchanged): %+v", a)
	}
	o, ok := table.Models["gpt-5.6-sol"]
	if !ok {
		t.Fatal("openai model not parsed")
	}
	if o.InputPerMTok != 1.50 || o.OutputPerMTok != 6.00 ||
		o.CacheCreationPerMTok != 0 || o.CacheReadPerMTok != 0.15 {
		t.Fatalf("openai prices wrong: %+v", o)
	}
	if _, ok := table.Models["gpt-5.6-zero"]; ok {
		t.Fatal("zero-cost openai entry must be dropped")
	}
	if _, ok := table.Models["azure-gpt-5.6"]; ok {
		t.Fatal("azure entry must be dropped (unsupported provider)")
	}
}

// TestParseLiteLLM_NoPricedModels replaces the old
// TestParseLiteLLM_NoAnthropicModels: an openai-only input is no longer an
// error case (openai is priced now), so the error path is exercised with a
// provider that's still unsupported (azure) plus a zero-cost openai entry.
func TestParseLiteLLM_NoPricedModels(t *testing.T) {
	const fixture = `{
  "azure-gpt-5.6": {"litellm_provider": "azure", "input_cost_per_token": 1e-05, "output_cost_per_token": 3e-05},
  "gpt-5.6-zero": {"litellm_provider": "openai", "input_cost_per_token": 0, "output_cost_per_token": 0}
}`
	if _, err := parseLiteLLM([]byte(fixture)); err == nil {
		t.Fatal("expected error when no priced models present")
	}
}
