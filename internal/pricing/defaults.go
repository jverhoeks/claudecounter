package pricing

// DefaultsDate is the ISO date the baked-in prices were captured.
// Update when bumping prices.
const DefaultsDate = "2026-04-24"

// Defaults returns a best-effort price table used when no pricing.toml
// is available and live fetch also fails.
// Prices in USD per 1M tokens.
func Defaults() Table {
	return Table{
		Models: map[string]ModelPrice{
			"claude-opus-4-7": {
				InputPerMTok: 15.00, OutputPerMTok: 75.00,
				CacheCreationPerMTok: 18.75, CacheReadPerMTok: 1.50,
			},
			"claude-sonnet-4-6": {
				InputPerMTok: 3.00, OutputPerMTok: 15.00,
				CacheCreationPerMTok: 3.75, CacheReadPerMTok: 0.30,
			},
			"claude-haiku-4-5": {
				InputPerMTok: 1.00, OutputPerMTok: 5.00,
				CacheCreationPerMTok: 1.25, CacheReadPerMTok: 0.10,
			},
		},
	}
}
