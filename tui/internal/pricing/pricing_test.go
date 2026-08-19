package pricing

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAndCost(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pricing.toml")
	body := `
[models."claude-opus-4-7"]
input_per_mtok = 15.0
output_per_mtok = 75.0
cache_creation_per_mtok = 18.75
cache_read_per_mtok = 1.50
`
	if err := writeFile(path, body); err != nil {
		t.Fatal(err)
	}
	table, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}

	u := Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000,
		CacheCreationInputTokens: 1_000_000, CacheReadInputTokens: 1_000_000}
	got := table.Cost("claude-opus-4-7", u)
	want := 15.0 + 75.0 + 18.75 + 1.50
	if got != want {
		t.Fatalf("cost: got %v want %v", got, want)
	}

	if table.Cost("unknown-model", u) != 0 {
		t.Fatalf("unknown model must cost 0")
	}
}

func TestLoadMissingFile(t *testing.T) {
	_, err := Load("/nonexistent/pricing.toml")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

// TestLoadSchema_Missing covers a pre-widening cache: a pricing.toml with no
// schema key at all must decode to Schema == 0, so loadPricing treats it as
// a miss and refetches once.
func TestLoadSchema_Missing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pricing.toml")
	body := `
[models."claude-opus-4-7"]
input_per_mtok = 15.0
output_per_mtok = 75.0
`
	if err := writeFile(path, body); err != nil {
		t.Fatal(err)
	}
	table, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if table.Schema != 0 {
		t.Fatalf("Schema = %d, want 0 for a cache with no schema key", table.Schema)
	}
}

// TestLoadSchema_Present covers a cache written by the current SaveTOML.
func TestLoadSchema_Present(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pricing.toml")
	// The literal tracks TableSchema so a bump doesn't turn this into a
	// pre-schema-cache test, which TestLoadSchema_Missing already covers.
	body := fmt.Sprintf(`
schema = %d

[models."claude-opus-4-7"]
input_per_mtok = 15.0
output_per_mtok = 75.0
`, TableSchema)
	if err := writeFile(path, body); err != nil {
		t.Fatal(err)
	}
	table, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if table.Schema != TableSchema {
		t.Fatalf("Schema = %d, want %d", table.Schema, TableSchema)
	}
}

// TestSaveTOML_RoundTrip guards against a real TOML pitfall: top-level keys
// must appear before any [table] header, or a decoder silently reads
// the schema line as a nested key of the last [models."..."] block instead of
// Table.Schema, and the schema marker would never fire. Verify at the
// consumer (Load), not just that SaveTOML ran without error.
func TestSaveTOML_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pricing.toml")
	in := Table{Models: map[string]ModelPrice{
		"claude-opus-4-8": {InputPerMTok: 5, OutputPerMTok: 25, CacheCreationPerMTok: 6.25, CacheReadPerMTok: 0.5},
		"gpt-5.6-sol":     {InputPerMTok: 1.5, OutputPerMTok: 6},
	}}
	if err := SaveTOML(in, path); err != nil {
		t.Fatal(err)
	}
	out, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if out.Schema != TableSchema {
		t.Fatalf("Schema = %d, want %d (schema key must decode as a top-level key, not nested under a model)", out.Schema, TableSchema)
	}
	if len(out.Models) != len(in.Models) {
		t.Fatalf("models = %d, want %d", len(out.Models), len(in.Models))
	}
	for name, want := range in.Models {
		got, ok := out.Models[name]
		if !ok {
			t.Fatalf("model %q missing after round-trip", name)
		}
		if got != want {
			t.Fatalf("model %q round-tripped as %+v, want %+v", name, got, want)
		}
	}
}

func TestDefaultsCoversMajorModels(t *testing.T) {
	d := Defaults()
	for _, m := range []string{"claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"} {
		if !d.Has(m) {
			t.Errorf("Defaults() missing %s", m)
		}
	}
	if DefaultsDate == "" {
		t.Error("DefaultsDate must be set")
	}
}

