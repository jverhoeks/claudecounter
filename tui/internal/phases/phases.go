// Package phases classifies subagent spend by phase, language, and model tier.
// It walks the same ~/.claude/projects tree the reader does but reads the
// paired .meta.json files to derive phase labels, and parses tool_use blocks
// to infer the working language from Bash commands and edited file paths.
package phases

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

// Phase labels.
const (
	PhaseOrchestration = "orchestration" // main sessions (no phase metadata)
	PhaseWriting       = "writing"
	PhaseReview        = "review"
	PhaseResearch      = "research"
	PhaseBuild         = "build"
	PhasePlan          = "plan"
	PhaseTest          = "test"
	PhaseOther         = "other"
)

// PhaseOrder controls display order; orchestration (main sessions) goes last.
var PhaseOrder = []string{
	PhaseBuild, PhaseReview, PhaseResearch,
	PhaseTest, PhasePlan, PhaseWriting, PhaseOther, PhaseOrchestration,
}

// LangOrder controls display order.
var LangOrder = []string{
	"go", "rust", "python", "typescript", "javascript",
	"ruby", "java", "csharp", "swift", "terraform", "unknown",
}

var phaseRules = []struct {
	phase string
	re    *regexp.Regexp
}{
	// writing must precede build: "edit ch X" matches writing, not build
	{PhaseWriting, regexp.MustCompile(`(?i)\b(edit\s+(ca|es|ch)\b|expand\s+ch|thin\s+(tics|ch)|gloss[- ]cut|voice\s+line[- ]edit|tic[- ]sweep|close[- ]read|betterment\s+sweep|aggressive\s+gloss|book[- ]wide|translate\s+chapters|ebook)\b`)},
	{PhaseReview, regexp.MustCompile(`(?i)\b(review|audit|quality|code[- ]?review|security|silent[- ]failure|hunt\b|harden\b|sec\s+task|compliance|policy.?correct|hardening|deep\s+audit|best\s+practices)\b`)},
	{PhaseResearch, regexp.MustCompile(`(?i)\b(research|explore|analyz|investigat|find\b|mine\b|map\b|trace\b|scope\b|survey\b|fetch\b|inventory\b|extract\b|deep\s+dive|gather\b|dig\b|triage\b)\b`)},
	{PhaseBuild, regexp.MustCompile(`(?i)\b(implement|build|fix|add|create|update|write|phase\s+[a-h]\b|batch\s+\d|wave\s+\d|task\s+\d|migrate|refactor|wir(e|ing)\b|port\b|scaffold|restore\b|redesign\b|rename\b|replace\b|convert\b|generate|translate\b|expand\b|draft\b|author\b|allowlist\b|complete\b|integrate\b|align\b|reconcil)\b`)},
	{PhasePlan, regexp.MustCompile(`(?i)\b(spec|plan|design|arch|blueprint)\b`)},
	{PhaseTest, regexp.MustCompile(`(?i)\b(test|verify|smoke|e2e)\b`)},
}

var langRules = []struct {
	lang string
	re   *regexp.Regexp
}{
	{"rust", regexp.MustCompile(`\b(cargo|rustc)\b`)},
	{"go", regexp.MustCompile(`\bgo\s+(test|build|run|vet|fmt|mod)\b`)},
	{"python", regexp.MustCompile(`\b(pytest|python3?|pip\b|uv\b|poetry)\b`)},
	{"typescript", regexp.MustCompile(`\b(tsc|vitest|jest)\b`)},
	{"javascript", regexp.MustCompile(`\b(npm|npx|yarn|pnpm|bun|node)\b`)},
	{"ruby", regexp.MustCompile(`\b(rspec|ruby|bundle)\b`)},
	{"java", regexp.MustCompile(`\b(mvn|gradle|javac)\b`)},
	{"csharp", regexp.MustCompile(`\b(dotnet|csc)\b`)},
	{"swift", regexp.MustCompile(`\bswift\s+test\b|\bxcodebuild\b`)},
	{"terraform", regexp.MustCompile(`\b(terraform|tofu)\b`)},
}

