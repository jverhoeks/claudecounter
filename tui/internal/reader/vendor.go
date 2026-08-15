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
	// Project returns the canonical project key for a transcript path.
	Project(slashPath string) string
	// IsSubagent reports whether the path belongs to a subagent
	// transcript rather than a main session.
	IsSubagent(slashPath string) bool
}

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

func (claudeParser) Project(slashPath string) string { return projectFromPath(slashPath) }

func (claudeParser) IsSubagent(slashPath string) bool {
	return strings.Contains(slashPath, "/subagents/")
}
