# claudecounter TUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a cross-platform Go TUI that tails `~/.claude/projects/**/*.jsonl` and displays realtime Claude Code spend (today / this month, total and per-model) across three togglable views.

**Architecture:** fsnotify watcher → line-offset JSONL reader → per-day/per-model aggregator → Bubble Tea UI. Pricing is loaded from `~/.config/claudecounter/pricing.toml` with HTTP-fetch fallback on miss, and a baked-in defaults table as last resort.

**Tech Stack:** Go 1.22+, `bubbletea`, `lipgloss`, `fsnotify`, `BurntSushi/toml`, `PuerkitoBio/goquery`.

**Spec:** [`docs/superpowers/specs/2026-04-24-claudecounter-tui-design.md`](../specs/2026-04-24-claudecounter-tui-design.md)

---

## File Structure

```
claudecounter/
├── go.mod
├── go.sum
├── README.md
├── cmd/claudecounter/
│   ├── main.go
│   └── integration_test.go
├── internal/
│   ├── pricing/
│   │   ├── pricing.go
│   │   ├── pricing_test.go
│   │   ├── defaults.go
│   │   ├── fetch.go
│   │   ├── fetch_test.go
│   │   └── testdata/pricing-page.html
│   ├── reader/
│   │   ├── reader.go
│   │   ├── reader_test.go
│   │   └── testdata/
│   │       ├── session_normal.jsonl
│   │       └── session_malformed.jsonl
│   ├── agg/
│   │   ├── agg.go
│   │   └── agg_test.go
│   ├── watcher/
│   │   ├── watcher.go
│   │   └── watcher_test.go
│   └── ui/
│       ├── model.go
│       ├── format.go
│       ├── view_minimal.go
│       ├── view_split.go
│       └── view_full.go
```

---

## Task 1: Bootstrap Go module

**Files:**
- Create: `go.mod`, `.gitignore`

- [ ] **Step 1: Initialize module**

Run:
```bash
go mod init github.com/jjverhoeks/claudecounter
```

- [ ] **Step 2: Create .gitignore**

Write `.gitignore`:
```
/claudecounter
/bin/
*.test
coverage.out
.DS_Store
```

- [ ] **Step 3: Add core dependencies**

Run:
```bash
go get github.com/charmbracelet/bubbletea@latest
go get github.com/charmbracelet/lipgloss@latest
go get github.com/fsnotify/fsnotify@latest
go get github.com/BurntSushi/toml@latest
go get github.com/PuerkitoBio/goquery@latest
```

- [ ] **Step 4: Commit**

```bash
git add go.mod go.sum .gitignore
git commit -m "chore: bootstrap go module with core deps"
```

---

## Task 2: pricing — types, Load, Cost (TDD)

**Files:**
- Create: `internal/pricing/pricing.go`
- Create: `internal/pricing/pricing_test.go`

- [ ] **Step 1: Write failing test**

Create `internal/pricing/pricing_test.go`:
```go
package pricing

import (
	"path/filepath"
	"testing"
)

func TestLoadAndCost(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pricing.toml")
	body := `
[models."claude-opus-4-7"]
input_per_mtok = 15.0
output_per_mtok = 75.0
cache_creation_per_mtok = 18.75
cache_read_per_mtok = 1.50
`
	if err := writeFile(path, body); err != nil {
		t.Fatal(err)
	}
	table, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}

	u := Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000,
		CacheCreationInputTokens: 1_000_000, CacheReadInputTokens: 1_000_000}
	got := table.Cost("claude-opus-4-7", u)
	want := 15.0 + 75.0 + 18.75 + 1.50
	if got != want {
		t.Fatalf("cost: got %v want %v", got, want)
	}

	if table.Cost("unknown-model", u) != 0 {
		t.Fatalf("unknown model must cost 0")
	}
}

func TestLoadMissingFile(t *testing.T) {
	_, err := Load("/nonexistent/pricing.toml")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}
```

Add a tiny helper at the bottom of the test file:
```go
func writeFile(path, body string) error {
	return os.WriteFile(path, []byte(body), 0o644)
}
```
And add `"os"` to the imports.

- [ ] **Step 2: Run the test, confirm it fails**

Run: `go test ./internal/pricing/...`
Expected: build failure — `Load`, `Usage`, `Table` undefined.

- [ ] **Step 3: Implement pricing.go**

Create `internal/pricing/pricing.go`:
```go
package pricing

import (
	"fmt"

	"github.com/BurntSushi/toml"
)

type Usage struct {
	InputTokens              uint64
	OutputTokens             uint64
	CacheCreationInputTokens uint64
	CacheReadInputTokens     uint64
}

type ModelPrice struct {
	InputPerMTok         float64 `toml:"input_per_mtok"`
	OutputPerMTok        float64 `toml:"output_per_mtok"`
	CacheCreationPerMTok float64 `toml:"cache_creation_per_mtok"`
	CacheReadPerMTok     float64 `toml:"cache_read_per_mtok"`
}

type Table struct {
	Models map[string]ModelPrice `toml:"models"`
}

func Load(path string) (Table, error) {
	var t Table
	if _, err := toml.DecodeFile(path, &t); err != nil {
		return Table{}, fmt.Errorf("load pricing: %w", err)
	}
	if t.Models == nil {
		t.Models = map[string]ModelPrice{}
	}
	return t, nil
}

func (t Table) Cost(model string, u Usage) float64 {
	p, ok := t.Models[model]
	if !ok {
		return 0
	}
	const m = 1_000_000.0
	return float64(u.InputTokens)/m*p.InputPerMTok +
		float64(u.OutputTokens)/m*p.OutputPerMTok +
		float64(u.CacheCreationInputTokens)/m*p.CacheCreationPerMTok +
		float64(u.CacheReadInputTokens)/m*p.CacheReadPerMTok
}

func (t Table) Has(model string) bool {
	_, ok := t.Models[model]
	return ok
}
```

- [ ] **Step 4: Run the test, confirm it passes**

Run: `go test ./internal/pricing/... -v`
Expected: PASS for `TestLoadAndCost`, `TestLoadMissingFile`.

- [ ] **Step 5: Commit**

```bash
git add internal/pricing/
git commit -m "feat(pricing): load pricing.toml and compute per-usage cost"
```

---

## Task 3: pricing — baked-in Defaults()

**Files:**
- Create: `internal/pricing/defaults.go`
- Modify: `internal/pricing/pricing_test.go`

- [ ] **Step 1: Add failing test**

Append to `internal/pricing/pricing_test.go`:
```go
func TestDefaultsCoversMajorModels(t *testing.T) {
	d := Defaults()
	for _, m := range []string{"claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"} {
		if !d.Has(m) {
			t.Errorf("Defaults() missing %s", m)
		}
	}
	if DefaultsDate == "" {
		t.Error("DefaultsDate must be set")
	}
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `go test ./internal/pricing/... -run Defaults`
Expected: FAIL — `Defaults`, `DefaultsDate` undefined.

- [ ] **Step 3: Implement defaults.go**

Create `internal/pricing/defaults.go`:
```go
package pricing

// DefaultsDate is the ISO date the baked-in prices were captured.
// Update when bumping prices.
const DefaultsDate = "2026-04-24"

