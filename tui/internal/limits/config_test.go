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
// It must not be an error — the gauge simply hides. WarnPct must still be
// clamped to DefaultWarnPct here, same as a parsed file that omits
// warn_pct: an un-clamped 0 flows straight into ui.RenderGauges (via
// gatherGauges), where pct >= 0 is true for nearly every percentage —
// painting every plan row amber for the commonest real configuration,
// a user with no limits.toml at all.
func TestLoadMissingFileIsNotAnError(t *testing.T) {
	got, err := Load(filepath.Join(t.TempDir(), "absent.toml"))
	if err != nil {
		t.Fatalf("missing file must not error, got %v", err)
	}
	if got.Daily != 0 || got.Weekly != 0 {
		t.Fatalf("missing file must yield zero limits, got %+v", got)
	}
	if got.WarnPct != DefaultWarnPct {
		t.Fatalf("missing file: WarnPct = %d, want %d (DefaultWarnPct)", got.WarnPct, DefaultWarnPct)
	}
}

// An empty path is DefaultConfigPath()'s failure mode (os.UserHomeDir
// erroring) and must degrade exactly like a missing file — including the
// WarnPct clamp, not just Daily/Weekly.
func TestLoadEmptyPathAppliesDefaultWarnPct(t *testing.T) {
	got, err := Load("")
	if err != nil {
		t.Fatalf("empty path must not error, got %v", err)
	}
	if got.WarnPct != DefaultWarnPct {
		t.Fatalf("empty path: WarnPct = %d, want %d (DefaultWarnPct)", got.WarnPct, DefaultWarnPct)
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
