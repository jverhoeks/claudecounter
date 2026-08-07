package limits

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTemp(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "limits.toml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadFullConfig(t *testing.T) {
	p := writeTemp(t, "[limits]\ndaily = 50.0\nweekly = 250.0\nwarn_pct = 70\n")
	got, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Daily != 50.0 || got.Weekly != 250.0 || got.WarnPct != 70 {
		t.Fatalf("got %+v", got)
	}
}

// A missing file is the normal "user has not configured limits" state.
// It must not be an error — the gauge simply hides.
func TestLoadMissingFileIsNotAnError(t *testing.T) {
	got, err := Load(filepath.Join(t.TempDir(), "absent.toml"))
	if err != nil {
		t.Fatalf("missing file must not error, got %v", err)
	}
	if got.Daily != 0 || got.Weekly != 0 {
		t.Fatalf("missing file must yield zero limits, got %+v", got)
	}
}

func TestLoadAppliesDefaultWarnPct(t *testing.T) {
	p := writeTemp(t, "[limits]\ndaily = 10.0\n")
	got, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.WarnPct != DefaultWarnPct {
		t.Fatalf("WarnPct = %d, want %d", got.WarnPct, DefaultWarnPct)
	}
}

func TestLoadMalformedReturnsError(t *testing.T) {
	p := writeTemp(t, "[limits]\ndaily = = =\n")
	if _, err := Load(p); err == nil {
		t.Fatal("malformed TOML must return an error so the caller can log it once")
	}
}