// Defaults returns a best-effort price table used when no pricing.toml
// is available and live fetch also fails.
// Prices in USD per 1M tokens.
func Defaults() Table {
	return Table{
		Models: map[string]ModelPrice{
			"claude-opus-4-7": {
				InputPerMTok: 15.00, OutputPerMTok: 75.00,
				CacheCreationPerMTok: 18.75, CacheReadPerMTok: 1.50,
			},
			"claude-sonnet-4-6": {
				InputPerMTok: 3.00, OutputPerMTok: 15.00,
				CacheCreationPerMTok: 3.75, CacheReadPerMTok: 0.30,
			},
			"claude-haiku-4-5": {
				InputPerMTok: 1.00, OutputPerMTok: 5.00,
				CacheCreationPerMTok: 1.25, CacheReadPerMTok: 0.10,
			},
		},
	}
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `go test ./internal/pricing/... -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/pricing/defaults.go internal/pricing/pricing_test.go
git commit -m "feat(pricing): baked-in defaults table for major models"
```

---

## Task 4: pricing — Fetch + parsePricingHTML (TDD with fixture)

**Files:**
- Create: `internal/pricing/fetch.go`
- Create: `internal/pricing/fetch_test.go`
- Create: `internal/pricing/testdata/pricing-page.html`

- [ ] **Step 1: Capture a fixture**

Download the current Anthropic pricing HTML page to the testdata dir. For the spike, a minimal synthetic HTML that exercises the parser is acceptable if live capture fails. Create `internal/pricing/testdata/pricing-page.html`:
```html
<!doctype html>
<html><body>
<table class="pricing-table">
  <tr data-model="claude-opus-4-7">
    <td class="input">$15.00</td>
    <td class="output">$75.00</td>
    <td class="cache-write">$18.75</td>
    <td class="cache-read">$1.50</td>
  </tr>
  <tr data-model="claude-sonnet-4-6">
    <td class="input">$3.00</td>
    <td class="output">$15.00</td>
    <td class="cache-write">$3.75</td>
    <td class="cache-read">$0.30</td>
  </tr>
</table>
</body></html>
```

Note: during implementation, replace this synthetic fixture with a real captured snapshot from the live pricing page, and adjust the parser selectors to match.

- [ ] **Step 2: Write failing test**

Create `internal/pricing/fetch_test.go`:
```go
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
```

- [ ] **Step 3: Run, confirm fail**

Run: `go test ./internal/pricing/... -run Parse`
Expected: FAIL — `parsePricingHTML` undefined.

- [ ] **Step 4: Implement fetch.go**

Create `internal/pricing/fetch.go`:
```go
package pricing

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/PuerkitoBio/goquery"
)

const pricingURL = "https://docs.anthropic.com/en/docs/about-claude/pricing"

// Fetch retrieves pricing from the Anthropic docs and parses it into a Table.
func Fetch(ctx context.Context) (Table, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, pricingURL, nil)
	if err != nil {
		return Table{}, err
	}
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return Table{}, fmt.Errorf("fetch pricing: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return Table{}, fmt.Errorf("fetch pricing: status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return Table{}, err
	}
	return parsePricingHTML(body)
}

// parsePricingHTML extracts a pricing Table from an HTML document.
// Selectors are pinned to the synthetic fixture schema; adjust once
// the real page is captured.
func parsePricingHTML(body []byte) (Table, error) {
	doc, err := goquery.NewDocumentFromReader(bytes.NewReader(body))
	if err != nil {
		return Table{}, err
	}
	out := Table{Models: map[string]ModelPrice{}}
	doc.Find("tr[data-model]").Each(func(_ int, s *goquery.Selection) {
		model, _ := s.Attr("data-model")
		if model == "" {
			return
		}
		parse := func(sel string) float64 {
			txt := strings.TrimSpace(s.Find(sel).First().Text())
			txt = strings.TrimPrefix(txt, "$")
			txt = strings.ReplaceAll(txt, ",", "")
			f, _ := strconv.ParseFloat(txt, 64)
			return f
		}
		out.Models[model] = ModelPrice{
			InputPerMTok:         parse("td.input"),
			OutputPerMTok:        parse("td.output"),
			CacheCreationPerMTok: parse("td.cache-write"),
			CacheReadPerMTok:     parse("td.cache-read"),
		}
	})
	if len(out.Models) == 0 {
		return Table{}, fmt.Errorf("no models found in pricing HTML")
	}
	return out, nil
}

// SaveTOML writes a Table to disk as pricing.toml.
func SaveTOML(t Table, path string) error {
	var buf bytes.Buffer
	buf.WriteString("# Auto-generated by claudecounter. Fetched: " +
		time.Now().UTC().Format(time.RFC3339) + "\n\n")
	for name, p := range t.Models {
		fmt.Fprintf(&buf, "[models.%q]\n", name)
		fmt.Fprintf(&buf, "input_per_mtok = %g\n", p.InputPerMTok)
		fmt.Fprintf(&buf, "output_per_mtok = %g\n", p.OutputPerMTok)
		fmt.Fprintf(&buf, "cache_creation_per_mtok = %g\n", p.CacheCreationPerMTok)
		fmt.Fprintf(&buf, "cache_read_per_mtok = %g\n\n", p.CacheReadPerMTok)
	}
	return writeFileAtomic(path, buf.Bytes())
}

func writeFileAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
```

Add import `"os"` to `fetch.go`.

- [ ] **Step 5: Run, confirm pass**

Run: `go test ./internal/pricing/... -v`
Expected: all tests PASS, including `TestParsePricingHTML`.

- [ ] **Step 6: Commit**

```bash
git add internal/pricing/fetch.go internal/pricing/fetch_test.go internal/pricing/testdata/
git commit -m "feat(pricing): http fetch + HTML parse with fixture test"
```

---

## Task 5: reader — Event type + parseLine (TDD)

**Files:**
- Create: `internal/reader/reader.go`
- Create: `internal/reader/reader_test.go`
- Create: `internal/reader/testdata/session_normal.jsonl`
- Create: `internal/reader/testdata/session_malformed.jsonl`

- [ ] **Step 1: Create JSONL fixtures**

Create `internal/reader/testdata/session_normal.jsonl`:
```
{"type":"permission-mode","permissionMode":"default","sessionId":"s1"}
{"type":"user","message":{"role":"user","content":"hi"},"sessionId":"s1","cwd":"/tmp/x","timestamp":"2026-04-24T14:00:00Z"}
{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"sessionId":"s1","cwd":"/tmp/x","timestamp":"2026-04-24T14:00:01Z"}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":100,"cache_read_input_tokens":50}},"sessionId":"s1","cwd":"/tmp/x","timestamp":"2026-04-24T14:00:02Z"}
```

Create `internal/reader/testdata/session_malformed.jsonl`:
```
{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T14:00:03Z","sessionId":"s2","cwd":"/tmp/y"}
{this is not json
{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T14:00:04Z","sessionId":"s2","cwd":"/tmp/y"}
```

- [ ] **Step 2: Write failing test**

Create `internal/reader/reader_test.go`:
```go
package reader

import (
	"testing"
	"time"
)

func TestParseLine_Assistant(t *testing.T) {
	line := []byte(`{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}},"sessionId":"s1","cwd":"/tmp/x","timestamp":"2026-04-24T14:00:01Z"}`)
	ev, ok, err := parseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("expected event")
	}
	if ev.Model != "claude-opus-4-7" {
		t.Errorf("model: %q", ev.Model)
	}
	if ev.Usage.InputTokens != 10 || ev.Usage.OutputTokens != 20 ||
		ev.Usage.CacheCreationInputTokens != 30 || ev.Usage.CacheReadInputTokens != 40 {
		t.Errorf("usage: %+v", ev.Usage)
	}
	if ev.SessionID != "s1" || ev.Cwd != "/tmp/x" {
		t.Errorf("ids: %+v", ev)
	}
	want, _ := time.Parse(time.RFC3339, "2026-04-24T14:00:01Z")
	if !ev.Timestamp.Equal(want) {
		t.Errorf("ts: %v", ev.Timestamp)
	}
}

func TestParseLine_SkipsNonAssistant(t *testing.T) {
	for _, l := range []string{
		`{"type":"user","message":{"content":"x"}}`,
		`{"type":"permission-mode"}`,
		`{"type":"assistant","message":{"model":"x"}}`, // no usage
	} {
		_, ok, err := parseLine([]byte(l))
		if err != nil {
			t.Fatalf("%s: %v", l, err)
		}
		if ok {
			t.Errorf("%s: expected skip", l)
		}
	}
}

func TestParseLine_Malformed(t *testing.T) {
	_, _, err := parseLine([]byte(`{not json`))
	if err == nil {
		t.Fatal("expected parse error")
	}
}
```

- [ ] **Step 3: Run, confirm fail**

Run: `go test ./internal/reader/...`
Expected: FAIL — build errors.

- [ ] **Step 4: Implement reader.go (types + parseLine only)**

Create `internal/reader/reader.go`:
```go
package reader

import (
	"encoding/json"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/pricing"
)

type Event struct {
	Timestamp time.Time
	SessionID string
	Cwd       string
	Model     string
	Usage     pricing.Usage
}

// rawLine mirrors only the fields we read from a JSONL event.
type rawLine struct {
	Type      string    `json:"type"`
	Timestamp time.Time `json:"timestamp"`
	SessionID string    `json:"sessionId"`
	Cwd       string    `json:"cwd"`
	Message   *struct {
		Model string `json:"model"`
		Usage *struct {
			InputTokens              uint64 `json:"input_tokens"`
			OutputTokens             uint64 `json:"output_tokens"`
			CacheCreationInputTokens uint64 `json:"cache_creation_input_tokens"`
			CacheReadInputTokens     uint64 `json:"cache_read_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

// parseLine returns (event, ok, err). ok=false means the line is valid JSON
// but not an assistant-usage event (skip it silently). err != nil means
// the line is not valid JSON at all.
func parseLine(line []byte) (Event, bool, error) {
	var r rawLine
	if err := json.Unmarshal(line, &r); err != nil {
		return Event{}, false, err
	}
	if r.Type != "assistant" || r.Message == nil || r.Message.Usage == nil {
		return Event{}, false, nil
	}
	u := r.Message.Usage
	return Event{
		Timestamp: r.Timestamp,
		SessionID: r.SessionID,
		Cwd:       r.Cwd,
		Model:     r.Message.Model,
		Usage: pricing.Usage{
			InputTokens:              u.InputTokens,
			OutputTokens:             u.OutputTokens,
			CacheCreationInputTokens: u.CacheCreationInputTokens,
			CacheReadInputTokens:     u.CacheReadInputTokens,
		},
	}, true, nil
}
```

- [ ] **Step 5: Run, confirm pass**

Run: `go test ./internal/reader/... -v -run ParseLine`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/reader/
git commit -m "feat(reader): parseLine extracts assistant usage events from jsonl"
```

---

## Task 6: reader — Reader struct with OnChange (offset + partial-line safety) (TDD)

**Files:**
- Modify: `internal/reader/reader.go`
- Modify: `internal/reader/reader_test.go`

- [ ] **Step 1: Write failing test**

Append to `internal/reader/reader_test.go`:
```go
import (
	"os"
	"path/filepath"
)

func TestOnChange_ReadsAppendedLinesOnly(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.jsonl")

	first := `{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"}` + "\n"
	if err := os.WriteFile(path, []byte(first), 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 8)
	r := New(ch)
	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ch:
	default:
		t.Fatal("expected event after first OnChange")
	}

	second := `{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:01Z","sessionId":"s","cwd":"/x"}` + "\n"
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(second)
	f.Close()

	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-ch:
		if ev.Model != "claude-sonnet-4-6" {
			t.Fatalf("expected sonnet, got %q", ev.Model)
		}
	default:
		t.Fatal("expected event after append")
	}
	select {
	case ev := <-ch:
		t.Fatalf("unexpected extra event: %+v", ev)
	default:
	}
}

