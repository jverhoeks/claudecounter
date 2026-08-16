package reader

import (
	"path/filepath"
	"strings"
)

// vendorParser is everything that differs between one vendor's
// transcripts and another's. Keeping it behind an interface rather than
// a chain of `if vendor == …` inside OnChange keeps each vendor's quirks
// — which files carry usage, how a project key is derived, how many
// events one line yields — in one place.
type vendorParser interface {
	// Walkable reports whether a file base name can carry usage. The
	// initial scan skips everything else, which matters for Grok: its
	// session directories hold other files whose token fields are
	// cumulative context, not usage.
	Walkable(name string) bool
	// Parse turns one line into zero or more events. Zero is normal (a
	// line with nothing we want). An error means the line was not valid
	// JSON and is counted as a parse error, never as spend.
	Parse(line []byte, slashPath string) ([]Event, error)
	// Project returns the canonical project key for a transcript path,
	// given the source's configured root.
	Project(root, slashPath string) string
	// IsSubagent reports whether the path belongs to a subagent
	// transcript rather than a main session, given the source's
	// configured root.
	IsSubagent(root, slashPath string) bool
}

// projectUnderRoot returns the first path segment of slashPath below
// root, or ok=false when slashPath isn't under root at all.
//
// This is root-relative rather than anchored on a literal marker
// ("/projects/" for Claude, "/sessions/" for Grok): sources.Load places
// no requirement that a configured root be named "projects" or
// "sessions", so a marker search silently misfiles every event under a
// root that omits it — flagged 2026-08-15 as a live risk for a custom
// Grok root, where it would mis-attribute subagent spend as main-session
// spend with no error and no log. Root-relative derivation is a no-op
// for every shipped configuration: under ~/.claude/projects the first
// segment below root already is the encoded project key, and under
// ~/.grok/sessions it already is the encoded cwd.
func projectUnderRoot(root, slashPath string) (segment string, ok bool) {
	slashRoot := strings.TrimSuffix(filepath.ToSlash(root), "/")
	if slashRoot == "" || !strings.HasPrefix(slashPath, slashRoot+"/") {
		return "", false
	}
	rest := slashPath[len(slashRoot)+1:]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		return rest[:i], true
	}
	return rest, true
}

// parserFor is a pure vendor→parser lookup for the two STATELESS
// parsers, where a fresh value returned per call is harmless because
// every method call is independent of the last. codex is deliberately
// absent: codexParser carries running totals and session_meta-derived
// state across calls, so a fresh instance per call is exactly wrong for
// it — see codexParser's doc comment and Reader.parserForChange, which
// keeps one *codexParser per file path instead of asking here for a new
// one.
func parserFor(vendor string) vendorParser {
	switch vendor {
	case "grok":
		return grokParser{}
	default:
		return claudeParser{}
	}
}

// claudeParser is today's behaviour, extracted unchanged.
type claudeParser struct{}

func (claudeParser) Walkable(name string) bool { return filepath.Ext(name) == ".jsonl" }

func (claudeParser) Parse(line []byte, _ string) ([]Event, error) {
	ev, ok, err := parseLine(line)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, nil
	}
	return []Event{ev}, nil
}

// Project derives the project key as the first path segment under the
// source root — see projectUnderRoot. Note this is deliberately not
// projectFromPath (which anchors on a literal "/projects/" marker and
// remains in this package only because TestProjectFromPath_BothSeparators
// exercises it directly): a custom Claude root has the same
// mis-attribution risk this replaces for Grok.
func (claudeParser) Project(root, slashPath string) string {
	seg, _ := projectUnderRoot(root, slashPath)
	return seg
}

// IsSubagent doesn't need root: "/subagents/" is a fixed subdirectory
// name under any session directory regardless of where the root sits.
func (claudeParser) IsSubagent(_, slashPath string) bool {
	return strings.Contains(slashPath, "/subagents/")
}
