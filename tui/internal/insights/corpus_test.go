package insights

import "testing"

func TestBuildCorpus(t *testing.T) {
	reports := []SessionReport{
		{ID: "a", Project: "p1", USD: 1, WasteUSD: 0.5, Score: 2, Findings: []Finding{{}, {}}},
		{ID: "b", Project: "p1", USD: 3, WasteUSD: 2, Score: 5, Findings: []Finding{{}}},
		{ID: "c", Project: "p2", USD: 0.2, WasteUSD: 0, Score: 0},
	}
	c := BuildCorpus(reports)
	if c.Sessions[0].ID != "b" {
		t.Errorf("worst-first failed: %s", c.Sessions[0].ID)
	}
	if len(c.Projects) != 2 || c.Projects[0].Project != "p1" {
		t.Errorf("projects: %+v", c.Projects)
	}
	if c.Projects[0].Sessions != 2 || c.Projects[0].WasteUSD != 2.5 {
		t.Errorf("p1 agg: %+v", c.Projects[0])
	}
	if c.TotalUSD != 4.2 || c.TotalWasteUSD != 2.5 {
		t.Errorf("totals: %v %v", c.TotalUSD, c.TotalWasteUSD)
	}
}