func TestOnChange_PartialLineNotAdvanced(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.jsonl")

	// Write a partial line (no trailing \n).
	partial := `{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":9,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"`
	os.WriteFile(path, []byte(partial), 0o644)

	ch := make(chan Event, 4)
	r := New(ch)
	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-ch:
		t.Fatalf("no event expected on partial line: %+v", ev)
	default:
	}

	// Append closing brace + newline.
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString("}\n")
	f.Close()

	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-ch:
		if ev.Usage.InputTokens != 9 {
			t.Fatalf("wrong event: %+v", ev)
		}
	default:
		t.Fatal("expected event once line completes")
	}
}

func TestOnChange_MalformedLineAdvancesButIsSkipped(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.jsonl")
	body := "{bad line\n" +
		`{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":7,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"}` + "\n"
	os.WriteFile(path, []byte(body), 0o644)

	ch := make(chan Event, 4)
	r := New(ch)
	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	got := <-ch
	if got.Usage.InputTokens != 7 {
		t.Fatalf("expected second line to be delivered: %+v", got)
	}
	if r.ParseErrors() != 1 {
		t.Fatalf("want 1 parse error, got %d", r.ParseErrors())
	}
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `go test ./internal/reader/... -v -run OnChange`
Expected: FAIL — `New`, `OnChange`, `ParseErrors` undefined.

- [ ] **Step 3: Implement Reader**

Append to `internal/reader/reader.go`:
```go
import (
	"bytes"
	"io"
	"os"
	"sync"
)

type Reader struct {
	mu          sync.Mutex
	offsets     map[string]int64
	parseErrors int
	out         chan<- Event
}

func New(out chan<- Event) *Reader {
	return &Reader{offsets: map[string]int64{}, out: out}
}

func (r *Reader) ParseErrors() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.parseErrors
}

// Forget drops a file from the offset map (used on Remove events).
func (r *Reader) Forget(path string) {
	r.mu.Lock()
	delete(r.offsets, path)
	r.mu.Unlock()
}

// OnChange reads any new complete lines in path starting from the
// previously-recorded offset, emits Events, and updates the offset.
// It never advances past an incomplete (non-\n-terminated) tail.
func (r *Reader) OnChange(path string) error {
	r.mu.Lock()
	start := r.offsets[path]
	r.mu.Unlock()

	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			r.Forget(path)
			return nil
		}
		return err
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return err
	}
	// File shrank (shouldn't happen in normal operation) — rewind.
	if stat.Size() < start {
		start = 0
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return err
	}

	data, err := io.ReadAll(f)
	if err != nil {
		return err
	}

	// Split on '\n'. A trailing non-empty tail without '\n' is a partial
	// line; leave it unconsumed so we retry on the next change.
	consumed := 0
	for {
		idx := bytes.IndexByte(data[consumed:], '\n')
		if idx < 0 {
			break
		}
		line := data[consumed : consumed+idx]
		consumed += idx + 1
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		ev, ok, perr := parseLine(line)
		if perr != nil {
			r.mu.Lock()
			r.parseErrors++
			r.mu.Unlock()
			continue
		}
		if ok {
			r.out <- ev
		}
	}

	r.mu.Lock()
	r.offsets[path] = start + int64(consumed)
	r.mu.Unlock()
	return nil
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `go test ./internal/reader/... -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/reader/
git commit -m "feat(reader): OnChange with offset tracking and partial-line safety"
```

---

## Task 7: reader — InitialScan with mtime cutoff (TDD)

**Files:**
- Modify: `internal/reader/reader.go`
- Modify: `internal/reader/reader_test.go`

- [ ] **Step 1: Write failing test**

Append to `internal/reader/reader_test.go`:
```go
func TestInitialScan_SkipsFilesOlderThanNotBefore(t *testing.T) {
	root := t.TempDir()
	projA := filepath.Join(root, "projA")
	projB := filepath.Join(root, "projB")
	os.MkdirAll(projA, 0o755)
	os.MkdirAll(projB, 0o755)

	old := filepath.Join(projA, "old.jsonl")
	cur := filepath.Join(projB, "cur.jsonl")
	line := `{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"}` + "\n"
	os.WriteFile(old, []byte(line), 0o644)
	os.WriteFile(cur, []byte(line), 0o644)

	// Backdate projA/old to 60 days ago.
	sixtyDaysAgo := time.Now().Add(-60 * 24 * time.Hour)
	os.Chtimes(old, sixtyDaysAgo, sixtyDaysAgo)

	ch := make(chan Event, 8)
	r := New(ch)

	notBefore := time.Now().Add(-30 * 24 * time.Hour)
	if err := r.InitialScan(root, notBefore); err != nil {
		t.Fatal(err)
	}
	close(ch)
	var events []Event
	for e := range ch {
		events = append(events, e)
	}
	if len(events) != 1 {
		t.Fatalf("want 1 event (from projB), got %d", len(events))
	}
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `go test ./internal/reader/... -run InitialScan`
Expected: FAIL — `InitialScan` undefined.

- [ ] **Step 3: Implement InitialScan**

Append to `internal/reader/reader.go`:
```go
import "path/filepath"

// InitialScan walks root/<project>/*.jsonl and reads every file whose
// mtime is at or after notBefore. After this returns, the reader's
// offset map reflects the end of every scanned file.
func (r *Reader) InitialScan(root string, notBefore time.Time) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		subdir := filepath.Join(root, e.Name())
		files, err := os.ReadDir(subdir)
		if err != nil {
			continue
		}
		for _, f := range files {
			if f.IsDir() || filepath.Ext(f.Name()) != ".jsonl" {
				continue
			}
			path := filepath.Join(subdir, f.Name())
			info, err := f.Info()
			if err != nil {
				continue
			}
			if info.ModTime().Before(notBefore) {
				continue
			}
			if err := r.OnChange(path); err != nil {
				continue
			}
		}
	}
	return nil
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `go test ./internal/reader/... -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/reader/
git commit -m "feat(reader): InitialScan walks projects, honoring mtime cutoff"
```

---

## Task 8: agg — Aggregator with civilDay bucketing (TDD)

**Files:**
- Create: `internal/agg/agg.go`
- Create: `internal/agg/agg_test.go`

- [ ] **Step 1: Write failing test**

Create `internal/agg/agg_test.go`:
```go
package agg

import (
	"testing"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/pricing"
	"github.com/jjverhoeks/claudecounter/internal/reader"
)

func priced() pricing.Table {
	return pricing.Table{Models: map[string]pricing.ModelPrice{
		"claude-opus-4-7":  {InputPerMTok: 15, OutputPerMTok: 75},
		"claude-sonnet-4-6": {InputPerMTok: 3, OutputPerMTok: 15},
	}}
}

func mkEvent(ts string, model string, inTok, outTok uint64) reader.Event {
	t, _ := time.Parse(time.RFC3339, ts)
	return reader.Event{
		Timestamp: t,
		Model:     model,
		Usage:     pricing.Usage{InputTokens: inTok, OutputTokens: outTok},
	}
}

func TestApplyAndSnapshot_TodayAndMonth(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	// Today: 1M input on opus = $15.
	a.Apply(mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 1_000_000, 0))
	// Yesterday: 1M output on sonnet = $15. Same month, different day.
	a.Apply(mkEvent(now.Add(-24*time.Hour).UTC().Format(time.RFC3339),
		"claude-sonnet-4-6", 0, 1_000_000))

	snap := a.Snapshot()
	if got := snap.Day["claude-opus-4-7"].USD; got != 15 {
		t.Errorf("today opus USD: %v", got)
	}
	if _, ok := snap.Day["claude-sonnet-4-6"]; ok {
		t.Error("today should not include sonnet event from yesterday")
	}
	if got := snap.Month["claude-opus-4-7"].USD; got != 15 {
		t.Errorf("month opus USD: %v", got)
	}
	if got := snap.Month["claude-sonnet-4-6"].USD; got != 15 {
		t.Errorf("month sonnet USD: %v", got)
	}
}

func TestApply_UnknownModelCounted(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })
	a.Apply(mkEvent(now.UTC().Format(time.RFC3339), "claude-foo-x", 100, 100))
	snap := a.Snapshot()
	if snap.Unknown != 1 {
		t.Errorf("unknown count: %d", snap.Unknown)
	}
	if _, ok := snap.Day["claude-foo-x"]; !ok {
		t.Error("unknown model still needs token accounting")
	}
	if snap.Day["claude-foo-x"].USD != 0 {
		t.Error("unknown model cost must be 0")
	}
}