var extLang = map[string]string{
	".go":    "go",
	".rs":    "rust",
	".py":    "python",
	".ts":    "typescript",
	".tsx":   "typescript",
	".js":    "javascript",
	".jsx":   "javascript",
	".rb":    "ruby",
	".java":  "java",
	".cs":    "csharp",
	".swift": "swift",
	".tf":    "terraform",
}

// Key identifies one (phase, language, model tier) bucket.
type Key struct {
	Phase string
	Lang  string
	Tier  string
}

// ProjPhaseKey identifies one (project, phase) bucket.
type ProjPhaseKey struct {
	Project string
	Phase   string
}

// Cell holds aggregated USD and agent count for one bucket.
type Cell struct {
	USD   float64
	Count int
}

// AgentRecord holds one subagent's data for the top-N list.
type AgentRecord struct {
	Description string
	Phase       string
	Lang        string
	Tier        string
	Project     string
	USD         float64
	SpawnDepth  int
}

// CostBreakdown splits a USD total into its four token-cost components.
type CostBreakdown struct {
	Input      float64
	Output     float64
	CacheWrite float64
	CacheRead  float64
}

func (c CostBreakdown) Total() float64 {
	return c.Input + c.Output + c.CacheWrite + c.CacheRead
}

// Pct returns the fraction of total for a component, 0 when total is 0.
func pct(part, total float64) float64 {
	if total == 0 {
		return 0
	}
	return 100 * part / total
}

// SessionRecord holds one main session's data for the top-N list.
type SessionRecord struct {
	ID        string
	Project   string
	Start     time.Time
	End       time.Time          // last API call timestamp (wall-clock; includes idle/resumed gaps)
	USD       float64
	Responses int                // unique model responses (API calls) in the session
	ByTier    map[string]float64 // model tier → cost within this session
	Breakdown CostBreakdown
}

// ProjModelKey identifies a (project, model tier) bucket for main sessions.
type ProjModelKey struct {
	Project string
	Tier    string
}

// Report is the output of Scan.
type Report struct {
	Month           time.Month
	Year            int
	Total           float64               // main + subagent for the civil month
	MainUSD         float64               // orchestration (main sessions only)
	SubUSD          float64               // subagent only
	ByPhase         map[string]*Cell
	ByLang          map[string]*Cell      // subagents only
	ByKey           map[Key]*Cell         // subagents only: phase × lang × tier
	ByProj          map[string]*Cell      // subagents only: project → total
	ByProjPhase     map[ProjPhaseKey]*Cell // subagents only: project × phase
	TopAgents       []AgentRecord         // all agents, caller sorts/truncates
	ByDepth         map[string]*Cell      // subagents only: spawn depth ("0", "1", …)
	MainByProj      map[string]*Cell      // main sessions: project → total
	MainByProjModel map[ProjModelKey]*Cell // main sessions: project × tier
	TopSessions     []SessionRecord       // all main sessions, caller sorts/truncates
	MainBreakdown   CostBreakdown         // aggregate token-cost breakdown for all main sessions
}

