package insights

import "sort"

// ProjectAgg rolls one project's sessions into a single row.
type ProjectAgg struct {
	Project  string  `json:"project"`
	Sessions int     `json:"sessions"`
	USD      float64 `json:"usd"`
	WasteUSD float64 `json:"waste_usd"`
	Findings int     `json:"findings"`
}

// CorpusReport is the ranked, aggregated view across all analyzed sessions.
type CorpusReport struct {
	Sessions      []SessionReport `json:"sessions"`
	Projects      []ProjectAgg    `json:"projects"`
	TotalUSD      float64         `json:"total_usd"`
	TotalWasteUSD float64         `json:"total_waste_usd"`
}

// BuildCorpus ranks sessions worst-first and aggregates per project. Pure.
func BuildCorpus(reports []SessionReport) CorpusReport {
	sorted := make([]SessionReport, len(reports))
	copy(sorted, reports)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Score != sorted[j].Score {
			return sorted[i].Score > sorted[j].Score
		}
		if sorted[i].USD != sorted[j].USD {
			return sorted[i].USD > sorted[j].USD
		}
		return sorted[i].ID < sorted[j].ID
	})

	byProj := map[string]*ProjectAgg{}
	var c CorpusReport
	for _, r := range reports {
		c.TotalUSD += r.USD
		c.TotalWasteUSD += r.WasteUSD
		p := byProj[r.Project]
		if p == nil {
			p = &ProjectAgg{Project: r.Project}
			byProj[r.Project] = p
		}
		p.Sessions++
		p.USD += r.USD
		p.WasteUSD += r.WasteUSD
		p.Findings += len(r.Findings)
	}
	for _, p := range byProj {
		c.Projects = append(c.Projects, *p)
	}
	sort.Slice(c.Projects, func(i, j int) bool {
		if c.Projects[i].WasteUSD != c.Projects[j].WasteUSD {
			return c.Projects[i].WasteUSD > c.Projects[j].WasteUSD
		}
		return c.Projects[i].Project < c.Projects[j].Project
	})
	c.Sessions = sorted
	return c
}
