package pricing

// DefaultsDate is the ISO date the baked-in prices were captured.
// Update when bumping prices.
const DefaultsDate = "2026-08-19"

// Defaults returns a best-effort price table used when no pricing.toml
// is available and live fetch also fails.
// Prices in USD per 1M tokens.
//
// Source: LiteLLM's model_prices_and_context_window.json (same table
// ccusage uses). Cache-creation rate is the 5-minute TTL multiplier
// (1.25× input) — LiteLLM does not split by TTL.
func Defaults() Table {
	opus := ModelPrice{
		// Every Opus from 4.5 through 5: $5/$25/$6.25/$0.50 per 1M.
		InputPerMTok: 5.00, OutputPerMTok: 25.00,
		CacheCreationPerMTok: 6.25, CacheReadPerMTok: 0.50,
	}
	sonnet := ModelPrice{
		// Sonnet's standard rate. Sonnet 5 carries a promotional
		// $2/$10 through 2026-08-31, which LiteLLM tracks; these
		// baked-in defaults deliberately hold the list price, since a
		// fallback table outlives the intro window and under-reporting
		// after it lapses is worse than over-reporting during it.
		InputPerMTok: 3.00, OutputPerMTok: 15.00,
		CacheCreationPerMTok: 3.75, CacheReadPerMTok: 0.30,
	}
	haiku := ModelPrice{
		InputPerMTok: 1.00, OutputPerMTok: 5.00,
		CacheCreationPerMTok: 1.25, CacheReadPerMTok: 0.10,
	}
	fable := ModelPrice{
		// Claude Fable 5: $10/$50 per 1M (above Opus tier).
		InputPerMTok: 10.00, OutputPerMTok: 50.00,
		CacheCreationPerMTok: 12.50, CacheReadPerMTok: 1.00,
	}
	// Codex/OpenAI models, from the same LiteLLM table as the Claude rows
	// above. These matter more than their spend share suggests: Grok
	// events arrive pre-costed from the vendor's own logs
	// (reader.grokParser reads costUsdTicks) and bypass this table
	// entirely, but Codex events carry no cost and are priced only from
	// here. Before these rows existed, every install that fell back to
	// Defaults priced all Codex usage at $0 while Claude looked correct —
	// an asymmetry that reads as "Codex is missing" rather than as a
	// pricing failure.
	//
	// gpt-5.6-luna is the model codex-auto-review bills at (see
	// modelAliases); without a row here that alias resolves to nothing.
	// gpt-5.5's cache-creation rate is 0 because LiteLLM carries no such
	// field for it, matching what a live fetch produces.
	gpt56 := ModelPrice{
		InputPerMTok: 5.00, OutputPerMTok: 30.00,
		CacheCreationPerMTok: 6.25, CacheReadPerMTok: 0.50,
	}
	gpt55 := ModelPrice{
		InputPerMTok: 5.00, OutputPerMTok: 30.00,
		CacheCreationPerMTok: 0, CacheReadPerMTok: 0.50,
	}
	gptLuna := ModelPrice{
		InputPerMTok: 0.20, OutputPerMTok: 1.20,
		CacheCreationPerMTok: 0.25, CacheReadPerMTok: 0.02,
	}
	return Table{
		Models: map[string]ModelPrice{
			"claude-fable-5":            fable,
			"claude-mythos-5":           fable,
			"claude-opus-5":             opus,
			"claude-sonnet-5":           sonnet,
			"claude-opus-4-8":           opus,
			"claude-opus-4-7":           opus,
			"claude-opus-4-6":           opus,
			"claude-opus-4-5":           opus,
			"claude-sonnet-4-6":         sonnet,
			"claude-sonnet-4-5":         sonnet,
			"claude-haiku-4-5":          haiku,
			"claude-haiku-4-5-20251001": haiku,
			"opus":                      opus,
			"sonnet":                    sonnet,
			"haiku":                     haiku,
			"fable":                     fable,
			"gpt-5.6-sol":               gpt56,
			"gpt-5.5":                   gpt55,
			"gpt-5.6-luna":              gptLuna,
		},
	}
}
