// Package limits evaluates user-configured USD spending ceilings against
// the cost totals the aggregator already computes. It is deliberately
// inert: a missing or unreadable config means "no limits configured",
// never an error that reaches the live counting path.
package limits

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

// DefaultWarnPct is the amber threshold applied when the config omits
// warn_pct. A single threshold covers both windows; per-window
// thresholds are deliberately not supported yet.
const DefaultWarnPct = 80

// Config is the parsed contents of limits.toml. A limit of zero (or
// absent) means that window is unconfigured, which is distinct from a
// limit of zero dollars — an unconfigured window renders no row at all.
type Config struct {
	Daily   float64
	Weekly  float64
	WarnPct int
}

type tomlFile struct {
	Limits struct {
		Daily   float64 `toml:"daily"`
		Weekly  float64 `toml:"weekly"`
		WarnPct int     `toml:"warn_pct"`
	} `toml:"limits"`
}

// DefaultConfigPath is the shared location both the TUI and the menu bar
// app read, so the two surfaces cannot disagree about the user's limits.
func DefaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "claudecounter", "limits.toml")
}

// Load reads limits.toml. A missing file yields a zero Config and no
// error: that is the normal unconfigured state, not a failure. Malformed
// TOML does return an error so the caller can surface it once rather
// than silently behaving as if no limits were set.
func Load(path string) (Config, error) {
	if path == "" {
		return Config{}, nil
	}
	var f tomlFile
	if _, err := toml.DecodeFile(path, &f); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Config{}, nil
		}
		return Config{}, err
	}
	cfg := Config{
		Daily:   f.Limits.Daily,
		Weekly:  f.Limits.Weekly,
		WarnPct: f.Limits.WarnPct,
	}
	if cfg.WarnPct <= 0 {
		cfg.WarnPct = DefaultWarnPct
	}
	return cfg, nil
}
