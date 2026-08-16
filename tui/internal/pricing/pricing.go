package pricing

import (
	"fmt"

	"github.com/BurntSushi/toml"
)

type Usage struct {
	InputTokens              uint64
	OutputTokens             uint64
	CacheCreationInputTokens uint64
	CacheReadInputTokens     uint64
}

type ModelPrice struct {
	InputPerMTok         float64 `toml:"input_per_mtok"`
	OutputPerMTok        float64 `toml:"output_per_mtok"`
	CacheCreationPerMTok float64 `toml:"cache_creation_per_mtok"`
	CacheReadPerMTok     float64 `toml:"cache_read_per_mtok"`
}

// TableSchema is bumped whenever parseLiteLLM's provider filter widens (or
// otherwise changes which models a fetch can produce). A cache saved under
// an older schema is stale in a way len(Models) > 0 can't detect: it's a
// complete, valid table — just missing an entire provider's worth of
// models, which would silently price them at $0 forever. loadPricing
// compares a loaded table's Schema against this constant and refetches once
// when it's behind, rather than trusting any non-empty cache indefinitely.
const TableSchema = 2

type Table struct {
	// Schema is 0 for any cache written before this field existed (no
	// "schema" key in the file at all) or the schema stamped by SaveTOML.
	Schema int                   `toml:"schema"`
	Models map[string]ModelPrice `toml:"models"`
}

func Load(path string) (Table, error) {
	var t Table
	if _, err := toml.DecodeFile(path, &t); err != nil {
		return Table{}, fmt.Errorf("load pricing: %w", err)
	}
	if t.Models == nil {
		t.Models = map[string]ModelPrice{}
	}
	return t, nil
}

func (t Table) Cost(model string, u Usage) float64 {
	p, ok := t.Models[model]
	if !ok {
		return 0
	}
	const m = 1_000_000.0
	return float64(u.InputTokens)/m*p.InputPerMTok +
		float64(u.OutputTokens)/m*p.OutputPerMTok +
		float64(u.CacheCreationInputTokens)/m*p.CacheCreationPerMTok +
		float64(u.CacheReadInputTokens)/m*p.CacheReadPerMTok
}

func (t Table) Has(model string) bool {
	_, ok := t.Models[model]
	return ok
}