// Scan walks root and returns a Report for the current civil month.
func Scan(root string, table pricing.Table) (Report, error) {
	now := time.Now().Local()
	rep := Report{
		Month:           now.Month(),
		Year:            now.Year(),
		ByPhase:         map[string]*Cell{},
		ByLang:          map[string]*Cell{},
		ByKey:           map[Key]*Cell{},
		ByProj:          map[string]*Cell{},
		ByProjPhase:     map[ProjPhaseKey]*Cell{},
		ByDepth:         map[string]*Cell{},
		MainByProj:      map[string]*Cell{},
		MainByProjModel: map[ProjModelKey]*Cell{},
	}

	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
	// mtime pre-filter: scan files modified at or after one day before monthStart
	// to avoid missing any event near the boundary.
	mtimeCutoff := monthStart.Add(-24 * time.Hour)

	seenSub := map[string]struct{}{}
	if err := scanSubagents(root, table, monthStart, mtimeCutoff, seenSub, &rep); err != nil {
		return rep, err
	}

	seenMain := map[string]struct{}{}
	if err := scanMainSessions(root, table, monthStart, mtimeCutoff, seenMain, &rep); err != nil {
		return rep, err
	}

	rep.Total = rep.MainUSD + rep.SubUSD
	if rep.MainUSD > 0 {
		addCell(rep.ByPhase, PhaseOrchestration, rep.MainUSD, 0)
	}
	sort.Slice(rep.TopAgents, func(i, j int) bool {
		return rep.TopAgents[i].USD > rep.TopAgents[j].USD
	})
	sort.Slice(rep.TopSessions, func(i, j int) bool {
		return rep.TopSessions[i].USD > rep.TopSessions[j].USD
	})
	return rep, nil
}

type agentMeta struct {
	Description string `json:"description"`
	SpawnDepth  int    `json:"spawnDepth"` // 0 when field absent (top-level)
}

func scanSubagents(root string, table pricing.Table, monthStart, mtimeCutoff time.Time, seen map[string]struct{}, rep *Report) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if !strings.HasSuffix(d.Name(), ".meta.json") {
			return nil
		}
		if !strings.Contains(filepath.ToSlash(path), "/subagents/") {
			return nil
		}
		info, err2 := d.Info()
		if err2 != nil || info.ModTime().Before(mtimeCutoff) {
			return nil
		}

		data, err2 := os.ReadFile(path)
		if err2 != nil {
			return nil
		}
		var meta agentMeta
		if json.Unmarshal(data, &meta) != nil {
			return nil
		}

		jsonlPath := strings.TrimSuffix(path, ".meta.json") + ".jsonl"
		usd, tier, lang, _ := parseAgentJSONL(jsonlPath, table, monthStart, seen)
		if usd == 0 {
			return nil
		}

		proj := projectFromPath(filepath.ToSlash(path))
		phase := classifyPhase(meta.Description)
		rep.SubUSD += usd
		addCell(rep.ByPhase, phase, usd, 1)
		addCell(rep.ByLang, lang, usd, 1)
		addKeyCell(rep.ByKey, Key{Phase: phase, Lang: lang, Tier: tier}, usd, 1)
		addCell(rep.ByProj, proj, usd, 1)
		addProjPhaseCell(rep.ByProjPhase, ProjPhaseKey{Project: proj, Phase: phase}, usd, 1)
		depthKey := fmt.Sprintf("%d", meta.SpawnDepth)
		addCell(rep.ByDepth, depthKey, usd, 1)
		rep.TopAgents = append(rep.TopAgents, AgentRecord{
			Description: meta.Description,
			Phase:       phase,
			Lang:        lang,
			Tier:        tier,
			Project:     proj,
			USD:         usd,
			SpawnDepth:  meta.SpawnDepth,
		})
		return nil
	})
}

func scanMainSessions(root string, table pricing.Table, monthStart, mtimeCutoff time.Time, seen map[string]struct{}, rep *Report) error {
	matches, err := filepath.Glob(filepath.Join(root, "*", "*.jsonl"))
	if err != nil {
		return err
	}
	for _, path := range matches {
		info, err2 := os.Stat(path)
		if err2 != nil || info.ModTime().Before(mtimeCutoff) {
			continue
		}
		usd, start, end, responses, byTier, bd := parseMainJSONL(path, table, monthStart, seen)
		if usd == 0 {
			continue
		}
		proj := projectFromPath(filepath.ToSlash(path))
		sessionID := strings.TrimSuffix(filepath.Base(path), ".jsonl")
		rep.MainUSD += usd
		rep.MainBreakdown.Input += bd.Input
		rep.MainBreakdown.Output += bd.Output
		rep.MainBreakdown.CacheWrite += bd.CacheWrite
		rep.MainBreakdown.CacheRead += bd.CacheRead
		addCell(rep.MainByProj, proj, usd, 1)
		for tier, cost := range byTier {
			addKeyCell2(rep.MainByProjModel, ProjModelKey{Project: proj, Tier: tier}, cost, 0)
		}
		rep.TopSessions = append(rep.TopSessions, SessionRecord{
			ID:        sessionID,
			Project:   proj,
			Start:     start,
			End:       end,
			USD:       usd,
			Responses: responses,
			ByTier:    byTier,
			Breakdown: bd,
		})
	}
	return nil
}