func TestSnapshot_ExcludesPreviousMonth(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })
	// 10 days before month start — last month.
	prev := time.Date(2026, 3, 21, 15, 0, 0, 0, time.Local)
	a.Apply(mkEvent(prev.UTC().Format(time.RFC3339), "claude-opus-4-7", 1_000_000, 0))

	snap := a.Snapshot()
	if _, ok := snap.Month["claude-opus-4-7"]; ok {
		t.Error("last month's event must not appear in this-month snapshot")
	}
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `go test ./internal/agg/...`
Expected: FAIL — build errors.

- [ ] **Step 3: Implement agg.go**

Create `internal/agg/agg.go`:
```go
package agg

import (
	"sync"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/pricing"
	"github.com/jjverhoeks/claudecounter/internal/reader"
)

type TokenCounts struct {
	In, Out, CacheCreate, CacheRead uint64
}

type ModelDay struct {
	USD    float64
	Tokens TokenCounts
}

type Totals struct {
	Day     map[string]ModelDay
	Month   map[string]ModelDay
	Unknown int
	AsOf    time.Time
}

type civilDay struct {
	Y int
	M time.Month
	D int
}

func dayOf(t time.Time) civilDay {
	lt := t.Local()
	return civilDay{lt.Year(), lt.Month(), lt.Day()}
}

type Aggregator struct {
	mu      sync.Mutex
	pricing pricing.Table
	byDay   map[civilDay]map[string]ModelDay
	unknown int
	now     func() time.Time
}

func New(p pricing.Table) *Aggregator {
	return NewWithClock(p, time.Now)
}

func NewWithClock(p pricing.Table, now func() time.Time) *Aggregator {
	return &Aggregator{
		pricing: p,
		byDay:   map[civilDay]map[string]ModelDay{},
		now:     now,
	}
}

func (a *Aggregator) Apply(e reader.Event) {
	a.mu.Lock()
	defer a.mu.Unlock()

	day := dayOf(e.Timestamp)
	bucket, ok := a.byDay[day]
	if !ok {
		bucket = map[string]ModelDay{}
		a.byDay[day] = bucket
	}
	md := bucket[e.Model]
	md.Tokens.In += e.Usage.InputTokens
	md.Tokens.Out += e.Usage.OutputTokens
	md.Tokens.CacheCreate += e.Usage.CacheCreationInputTokens
	md.Tokens.CacheRead += e.Usage.CacheReadInputTokens

	if a.pricing.Has(e.Model) {
		md.USD += a.pricing.Cost(e.Model, e.Usage)
	} else {
		a.unknown++
	}
	bucket[e.Model] = md
}

func (a *Aggregator) Snapshot() Totals {
	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.now().Local()
	today := civilDay{now.Year(), now.Month(), now.Day()}

	t := Totals{
		Day:     map[string]ModelDay{},
		Month:   map[string]ModelDay{},
		Unknown: a.unknown,
		AsOf:    now,
	}

	if bucket, ok := a.byDay[today]; ok {
		for m, md := range bucket {
			t.Day[m] = md
		}
	}
	for day, bucket := range a.byDay {
		if day.Y != now.Year() || day.M != now.Month() {
			continue
		}
		for m, md := range bucket {
			agg := t.Month[m]
			agg.USD += md.USD
			agg.Tokens.In += md.Tokens.In
			agg.Tokens.Out += md.Tokens.Out
			agg.Tokens.CacheCreate += md.Tokens.CacheCreate
			agg.Tokens.CacheRead += md.Tokens.CacheRead
			t.Month[m] = agg
		}
	}
	return t
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `go test ./internal/agg/... -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/agg/
git commit -m "feat(agg): civilDay-keyed aggregator with today/month snapshots"
```

---

## Task 9: watcher — fsnotify wrapper with subdir auto-add (smoke test)

**Files:**
- Create: `internal/watcher/watcher.go`
- Create: `internal/watcher/watcher_test.go`

- [ ] **Step 1: Write failing test**

Create `internal/watcher/watcher_test.go`:
```go
package watcher

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWatcher_EmitsWriteEvent(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "projA"), 0o755)

	w, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.AddTree(dir); err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(dir, "projA", "s.jsonl")
	os.WriteFile(path, []byte("hi\n"), 0o644)

	if !waitFor(w.Events(), 2*time.Second,
		func(c Change) bool { return c.Path == path }) {
		t.Fatal("expected change for new file")
	}
}