func TestDefaults_CoversCurrentModels(t *testing.T) {
	d := Defaults()
	for _, m := range []string{
		"claude-opus-4-8",
		"claude-opus-4-7",
		"claude-sonnet-4-6",
		"claude-haiku-4-5-20251001",
		"opus", "sonnet", "haiku",
	} {
		if !d.Has(m) {
			t.Errorf("Defaults() missing price for %q", m)
		}
	}
	// opus-4-8 is the Opus 4.5+ tier: $5 in / $25 out per 1M.
	p := d.Models["claude-opus-4-8"]
	if p.InputPerMTok != 5.00 || p.OutputPerMTok != 25.00 {
		t.Errorf("opus-4-8 price = $%v/$%v, want $5/$25", p.InputPerMTok, p.OutputPerMTok)
	}
}

func writeFile(path, body string) error {
	return os.WriteFile(path, []byte(body), 0o644)
}

// TestAlias_HasResolvesCodexAutoReview covers the defect this alias exists
// to fix: codex-auto-review has no LiteLLM entry of its own, so it must be
// found only by resolving through the alias to gpt-5.6-luna, the model it
// actually bills at.
func TestAlias_HasResolvesCodexAutoReview(t *testing.T) {
	t.Run("present when the aliased model has an entry", func(t *testing.T) {
		table := Table{Models: map[string]ModelPrice{
			"gpt-5.6-luna": {InputPerMTok: 0.20, OutputPerMTok: 1.20},
		}}
		if !table.Has("codex-auto-review") {
			t.Fatal("Has(codex-auto-review) = false, want true via alias to gpt-5.6-luna")
		}
	})

	t.Run("absent when the aliased model has no entry", func(t *testing.T) {
		table := Table{Models: map[string]ModelPrice{
			"claude-opus-4-8": {InputPerMTok: 5, OutputPerMTok: 25},
		}}
		if table.Has("codex-auto-review") {
			t.Fatal("Has(codex-auto-review) = true, want false: gpt-5.6-luna is not in the table")
		}
	})
}

// TestAlias_CostMatchesAliasedModel asserts Cost("codex-auto-review", u)
// equals Cost("gpt-5.6-luna", u) exactly, for a usage with non-zero input,
// output, and cache-read tokens.
func TestAlias_CostMatchesAliasedModel(t *testing.T) {
	table := Table{Models: map[string]ModelPrice{
		"gpt-5.6-luna": {InputPerMTok: 0.20, OutputPerMTok: 1.20, CacheReadPerMTok: 0.02},
	}}
	u := Usage{InputTokens: 5_900_000, OutputTokens: 120_000, CacheReadInputTokens: 30_600_000}

	got := table.Cost("codex-auto-review", u)
	want := table.Cost("gpt-5.6-luna", u)
	if got != want {
		t.Fatalf("Cost(codex-auto-review) = %v, want %v (Cost(gpt-5.6-luna))", got, want)
	}
	if got == 0 {
		t.Fatal("Cost(codex-auto-review) = 0, want non-zero")
	}
}

// TestAlias_DirectEntryWinsOverAlias guards against an alias applied too
// eagerly: if a table happens to carry its own entry for an alias's key
// (e.g. a future LiteLLM release adds a real codex-auto-review row), that
// direct entry must win rather than being shadowed by the redirect to
// gpt-5.6-luna.
func TestAlias_DirectEntryWinsOverAlias(t *testing.T) {
	table := Table{Models: map[string]ModelPrice{
		"codex-auto-review": {InputPerMTok: 99, OutputPerMTok: 99},
		"gpt-5.6-luna":      {InputPerMTok: 0.20, OutputPerMTok: 1.20},
	}}
	if !table.Has("codex-auto-review") {
		t.Fatal("Has(codex-auto-review) = false, want true (direct entry)")
	}
	u := Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000}
	got := table.Cost("codex-auto-review", u)
	want := 99.0 + 99.0
	if got != want {
		t.Fatalf("Cost(codex-auto-review) = %v, want %v (direct entry must win over the alias)", got, want)
	}
}