// pLine is the minimal JSONL record for phases scanning.
type pLine struct {
	Timestamp time.Time `json:"timestamp"`
	RequestID string    `json:"requestId"`
	Message   *struct {
		ID    string `json:"id"`
		Model string `json:"model"`
		Usage *struct {
			InputTokens              uint64 `json:"input_tokens"`
			OutputTokens             uint64 `json:"output_tokens"`
			CacheCreationInputTokens uint64 `json:"cache_creation_input_tokens"`
			CacheReadInputTokens     uint64 `json:"cache_read_input_tokens"`
		} `json:"usage"`
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type pBlock struct {
	Type  string          `json:"type"`
	Name  string          `json:"name"`
	Input json.RawMessage `json:"input"`
}

type pInput struct {
	Command  string `json:"command"`
	FilePath string `json:"file_path"`
}

func monthEnd(monthStart time.Time) time.Time {
	return time.Date(monthStart.Year(), monthStart.Month()+1, 1, 0, 0, 0, 0, monthStart.Location())
}

func parseAgentJSONL(path string, table pricing.Table, monthStart time.Time, seen map[string]struct{}) (usd float64, tier, lang string, err error) {
	f, err2 := os.Open(path)
	if err2 != nil {
		return 0, "unknown", "unknown", nil
	}
	defer f.Close()

	end := monthEnd(monthStart)
	var cmds, paths []string

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var r pLine
		if json.Unmarshal(line, &r) != nil {
			continue
		}
		if r.Timestamp.IsZero() || r.Timestamp.Before(monthStart) || !r.Timestamp.Before(end) {
			continue
		}
		if r.Message == nil {
			continue
		}

		if u := r.Message.Usage; u != nil && r.Message.Model != "<synthetic>" {
			key := r.Message.ID + ":" + r.RequestID
			if _, dup := seen[key]; !dup {
				seen[key] = struct{}{}
				usd += table.Cost(r.Message.Model, pricing.Usage{
					InputTokens:              u.InputTokens,
					OutputTokens:             u.OutputTokens,
					CacheCreationInputTokens: u.CacheCreationInputTokens,
					CacheReadInputTokens:     u.CacheReadInputTokens,
				})
				if tier == "" {
					tier = modelTier(r.Message.Model)
				}
			}
		}

		if len(r.Message.Content) > 0 && r.Message.Content[0] == '[' {
			var blocks []pBlock
			if json.Unmarshal(r.Message.Content, &blocks) == nil {
				for _, b := range blocks {
					if b.Type != "tool_use" {
						continue
					}
					var inp pInput
					if json.Unmarshal(b.Input, &inp) != nil {
						continue
					}
					switch b.Name {
					case "Bash":
						if inp.Command != "" {
							cmds = append(cmds, inp.Command)
						}
					case "Write", "Edit", "NotebookEdit":
						if inp.FilePath != "" {
							paths = append(paths, inp.FilePath)
						}
					}
				}
			}
		}
	}

	if tier == "" {
		tier = "unknown"
	}
	return usd, tier, detectLang(cmds, paths), sc.Err()
}

func parseMainJSONL(path string, table pricing.Table, monthStart time.Time, seen map[string]struct{}) (usd float64, start, end time.Time, responses int, byTier map[string]float64, bd CostBreakdown) {
	f, err := os.Open(path)
	if err != nil {
		return 0, time.Time{}, time.Time{}, 0, nil, CostBreakdown{}
	}
	defer f.Close()

	mEnd := monthEnd(monthStart)
	byTier = map[string]float64{}

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var r pLine
		if json.Unmarshal(line, &r) != nil {
			continue
		}
		if r.Timestamp.IsZero() || r.Timestamp.Before(monthStart) || !r.Timestamp.Before(mEnd) {
			continue
		}
		if r.Message == nil || r.Message.Usage == nil || r.Message.Model == "<synthetic>" {
			continue
		}
		key := r.Message.ID + ":" + r.RequestID
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		if start.IsZero() {
			start = r.Timestamp
		}
		end = r.Timestamp
		responses++
		u := r.Message.Usage
		m := r.Message.Model
		inp := table.Cost(m, pricing.Usage{InputTokens: u.InputTokens})
		out := table.Cost(m, pricing.Usage{OutputTokens: u.OutputTokens})
		cw := table.Cost(m, pricing.Usage{CacheCreationInputTokens: u.CacheCreationInputTokens})
		cr := table.Cost(m, pricing.Usage{CacheReadInputTokens: u.CacheReadInputTokens})
		cost := inp + out + cw + cr
		usd += cost
		byTier[modelTier(m)] += cost
		bd.Input += inp
		bd.Output += out
		bd.CacheWrite += cw
		bd.CacheRead += cr
	}
	return usd, start, end, responses, byTier, bd
}

