package pricing

import (
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

func writeFile(path, body string) error {
	return os.WriteFile(path, []byte(body), 0o644)
}
