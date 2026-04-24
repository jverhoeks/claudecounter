package pricing

// DefaultsDate is the ISO date the baked-in prices were captured.
// Update when bumping prices.
const DefaultsDate = "2026-04-24"

// Defaults returns a best-effort price table used when no pricing.toml
// is available and live fetch also fails.
// Prices in USD per 1M tokens.
//
// Source: LiteLLM's model_prices_and_context_window.json (same table
// ccusage uses). Cache-creation rate is the 5-minute TTL multiplier
// (1.25× input) — LiteLLM does not split by TTL.
func Defaults() Table {
	opus := ModelPrice{
		// Claude 4.5/4.6/4.7 Opus: $5/$25/$6.25/$0.50 per 1M.
		InputPerMTok: 5.00, OutputPerMTok: 25.00,
		CacheCreationPerMTok: 6.25, CacheReadPerMTok: 0.50,
	}
	sonnet := ModelPrice{
		InputPerMTok: 3.00, OutputPerMTok: 15.00,
		CacheCreationPerMTok: 3.75, CacheReadPerMTok: 0.30,
	}
	haiku := ModelPrice{
		InputPerMTok: 1.00, OutputPerMTok: 5.00,
		CacheCreationPerMTok: 1.25, CacheReadPerMTok: 0.10,
	}
	return Table{
		Models: map[string]ModelPrice{
			"claude-opus-4-7":           opus,
			"claude-opus-4-6":           opus,
			"claude-opus-4-5":           opus,
			"claude-sonnet-4-6":         sonnet,
			"claude-sonnet-4-5":         sonnet,
			"claude-haiku-4-5":          haiku,
			"claude-haiku-4-5-20251001": haiku,
		},
	}
}