func TestWatcher_PicksUpNewSubdir(t *testing.T) {
	dir := t.TempDir()
	w, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.AddTree(dir); err != nil {
		t.Fatal(err)
	}

	newSub := filepath.Join(dir, "projNew")
	os.MkdirAll(newSub, 0o755)

	// Give the watcher a moment to register the new subdir.
	time.Sleep(200 * time.Millisecond)

	path := filepath.Join(newSub, "s.jsonl")
	os.WriteFile(path, []byte("hi\n"), 0o644)

	if !waitFor(w.Events(), 2*time.Second,
		func(c Change) bool { return c.Path == path }) {
		t.Fatal("expected change for file in newly-created subdir")
	}
}

func waitFor(ch <-chan Change, d time.Duration, pred func(Change) bool) bool {
	deadline := time.After(d)
	for {
		select {
		case c := <-ch:
			if pred(c) {
				return true
			}
		case <-deadline:
			return false
		}
	}
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `go test ./internal/watcher/...`
Expected: FAIL — build errors.

- [ ] **Step 3: Implement watcher.go**

Create `internal/watcher/watcher.go`:
```go
package watcher

import (
	"os"
	"path/filepath"

	"github.com/fsnotify/fsnotify"
)

type ChangeKind int

const (
	Create ChangeKind = iota
	Write
	Remove
)

type Change struct {
	Path string
	Kind ChangeKind
}

type Watcher struct {
	fs  *fsnotify.Watcher
	out chan Change
}

func New() (*Watcher, error) {
	fs, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	w := &Watcher{fs: fs, out: make(chan Change, 256)}
	go w.loop()
	return w, nil
}

func (w *Watcher) Events() <-chan Change { return w.out }

func (w *Watcher) Close() error { return w.fs.Close() }

// AddTree watches root itself and every existing subdirectory of root.
func (w *Watcher) AddTree(root string) error {
	if err := w.fs.Add(root); err != nil {
		return err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			_ = w.fs.Add(filepath.Join(root, e.Name()))
		}
	}
	return nil
}

func (w *Watcher) loop() {
	for {
		select {
		case ev, ok := <-w.fs.Events:
			if !ok {
				close(w.out)
				return
			}
			w.handle(ev)
		case _, ok := <-w.fs.Errors:
			if !ok {
				return
			}
			// Errors are surfaced as a synthetic re-tail of known files in
			// cmd/main, not here. Drop for now.
		}
	}
}

func (w *Watcher) handle(ev fsnotify.Event) {
	// If a new directory is created inside a watched parent, watch it.
	if ev.Op&fsnotify.Create != 0 {
		if info, err := os.Stat(ev.Name); err == nil && info.IsDir() {
			_ = w.fs.Add(ev.Name)
			return
		}
	}

	if filepath.Ext(ev.Name) != ".jsonl" {
		return
	}

	switch {
	case ev.Op&fsnotify.Create != 0:
		w.out <- Change{Path: ev.Name, Kind: Create}
	case ev.Op&fsnotify.Write != 0:
		w.out <- Change{Path: ev.Name, Kind: Write}
	case ev.Op&(fsnotify.Remove|fsnotify.Rename) != 0:
		w.out <- Change{Path: ev.Name, Kind: Remove}
	}
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `go test ./internal/watcher/... -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/watcher/
git commit -m "feat(watcher): fsnotify wrapper with subdir auto-add"
```

---

## Task 10: ui — cost formatter (TDD)

**Files:**
- Create: `internal/ui/format.go`
- Create: `internal/ui/format_test.go`

- [ ] **Step 1: Write failing test**

Create `internal/ui/format_test.go`:
```go
package ui

import "testing"

func TestFormatUSD(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0, "$0.00"},
		{0.004, "$0.00"},
		{1.2, "$1.20"},
		{132.8, "$132.80"},
		{1234.5, "$1,234.50"},
		{1_234_567.89, "$1,234,567.89"},
	}
	for _, c := range cases {
		if got := FormatUSD(c.in); got != c.want {
			t.Errorf("FormatUSD(%v) = %q want %q", c.in, got, c.want)
		}
	}
}

