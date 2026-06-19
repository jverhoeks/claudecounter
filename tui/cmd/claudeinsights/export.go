package main

import (
	"encoding/csv"
	"encoding/json"
	"io"
	"strconv"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

// Digest size bounds — keep LLM input small and predictable.
const (
	digestMaxPrompts = 40
	digestMaxTools   = 120
	digestMaxRunes   = 280
)

func writeJSON(w io.Writer, c insights.CorpusReport) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(c)
}

func writeDigest(w io.Writer, d insights.Digest) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(d)
}

func writeCSV(w io.Writer, c insights.CorpusReport) error {
	cw := csv.NewWriter(w)
	if err := cw.Write([]string{
		"session", "project", "usd", "waste_usd", "category", "detail", "count", "finding_usd",
	}); err != nil {
		return err
	}
	for _, s := range c.Sessions {
		if len(s.Findings) == 0 {
			if err := cw.Write([]string{
				s.ID, s.Project, f2(s.USD), f2(s.WasteUSD), "", "", "", "",
			}); err != nil {
				return err
			}
			continue
		}
		for _, fi := range s.Findings {
			if err := cw.Write([]string{
				s.ID, s.Project, f2(s.USD), f2(s.WasteUSD),
				string(fi.Category), fi.Detail, strconv.Itoa(fi.Count), f2(fi.USD),
			}); err != nil {
				return err
			}
		}
	}
	cw.Flush()
	return cw.Error()
}

func f2(v float64) string { return strconv.FormatFloat(v, 'f', 4, 64) }
