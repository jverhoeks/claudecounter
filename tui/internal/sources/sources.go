// Package sources turns the user's sources.toml into a validated list of
// roots to scan. Each source pairs a vendor (which reader handles it)
// with a user-chosen label (which subscription or install it is).
//
// The root path is the only thing that can distinguish two Claude
// subscriptions: transcripts carry no account identifier, and the one in
// ~/.claude.json is machine-global and reflects whoever is logged in now.
package sources

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// knownVendors are the vendors a reader exists for.
var knownVendors = map[string]bool{"claude": true, "grok": true, "codex": true}

// Source is one configured root.
type Source struct {
	Vendor string
	Label  string
	Root   string
}

// ID is the series identity: vendor and label together. Two sources may
// share a label across vendors, so the label alone is not unique.
func (s Source) ID() string { return s.Vendor + "/" + s.Label }

type Config struct {
	Sources []Source
	// UsedDefaults is true when Sources came from Defaults(home) rather
	// than from a parsed sources.toml — i.e. no config file exists (or
	// none was given). Callers use this to decide how hard a missing
	// root should fail: a root a user actually listed in sources.toml is
	// legitimately allowed to be absent (see splitReachable), but the
	// implicit fallback nobody configured is not — before
	// --sources-config existed, a missing default root was always
	// fatal, and callers restore that here.
	UsedDefaults bool
}

type tomlFile struct {
	Source []struct {
		Vendor string `toml:"vendor"`
		Label  string `toml:"label"`
		Root   string `toml:"root"`
	} `toml:"source"`
}

// DefaultConfigPath sits beside limits.toml so both surfaces read one
// directory.
func DefaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "claudecounter", "sources.toml")
}

// Defaults is the implicit source list used when no config file exists.
//
// The Claude entry is unconditional and always first: it is the original
// hardcoded behaviour, and callers (requireDefaultRoots) still treat a
// missing Claude root as fatal so a first-run user never gets a
// confident silent $0.00.
//
// Other vendors are auto-discovered — added only when their root
// actually exists on this machine. That mirrors how planlimits already
// finds ~/.grok with zero configuration, and it keeps the promise that a
// user who never opts in sees no change: no ~/.grok, no Grok source, no
// difference. Because such an entry is only ever added when the
// directory is there, it is never subject to the must-exist rule.
//
// A discovered root that overlaps one already in the list is dropped
// rather than returned. Load() rejects nested roots outright because a
// user wrote them; this list is assembled by us, so the same hazard —
// every event in the overlap counted twice — is silently avoided instead
// of turned into an error the user cannot act on. It is reachable: a
// CLAUDE_CONFIG_DIR pointing under ~/.grok, or the reverse, nests the
// two.
func Defaults(home string) []Source {
	return DefaultsWithClaudeRoot(home, filepath.Join(home, ".claude", "projects"))
}

// DefaultsWithClaudeRoot is Defaults with the Claude root injected. It
// exists so the overlap branch below is reachable from a test: the two
// real default paths are siblings, so nothing else can exercise it.
func DefaultsWithClaudeRoot(home, claudeRoot string) []Source {
	out := []Source{{
		Vendor: "claude",
		Label:  "claude",
		Root:   claudeRoot,
	}}
	for _, d := range discoverable {
		root := filepath.Join(home, filepath.Join(d.segments...))
		fi, err := os.Stat(root)
		if err != nil || !fi.IsDir() {
			continue
		}
		cand := Source{Vendor: d.vendor, Label: d.vendor, Root: root}
		if checkOverlap(append(append([]Source{}, out...), cand)) != nil {
			continue
		}
		out = append(out, cand)
	}
	return out
}

// discoverable lists the non-Claude vendors Defaults probes for, in the
// order they are appended. Adding a vendor here is all it takes for a
// zero-config install to be counted, provided a reader exists for it.
var discoverable = []struct {
	vendor   string
	segments []string
}{
	{vendor: "grok", segments: []string{".grok", "sessions"}},
	{vendor: "codex", segments: []string{".codex", "sessions"}},
}

// Load reads sources.toml. A missing file yields Defaults(home) and no
// error — that is the normal unconfigured state. A malformed or invalid
// file returns an error so a typo is surfaced rather than silently
// read as "no sources".
func Load(path, home string) (Config, error) {
	if path == "" {
		return Config{Sources: Defaults(home), UsedDefaults: true}, nil
	}
	var f tomlFile
	if _, err := toml.DecodeFile(path, &f); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Config{Sources: Defaults(home), UsedDefaults: true}, nil
		}
		return Config{}, err
	}
	if len(f.Source) == 0 {
		return Config{}, errors.New("sources.toml configures no sources: at least one source is required")
	}

	out := make([]Source, 0, len(f.Source))
	seen := map[string]bool{}
	for i, s := range f.Source {
		if !knownVendors[s.Vendor] {
			return Config{}, fmt.Errorf("source %d: unknown vendor %q", i, s.Vendor)
		}
		if s.Label == "" {
			return Config{}, fmt.Errorf("source %d: label must not be empty", i)
		}
		if s.Root == "" {
			return Config{}, fmt.Errorf("source %d: root must not be empty", i)
		}
		src := Source{Vendor: s.Vendor, Label: s.Label, Root: expand(s.Root, home)}
		if !filepath.IsAbs(src.Root) {
			return Config{}, fmt.Errorf("source %d: root %q must be absolute or start with ~", i, s.Root)
		}
		if seen[src.ID()] {
			return Config{}, fmt.Errorf("duplicate source %s: two roots under one label would merge two subscriptions", src.ID())
		}
		seen[src.ID()] = true
		out = append(out, src)
	}
	if err := checkOverlap(out); err != nil {
		return Config{}, err
	}
	return Config{Sources: out}, nil
}

func expand(p, home string) string {
	if p == "~" {
		return home
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return filepath.Clean(p)
}

// checkOverlap rejects a root nested inside another. An event under both
// would be scanned twice and counted twice, which is a silent doubling of
// the user's spend.
func checkOverlap(ss []Source) error {
	for i := range ss {
		for j := range ss {
			if i == j {
				continue
			}
			a, b := ss[i].Root, ss[j].Root
			if a == b {
				return fmt.Errorf("sources %s and %s share the root %s", ss[i].ID(), ss[j].ID(), a)
			}
			// Special case: "/" is the root of the filesystem and contains everything.
			// Any other path is nested inside it.
			if a == "/" {
				if b != "/" {
					return fmt.Errorf("source %s root %s is nested inside source %s root %s: events would count twice", ss[j].ID(), b, ss[i].ID(), a)
				}
			} else if strings.HasPrefix(b, a+string(filepath.Separator)) {
				return fmt.Errorf("source %s root %s is nested inside source %s root %s: events would count twice", ss[j].ID(), b, ss[i].ID(), a)
			}
		}
	}
	return nil
}