func TestFormatTokShort(t *testing.T) {
	cases := []struct {
		in   uint64
		want string
	}{
		{0, "0"},
		{900, "900"},
		{1000, "1.0k"},
		{1234, "1.2k"},
		{999_500, "999.5k"},
		{1_000_000, "1.0M"},
		{2_340_000, "2.3M"},
	}
	for _, c := range cases {
		if got := FormatTokShort(c.in); got != c.want {
			t.Errorf("FormatTokShort(%v) = %q want %q", c.in, got, c.want)
		}
	}
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `go test ./internal/ui/...`
Expected: FAIL — build errors.

- [ ] **Step 3: Implement format.go**

Create `internal/ui/format.go`:
```go
package ui

import (
	"fmt"
	"strings"
)

// FormatUSD renders a dollar value like "$1,234.56".
func FormatUSD(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	whole := int64(v)
	cents := int64((v-float64(whole))*100 + 0.5)
	if cents == 100 {
		whole++
		cents = 0
	}
	s := fmt.Sprintf("%d", whole)
	// Insert commas every 3 digits from the right.
	var b strings.Builder
	n := len(s)
	for i, r := range s {
		if i > 0 && (n-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}
	sign := ""
	if neg {
		sign = "-"
	}
	return fmt.Sprintf("%s$%s.%02d", sign, b.String(), cents)
}

// FormatTokShort renders token counts as "900", "1.2k", "2.3M".
func FormatTokShort(n uint64) string {
	switch {
	case n < 1000:
		return fmt.Sprintf("%d", n)
	case n < 1_000_000:
		return fmt.Sprintf("%.1fk", float64(n)/1000.0)
	default:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000.0)
	}
}
```

- [ ] **Step 4: Run, confirm pass**

Run: `go test ./internal/ui/... -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/ui/format.go internal/ui/format_test.go
git commit -m "feat(ui): currency + short token formatters"
```

---

## Task 11: ui — Bubble Tea model skeleton with view routing

**Files:**
- Create: `internal/ui/model.go`

- [ ] **Step 1: Implement model + view routing + minimal view placeholder**

Create `internal/ui/model.go`:
```go
package ui

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/jjverhoeks/claudecounter/internal/agg"
)

type ViewMode int

const (
	ModeMinimal ViewMode = iota
	ModeSplit
	ModeFull
)

// SnapshotMsg is pushed by the app goroutine whenever totals change.
type SnapshotMsg struct {
	Totals      agg.Totals
	ParseErrors int
	PricingWarn string // empty unless built-in defaults are in use
}

// RecentEventMsg is pushed for the live-tail in ModeFull.
type RecentEventMsg struct {
	Tag   string // short label (project, model, cost)
	Line  string // pre-formatted line for the feed
}

const recentCap = 20

type Model struct {
	mode         ViewMode
	totals       agg.Totals
	recent       []string
	warns        []string
	parseErrors  int
	pricingWarn  string
	width        int
	height       int
}

func NewModel() Model { return Model{mode: ModeSplit} }

func (m Model) Init() tea.Cmd { return nil }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "1":
			m.mode = ModeMinimal
		case "2":
			m.mode = ModeSplit
		case "3":
			m.mode = ModeFull
		case "tab":
			m.mode = (m.mode + 1) % 3
		}
	case SnapshotMsg:
		m.totals = msg.Totals
		m.parseErrors = msg.ParseErrors
		m.pricingWarn = msg.PricingWarn
		m.warns = collectWarns(msg)
	case RecentEventMsg:
		m.recent = append(m.recent, msg.Line)
		if len(m.recent) > recentCap {
			m.recent = m.recent[len(m.recent)-recentCap:]
		}
	}
	return m, nil
}

func (m Model) View() string {
	var body string
	switch m.mode {
	case ModeMinimal:
		body = viewMinimal(m.totals)
	case ModeSplit:
		body = viewSplit(m.totals)
	case ModeFull:
		body = viewFull(m.totals, m.recent)
	}
	footer := "1/2/3 or Tab: switch view   q: quit"
	for _, w := range m.warns {
		footer = w + "\n" + footer
	}
	return body + "\n" + footer + "\n"
}

func collectWarns(s SnapshotMsg) []string {
	var out []string
	if s.PricingWarn != "" {
		out = append(out, s.PricingWarn)
	}
	if s.Totals.Unknown > 0 {
		out = append(out, fmt.Sprintf("⚠ %d events with unpriced models", s.Totals.Unknown))
	}
	if s.ParseErrors > 0 {
		out = append(out, fmt.Sprintf("⚠ %d parse errors", s.ParseErrors))
	}
	return out
}
```

- [ ] **Step 2: Verify build**

Run: `go build ./internal/ui/...`
Expected: build errors — `viewMinimal`, `viewSplit`, `viewFull` not yet defined. That's expected; the next three tasks define them.

- [ ] **Step 3: Commit (leave broken build — next tasks fix it)**

No commit yet; move to Task 12. The build is intentionally broken until views are implemented.

---

## Task 12: ui — minimal view

**Files:**
- Create: `internal/ui/view_minimal.go`

- [ ] **Step 1: Implement**

Create `internal/ui/view_minimal.go`:
```go
package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/jjverhoeks/claudecounter/internal/agg"
)

var (
	styleMoney = lipgloss.NewStyle().Foreground(lipgloss.Color("10")).Bold(true)
	styleDim   = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	styleHead  = lipgloss.NewStyle().Foreground(lipgloss.Color("12")).Bold(true)
)

func sumUSD(m map[string]agg.ModelDay) float64 {
	var s float64
	for _, v := range m {
		s += v.USD
	}
	return s
}

// shortModel returns a compact model id, e.g. "Opus" or "Sonnet".
func shortModel(id string) string {
	switch {
	case strings.Contains(id, "opus"):
		return "Opus"
	case strings.Contains(id, "sonnet"):
		return "Sonnet"
	case strings.Contains(id, "haiku"):
		return "Haiku"
	default:
		return id
	}
}

func viewMinimal(t agg.Totals) string {
	var b strings.Builder
	b.WriteString(styleHead.Render("Today") + "     " + styleMoney.Render(FormatUSD(sumUSD(t.Day))) + "\n")
	b.WriteString(styleHead.Render("Month") + "     " + styleMoney.Render(FormatUSD(sumUSD(t.Month))) + "\n")

	// Per-model summary for Today.
	names := make([]string, 0, len(t.Day))
	for name := range t.Day {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		return t.Day[names[i]].USD > t.Day[names[j]].USD
	})
	parts := make([]string, 0, len(names))
	for _, n := range names {
		parts = append(parts, fmt.Sprintf("%s %s", shortModel(n), FormatUSD(t.Day[n].USD)))
	}
	if len(parts) > 0 {
		b.WriteString(styleDim.Render(strings.Join(parts, " · ")) + "\n")
	}
	return b.String()
}
```

- [ ] **Step 2: Build check**

Run: `go build ./internal/ui/...`
Expected: still missing `viewSplit`, `viewFull`. Continue to Task 13.

---

## Task 13: ui — split view

**Files:**
- Create: `internal/ui/view_split.go`

- [ ] **Step 1: Implement**

Create `internal/ui/view_split.go`:
```go
package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/jjverhoeks/claudecounter/internal/agg"
)

func viewSplit(t agg.Totals) string {
	var b strings.Builder
	dayTotal := sumUSD(t.Day)
	monthTotal := sumUSD(t.Month)

	b.WriteString(fmt.Sprintf("%s  %s    %s %s\n",
		styleHead.Render("Today"),
		styleMoney.Render(FormatUSD(dayTotal)),
		styleHead.Render("Month"),
		styleMoney.Render(FormatUSD(monthTotal)),
	))
	b.WriteString(styleDim.Render(strings.Repeat("─", 48)) + "\n")

	// Today breakdown (sorted by USD desc).
	names := make([]string, 0, len(t.Day))
	for name := range t.Day {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		return t.Day[names[i]].USD > t.Day[names[j]].USD
	})
	for _, n := range names {
		md := t.Day[n]
		pct := 0.0
		if dayTotal > 0 {
			pct = md.USD / dayTotal * 100
		}
		line := fmt.Sprintf("  %-14s %9s  %4.0f%%\n", shortModel(n), FormatUSD(md.USD), pct)
		if pct < 10 {
			line = styleDim.Render(line)
		}
		b.WriteString(line)
	}
	return b.String()
}
```

- [ ] **Step 2: Build check**

Run: `go build ./internal/ui/...`
Expected: still missing `viewFull`. Continue.

---

## Task 14: ui — full view with live tail

**Files:**
- Create: `internal/ui/view_full.go`

- [ ] **Step 1: Implement**

Create `internal/ui/view_full.go`:
```go
package ui

import (
	"strings"

	"github.com/jjverhoeks/claudecounter/internal/agg"
)

func viewFull(t agg.Totals, recent []string) string {
	var b strings.Builder
	b.WriteString(viewSplit(t))
	b.WriteString(styleDim.Render(strings.Repeat("─", 48)) + "\n")
	b.WriteString(styleHead.Render("Live") + "\n")
	if len(recent) == 0 {
		b.WriteString(styleDim.Render("  (waiting for events…)") + "\n")
		return b.String()
	}
	for _, line := range recent {
		b.WriteString("  " + line + "\n")
	}
	return b.String()
}
```

- [ ] **Step 2: Build check**

Run: `go build ./internal/ui/...`
Expected: success, no unresolved references.

- [ ] **Step 3: Commit all three view files + model**

```bash
git add internal/ui/
git commit -m "feat(ui): bubbletea model with minimal/split/full view modes"
```

---

## Task 15: cmd wiring — main.go startup + event pipeline

**Files:**
- Create: `cmd/claudecounter/main.go`

- [ ] **Step 1: Implement main.go**

Create `cmd/claudecounter/main.go`:
```go
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/jjverhoeks/claudecounter/internal/agg"
	"github.com/jjverhoeks/claudecounter/internal/pricing"
	"github.com/jjverhoeks/claudecounter/internal/reader"
	"github.com/jjverhoeks/claudecounter/internal/ui"
	"github.com/jjverhoeks/claudecounter/internal/watcher"
)

func defaultPricingPath() string {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "claudecounter", "pricing.toml")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "claudecounter", "pricing.toml")
}

func defaultRoot() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "projects")
}

func main() {
	pricingPath := flag.String("pricing", defaultPricingPath(), "path to pricing.toml")
	root := flag.String("root", defaultRoot(), "claude projects root")
	refresh := flag.Bool("refresh-pricing", false, "fetch pricing from the web and overwrite pricing.toml")
	flag.Parse()

	if _, err := os.Stat(*root); err != nil {
		log.Fatalf("claude projects root not found: %s (%v)", *root, err)
	}

	table, pricingWarn := loadPricing(*pricingPath, *refresh)

	evCh := make(chan reader.Event, 256)
	r := reader.New(evCh)

	notBefore := firstOfMonth(time.Now().Local())
	if err := r.InitialScan(*root, notBefore); err != nil {
		log.Fatalf("initial scan: %v", err)
	}

	w, err := watcher.New()
	if err != nil {
		log.Fatalf("watcher: %v", err)
	}
	defer w.Close()
	if err := w.AddTree(*root); err != nil {
		log.Fatalf("watcher add: %v", err)
	}

	a := agg.New(table)
	// Drain any events already produced by InitialScan.
	drained := drainEvents(evCh)
	for _, e := range drained {
		a.Apply(e)
	}

	m := ui.NewModel()
	prog := tea.NewProgram(m, tea.WithAltScreen())

	go pipeline(w, r, a, evCh, prog, table, pricingWarn)

	// Send an initial snapshot so the UI renders real numbers immediately.
	prog.Send(ui.SnapshotMsg{
		Totals:      a.Snapshot(),
		ParseErrors: r.ParseErrors(),
		PricingWarn: pricingWarn,
	})

	if _, err := prog.Run(); err != nil {
		log.Fatal(err)
	}
}

func firstOfMonth(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, t.Location())
}

func drainEvents(ch chan reader.Event) []reader.Event {
	var out []reader.Event
	for {
		select {
		case e := <-ch:
			out = append(out, e)
		default:
			return out
		}
	}
}

func pipeline(w *watcher.Watcher, r *reader.Reader, a *agg.Aggregator,
	evCh chan reader.Event, prog *tea.Program, table pricing.Table, pricingWarn string) {

	debounce := time.NewTimer(time.Hour)
	debounce.Stop()
	dirty := false

	flush := func() {
		if !dirty {
			return
		}
		prog.Send(ui.SnapshotMsg{
			Totals:      a.Snapshot(),
			ParseErrors: r.ParseErrors(),
			PricingWarn: pricingWarn,
		})
		dirty = false
	}

	for {
		select {
		case c, ok := <-w.Events():
			if !ok {
				return
			}
			switch c.Kind {
			case watcher.Create, watcher.Write:
				_ = r.OnChange(c.Path)
			case watcher.Remove:
				r.Forget(c.Path)
			}
		case e := <-evCh:
			a.Apply(e)
			cost := table.Cost(e.Model, e.Usage)
			prog.Send(ui.RecentEventMsg{
				Line: fmt.Sprintf("%s  %-12s %-8s %s",
					e.Timestamp.Local().Format("15:04:05"),
					filepath.Base(e.Cwd),
					shortModelTag(e.Model),
					ui.FormatUSD(cost),
				),
			})
			dirty = true
			debounce.Reset(50 * time.Millisecond)
		case <-debounce.C:
			flush()
		}
	}
}

func shortModelTag(id string) string {
	switch {
	case contains(id, "opus"):
		return "opus"
	case contains(id, "sonnet"):
		return "sonnet"
	case contains(id, "haiku"):
		return "haiku"
	}
	return id
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// loadPricing resolves the price table in order: refresh flag > load file > fetch > defaults.
// Returns the table plus a user-facing warning (empty if all is well).
func loadPricing(path string, refresh bool) (pricing.Table, string) {
	if !refresh {
		if t, err := pricing.Load(path); err == nil && len(t.Models) > 0 {
			return t, ""
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	t, err := pricing.Fetch(ctx)
	if err == nil && len(t.Models) > 0 {
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		_ = pricing.SaveTOML(t, path)
		return t, ""
	}
	return pricing.Defaults(),
		fmt.Sprintf("⚠ pricing: using built-in defaults from %s", pricing.DefaultsDate)
}
```

- [ ] **Step 2: Build**

Run: `go build ./cmd/claudecounter/`
Expected: success, produces `./claudecounter` binary.

- [ ] **Step 3: Smoke test**

Run: `./claudecounter`
Expected: alt-screen TUI opens; headline shows today's and this-month's numbers (possibly $0.00 if no activity today). `Tab` cycles views. `q` quits.

- [ ] **Step 4: Commit**

```bash
git add cmd/claudecounter/main.go
git commit -m "feat(cmd): wire watcher → reader → aggregator → bubbletea"
```

---

## Task 16: integration test (end-to-end wiring)

**Files:**
- Create: `cmd/claudecounter/integration_test.go`

- [ ] **Step 1: Write the test**

Create `cmd/claudecounter/integration_test.go`:
```go
package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/agg"
	"github.com/jjverhoeks/claudecounter/internal/pricing"
	"github.com/jjverhoeks/claudecounter/internal/reader"
	"github.com/jjverhoeks/claudecounter/internal/watcher"
)

func TestEndToEnd_NewFileAndAppend(t *testing.T) {
	root := t.TempDir()
	projOld := filepath.Join(root, "old")
	projCur := filepath.Join(root, "cur")
	os.MkdirAll(projOld, 0o755)
	os.MkdirAll(projCur, 0o755)

	now := time.Now()
	nowRFC := now.UTC().Format(time.RFC3339)
	oldRFC := now.AddDate(0, -2, 0).UTC().Format(time.RFC3339)

	oldFile := filepath.Join(projOld, "a.jsonl")
	curFile := filepath.Join(projCur, "b.jsonl")
	lineOpus := func(ts string) string {
		return `{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"` + ts + `","sessionId":"s","cwd":"/x"}` + "\n"
	}
	os.WriteFile(oldFile, []byte(lineOpus(oldRFC)), 0o644)
	os.Chtimes(oldFile, now.AddDate(0, -2, 0), now.AddDate(0, -2, 0))
	os.WriteFile(curFile, []byte(lineOpus(nowRFC)), 0o644)

	table := pricing.Defaults()
	evCh := make(chan reader.Event, 64)
	r := reader.New(evCh)
	if err := r.InitialScan(root, firstOfMonth(now.Local())); err != nil {
		t.Fatal(err)
	}
	a := agg.New(table)
	for drained := true; drained; {
		select {
		case e := <-evCh:
			a.Apply(e)
		default:
			drained = false
		}
	}

	snap := a.Snapshot()
	if snap.Day["claude-opus-4-7"].USD == 0 {
		t.Fatalf("expected initial scan to count current-month opus: %+v", snap.Day)
	}
	beforeUSD := snap.Day["claude-opus-4-7"].USD

	w, err := watcher.New()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.AddTree(root); err != nil {
		t.Fatal(err)
	}

	go func() {
		for c := range w.Events() {
			if c.Kind == watcher.Remove {
				r.Forget(c.Path)
				continue
			}
			_ = r.OnChange(c.Path)
		}
	}()

	// Append to existing file.
	f, _ := os.OpenFile(curFile, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(lineOpus(nowRFC))
	f.Close()

	if !waitFor(t, 2*time.Second, func() bool {
		select {
		case e := <-evCh:
			a.Apply(e)
		default:
		}
		return a.Snapshot().Day["claude-opus-4-7"].USD > beforeUSD
	}) {
		t.Fatal("append was not picked up")
	}
	afterAppend := a.Snapshot().Day["claude-opus-4-7"].USD

	// Create a brand-new file in a new subdir.
	projNew := filepath.Join(root, "new")
	os.MkdirAll(projNew, 0o755)
	time.Sleep(200 * time.Millisecond)
	newFile := filepath.Join(projNew, "c.jsonl")
	os.WriteFile(newFile, []byte(lineOpus(nowRFC)), 0o644)

	if !waitFor(t, 2*time.Second, func() bool {
		select {
		case e := <-evCh:
			a.Apply(e)
		default:
		}
		return a.Snapshot().Day["claude-opus-4-7"].USD > afterAppend
	}) {
		t.Fatal("new file in new subdir was not picked up")
	}
}

func waitFor(t *testing.T, d time.Duration, cond func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}
```

- [ ] **Step 2: Run the test**

Run: `go test ./cmd/claudecounter/ -run EndToEnd -v`
Expected: PASS.

- [ ] **Step 3: Run the entire suite**

Run: `go test ./...`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add cmd/claudecounter/integration_test.go
git commit -m "test(cmd): e2e wiring — initial scan, append, new-subdir new-file"
```

---

## Task 17: README with build + usage

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

Create `README.md`:
```markdown
# claudecounter

Realtime cost dashboard for Claude Code. Tails `~/.claude/projects/**/*.jsonl`
and shows today's and this-month's spend, total and per-model, across three
togglable views.

## Build

```
go build ./cmd/claudecounter
```

## Run

```
./claudecounter
```

Flags:
- `--pricing <path>` — override pricing TOML location (default:
  `~/.config/claudecounter/pricing.toml`)
- `--root <path>` — override projects root (default: `~/.claude/projects`)
- `--refresh-pricing` — fetch current prices from the Anthropic docs and
  overwrite the pricing file

## Keys

- `1` / `2` / `3` — minimal / split / full view
- `Tab` — cycle views
- `q` / `Ctrl+C` — quit

## Pricing

On first run, if `pricing.toml` does not exist, claudecounter attempts to
fetch prices from `https://docs.anthropic.com/en/docs/about-claude/pricing`
and write them to disk. If the fetch fails, it falls back to a baked-in
table (dated in source) with a banner warning.

## Tests

```
go test ./...
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with build, flags, and keybindings"
```

---

## Task 18: Final verification

- [ ] **Step 1: Full test run**

Run: `go test ./...`
Expected: all PASS.

- [ ] **Step 2: Build release binary**

Run: `go build -o claudecounter ./cmd/claudecounter`
Expected: binary produced, no errors.

- [ ] **Step 3: Live smoke test**

Run: `./claudecounter`
- Confirm the TUI renders and shows real numbers reflecting recent activity.
- Press `1`, `2`, `3`, `Tab` — confirm view mode changes.
- Trigger a new Claude Code interaction in another terminal; confirm the
  numbers tick up live.
- Press `q` to quit.

- [ ] **Step 4: Tag the milestone**

```bash
git tag -a v0.1.0 -m "claudecounter TUI MVP"
```