// TestAlias_ClaudeModelsUnaffected guards against the alias resolution path
// interfering with ordinary, non-aliased lookups.
func TestAlias_ClaudeModelsUnaffected(t *testing.T) {
	table := Table{Models: map[string]ModelPrice{
		"claude-opus-4-8": {InputPerMTok: 5, OutputPerMTok: 25},
	}}
	if !table.Has("claude-opus-4-8") {
		t.Fatal("Has(claude-opus-4-8) = false, want true")
	}
	if table.Has("claude-sonnet-4-6") {
		t.Fatal("Has(claude-sonnet-4-6) = true, want false: not in this table and not an alias key")
	}
	u := Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000}
	got := table.Cost("claude-opus-4-8", u)
	want := 5.0 + 25.0
	if got != want {
		t.Fatalf("Cost(claude-opus-4-8) = %v, want %v", got, want)
	}
}

// TestDefaults_CoversClaude5Family covers the release defect these entries
// exist to fix: claude-opus-5 and claude-sonnet-5 were the two most-used
// models in real logs yet had no Defaults() row, so any install without a
// pricing.toml (or with a failed live fetch) priced ~85% of its traffic at
// $0 and under-reported total spend roughly tenfold.
func TestDefaults_CoversClaude5Family(t *testing.T) {
	d := Defaults()
	for _, m := range []string{
		"claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-mythos-5",
		"fable",
	} {
		if !d.Has(m) {
			t.Errorf("Defaults() missing price for %q", m)
		}
	}
	// Opus 5 sits in the same $5/$25 tier as Opus 4.5 through 4.8.
	if p := d.Models["claude-opus-5"]; p.InputPerMTok != 5.00 || p.OutputPerMTok != 25.00 {
		t.Errorf("opus-5 price = $%v/$%v, want $5/$25", p.InputPerMTok, p.OutputPerMTok)
	}
	// Mythos 5 bills at the Fable tier, above Opus.
	if p := d.Models["claude-mythos-5"]; p.InputPerMTok != 10.00 || p.OutputPerMTok != 50.00 {
		t.Errorf("mythos-5 price = $%v/$%v, want $10/$50", p.InputPerMTok, p.OutputPerMTok)
	}
}

// TestLongContextSuffix_PricesAtBaseRate covers turns logged with the
// 1M-context window (e.g. "claude-opus-5[1m]"). No pricing source keys
// models that way, so without the suffix strip these billed at $0.
func TestLongContextSuffix_PricesAtBaseRate(t *testing.T) {
	d := Defaults()
	u := Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000}

	for _, base := range []string{"claude-opus-5", "claude-opus-4-8", "claude-sonnet-5"} {
		long := base + "[1m]"
		if !d.Has(long) {
			t.Errorf("Has(%q) = false, want true", long)
		}
		if got, want := d.Cost(long, u), d.Cost(base, u); got != want {
			t.Errorf("Cost(%q) = %v, want %v (the base rate)", long, got, want)
		}
	}

	// A real [1m] row must win over the stripped fallback, so a future
	// pricing source that does tier by context length is not shadowed.
	tiered := Table{Models: map[string]ModelPrice{
		"claude-opus-5":     {InputPerMTok: 5.00},
		"claude-opus-5[1m]": {InputPerMTok: 10.00},
	}}
	if p, _ := tiered.resolve("claude-opus-5[1m]"); p.InputPerMTok != 10.00 {
		t.Errorf("direct [1m] row lost to the fallback: got $%v, want $10", p.InputPerMTok)
	}

	// The strip must not invent prices for models nothing knows about.
	if d.Has("claude-nonexistent-9[1m]") {
		t.Error("Has(unknown[1m]) = true, want false")
	}
}