func classifyPhase(desc string) string {
	for _, rule := range phaseRules {
		if rule.re.MatchString(desc) {
			return rule.phase
		}
	}
	return PhaseOther
}

func detectLang(cmds, filePaths []string) string {
	votes := map[string]int{}
	for _, cmd := range cmds {
		for _, rule := range langRules {
			if rule.re.MatchString(cmd) {
				votes[rule.lang] += 2
				break
			}
		}
	}
	for _, p := range filePaths {
		ext := strings.ToLower(filepath.Ext(p))
		if l, ok := extLang[ext]; ok {
			votes[l]++
		}
	}
	if len(votes) == 0 {
		return "unknown"
	}
	best, bestV := "", 0
	for l, v := range votes {
		if v > bestV || (v == bestV && l < best) {
			best, bestV = l, v
		}
	}
	return best
}

func modelTier(model string) string {
	switch {
	case strings.Contains(model, "fable"):
		return "fable-5"
	case strings.Contains(model, "opus"):
		return "opus"
	case strings.Contains(model, "sonnet"):
		return "sonnet"
	case strings.Contains(model, "haiku"):
		return "haiku"
	}
	return "other"
}

func addCell(m map[string]*Cell, key string, usd float64, count int) {
	if m[key] == nil {
		m[key] = &Cell{}
	}
	m[key].USD += usd
	m[key].Count += count
}

func addKeyCell(m map[Key]*Cell, key Key, usd float64, count int) {
	if m[key] == nil {
		m[key] = &Cell{}
	}
	m[key].USD += usd
	m[key].Count += count
}

func addKeyCell2(m map[ProjModelKey]*Cell, key ProjModelKey, usd float64, count int) {
	if m[key] == nil {
		m[key] = &Cell{}
	}
	m[key].USD += usd
	m[key].Count += count
}

func addProjPhaseCell(m map[ProjPhaseKey]*Cell, key ProjPhaseKey, usd float64, count int) {
	if m[key] == nil {
		m[key] = &Cell{}
	}
	m[key].USD += usd
	m[key].Count += count
}

// projectFromPath extracts the encoded project segment from a /projects/<project>/... path.
func projectFromPath(slashPath string) string {
	idx := strings.Index(slashPath, "/projects/")
	if idx < 0 {
		return ""
	}
	rest := slashPath[idx+len("/projects/"):]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		return rest[:i]
	}
	return rest
}
