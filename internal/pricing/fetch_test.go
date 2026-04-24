package pricing

import (
	"os"
	"testing"
)

func TestParsePricingHTML(t *testing.T) {
	body, err := os.ReadFile("testdata/pricing-page.html")
	if err != nil {
		t.Fatal(err)
	}
	table, err := parsePricingHTML(body)
	if err != nil {
		t.Fatal(err)
	}
	p, ok := table.Models["claude-opus-4-7"]
	if !ok {
		t.Fatal("opus not parsed")
	}
	if p.InputPerMTok != 15.00 || p.OutputPerMTok != 75.00 ||
		p.CacheCreationPerMTok != 18.75 || p.CacheReadPerMTok != 1.50 {
		t.Fatalf("opus prices wrong: %+v", p)
	}
	if _, ok := table.Models["claude-sonnet-4-6"]; !ok {
		t.Fatal("sonnet not parsed")
	}
}
