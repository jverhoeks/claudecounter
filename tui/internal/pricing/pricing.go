package pricing

import (
	"fmt"
	"strings"

	"github.com/BurntSushi/toml"
)

type Usage struct {
	InputTokens              uint64
	OutputTokens             uint64
	CacheCreationInputTokens uint64
	CacheReadInputTokens     uint64
	// CacheCreation1hInputTokens is the subset of
	// CacheCreationInputTokens written with a 1-hour TTL, which bills at
	// 2× base input instead of the 5-minute rate's 1.25×. It is a subset,
	// not a sibling: every token counter that only reports volume can keep
	// reading CacheCreationInputTokens and stay correct.
	//
	// Claude Code reports the split as usage.cache_creation.{ephemeral_1h,
	// ephemeral_5m}_input_tokens. Those two do not always sum to
	// cache_creation_input_tokens (observed: 507,455 vs 510,803 over one
	// day), so Cost derives the 5-minute share by subtraction — the
	// unattributed remainder bills at the cheaper rate rather than
	// vanishing from the total.
	CacheCreation1hInputTokens uint64
}

type ModelPrice struct {
	InputPerMTok         float64 `toml:"input_per_mtok"`
	OutputPerMTok        float64 `toml:"output_per_mtok"`
	CacheCreationPerMTok float64 `toml:"cache_creation_per_mtok"`
	CacheReadPerMTok     float64 `toml:"cache_read_per_mtok"`
	// CacheCreation1hPerMTok is LiteLLM's
	// cache_creation_input_token_cost_above_1hr. It is optional: a
	// pricing.toml written before this field existed leaves it 0, and
	// cacheCreation1hRate falls back to the documented universal rule
	// (2× base input) rather than forcing a refetch.
	CacheCreation1hPerMTok float64 `toml:"cache_creation_1h_per_mtok"`
}

// cacheCreation1hRate returns the per-MTok rate for 1-hour cache writes.
// Anthropic prices these at a flat 2× base input for every model, so the
// fallback is exact rather than approximate — the table field only exists
// so a future model that breaks the rule can override it.
func (p ModelPrice) cacheCreation1hRate() float64 {
	if p.CacheCreation1hPerMTok > 0 {
		return p.CacheCreation1hPerMTok
	}
	return p.InputPerMTok * 2
}

// TableSchema is bumped whenever a fetched cache can be missing models a
// fresh fetch would now include — either because parseLiteLLM's provider
// filter widened, or because upstream gained models that any cache written
// before them cannot contain. A cache saved under an older schema is stale
// in a way len(Models) > 0 can't detect: it's a complete, valid table —
// just missing models, which it would silently price at $0 forever.
// loadPricing compares a loaded table's Schema against this constant and
// refetches once when it's behind, rather than trusting any non-empty cache
// indefinitely.
//
// 3: LiteLLM gained claude-opus-5 and claude-sonnet-5. Every cache fetched
// before they landed prices what are now the two most-used models at $0,
// and is otherwise indistinguishable from a current one.
const TableSchema = 3

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

// modelAliases maps a display model name with no LiteLLM entry of its own
// to the model it actually bills at. Codex's auto-review runs on GPT-5.6
// Luna ($0.20/Mtok in, $1.20/Mtok out) but the reader emits the display
// name codex-auto-review, which has no pricing row — see aliasedModel.
//
// This is a map rather than branching logic because the model behind a
// display name like this is a moving target: a future Codex release edits
// a map entry here, not the code that resolves it.
var modelAliases = map[string]string{"codex-auto-review": "gpt-5.6-luna"}

// aliasedModel resolves model through modelAliases, unconditionally. Every
// model outside the map maps to itself, so Has and Cost can call this
// without special-casing which names are aliased.
func aliasedModel(model string) string {
	if alias, ok := modelAliases[model]; ok {
		return alias
	}
	return model
}

// longContextSuffix marks a turn that ran with the 1M-token context window
// enabled: Claude Code logs those as e.g. "claude-opus-5[1m]". No pricing
// source keys models this way — LiteLLM has no [1m] rows at all — so before
// this was stripped, every such turn resolved to nothing and billed at $0.
//
// Stripping is the correct fix rather than a separate rate because the
// current 1M-context models price flat: LiteLLM carries no
// *_above_200k_tokens premium for claude-opus-5, claude-opus-4-8,
// claude-sonnet-5, claude-fable-5 or claude-mythos-5 (its only "above"
// field is cache_creation_input_token_cost_above_1hr, a cache-TTL rate
// unrelated to context length). If a future model does tier by context
// length, that needs a real [1m] row here, not this fallback.
const longContextSuffix = "[1m]"

// resolve returns the ModelPrice a model should be priced against: model's
// own entry if the table has one, otherwise its alias's entry (which may
// itself be absent), and failing both, whatever the same lookups find for
// the name with any [1m] long-context suffix removed. A direct entry always
// wins over the alias — see TestAlias_DirectEntryWinsOverAlias — so a future
// LiteLLM release adding a real row for an aliased or [1m] name is never
// shadowed by the fallback.
func (t Table) resolve(model string) (ModelPrice, bool) {
	if p, ok := t.lookup(model); ok {
		return p, true
	}
	if base := strings.TrimSuffix(model, longContextSuffix); base != model {
		return t.lookup(base)
	}
	return ModelPrice{}, false
}

// lookup tries model's own entry, then its alias's.
func (t Table) lookup(model string) (ModelPrice, bool) {
	if p, ok := t.Models[model]; ok {
		return p, true
	}
	p, ok := t.Models[aliasedModel(model)]
	return p, ok
}

func (t Table) Cost(model string, u Usage) float64 {
	p, ok := t.resolve(model)
	if !ok {
		return 0
	}
	const m = 1_000_000.0
	// Clamp before subtracting: CacheCreation1hInputTokens is meant to be a
	// subset, but a malformed event that reports more 1h tokens than total
	// cache-creation tokens must not underflow uint64 into a nonsense bill.
	cc1h := u.CacheCreation1hInputTokens
	if cc1h > u.CacheCreationInputTokens {
		cc1h = u.CacheCreationInputTokens
	}
	cc5m := u.CacheCreationInputTokens - cc1h
	return float64(u.InputTokens)/m*p.InputPerMTok +
		float64(u.OutputTokens)/m*p.OutputPerMTok +
		float64(cc5m)/m*p.CacheCreationPerMTok +
		float64(cc1h)/m*p.cacheCreation1hRate() +
		float64(u.CacheReadInputTokens)/m*p.CacheReadPerMTok
}

// Has reports whether model can be priced — directly or via alias. A model
// found only through the alias (e.g. codex-auto-review, resolving to
// gpt-5.6-luna) now counts as known here, which is the deliberate,
// desired effect on agg's Unknown tally: it is genuinely priced, so it
// should not be counted as unpriced.
func (t Table) Has(model string) bool {
	_, ok := t.resolve(model)
	return ok
}
