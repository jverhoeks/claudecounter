package reader

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

type Event struct {
	Timestamp  time.Time
	SessionID  string
	Cwd        string
	Project    string // canonical project key (encoded segment under projects/)
	Model      string
	MessageID  string // Anthropic message id
	RequestID  string // Anthropic request id; combined with MessageID for dedupe
	IsSubagent bool   // true when the event came from a subagents/agent-*.jsonl file
	Usage      pricing.Usage
	// Vendor is which tool produced this event ("claude"). It comes from
	// the configured root the file was found under, never from the model
	// name — inference already fails on real data (codex-auto-review).
	Vendor string
	// Source is the series identity "vendor/label", identifying which
	// subscription or install produced the event.
	Source string
	// CostUSD is a dollar figure the vendor reported for this event.
	// Grok emits costUsdTicks (nano-dollars) per turn and per model; that
	// is authoritative in a way our pricing table can never be, so it is
	// used as given rather than re-derived from Usage.
	CostUSD float64
	// Costed marks CostUSD as authoritative. A costed event's tokens are
	// still recorded (the token charts want them) but never priced, and
	// its model never counts toward the Unknown tally — there is no
	// pricing entry to be missing.
	Costed bool
	// CoverageOnly marks a bookkeeping event that carries no usage and
	// must not be counted as spend. Grok's `usage` object is present on
	// only a fraction of historical turns, so a Grok total over an old
	// month is a floor rather than a total. One coverage event per
	// turn_completed lets the aggregator report that fraction instead of
	// presenting an undercount as authoritative.
	CoverageOnly bool
	// HasUsage is meaningful only on a CoverageOnly event: it is the
	// numerator of that fraction.
	HasUsage bool
}

// rawLine mirrors only the fields we read from a JSONL event.
type rawLine struct {
	Type      string    `json:"type"`
	Timestamp time.Time `json:"timestamp"`
	SessionID string    `json:"sessionId"`
	Cwd       string    `json:"cwd"`
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
	} `json:"message"`
}

// parseLine returns (event, ok, err). ok=false means the line has no
// usage data we care about (skip silently). err != nil means the line
// is not valid JSON.
//
// Mirrors ccusage's filter: any line with message.usage is included,
// regardless of `type` or model name. The Claude Code JSONL only ever
// puts usage on assistant lines today, but matching ccusage's permissive
// rule keeps us aligned if that changes.
func parseLine(line []byte) (Event, bool, error) {
	var r rawLine
	if err := json.Unmarshal(line, &r); err != nil {
		return Event{}, false, err
	}
	if r.Message == nil || r.Message.Usage == nil {
		return Event{}, false, nil
	}
	if r.Message.Model == "<synthetic>" {
		// All-zero bookkeeping events; inflate "unknown" otherwise.
		return Event{}, false, nil
	}
	u := r.Message.Usage
	return Event{
		Timestamp: r.Timestamp,
		SessionID: r.SessionID,
		Cwd:       r.Cwd,
		Model:     r.Message.Model,
		MessageID: r.Message.ID,
		RequestID: r.RequestID,
		Usage: pricing.Usage{
			InputTokens:              u.InputTokens,
			OutputTokens:             u.OutputTokens,
			CacheCreationInputTokens: u.CacheCreationInputTokens,
			CacheReadInputTokens:     u.CacheReadInputTokens,
		},
	}, true, nil
}

type Reader struct {
	mu          sync.Mutex
	offsets     map[string]int64
	parseErrors int
	out         chan<- Event
	src         sources.Source
	// codexParsers holds one *codexParser per path currently tracked in
	// offsets, keyed the same way. codexParser is stateful (see its doc
	// comment), so unlike claudeParser/grokParser it cannot be recreated
	// on every OnChange call — see parserForChange. Entries are dropped
	// in Forget alongside the matching offsets entry, so a long-running
	// watcher does not accumulate parsers for files that have gone away.
	codexParsers map[string]*codexParser
}

func New(out chan<- Event) *Reader {
	home, err := os.UserHomeDir()
	var src sources.Source
	if err != nil {
		src = sources.Source{Vendor: "claude", Label: "claude"}
	} else {
		src = sources.Defaults(home)[0]
	}
	return &Reader{
		offsets: map[string]int64{},
		out:     out,
		src:     src,
	}
}

func (r *Reader) ParseErrors() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.parseErrors
}

// Forget drops a file from the offset map (used on Remove events), and
// from codexParsers alongside it — a deleted file's running totals are
// gone for good, and keeping the entry would both leak memory and, if
// the path were ever reused, resurrect stale state for an unrelated
// session.
func (r *Reader) Forget(path string) {
	r.mu.Lock()
	delete(r.offsets, path)
	delete(r.codexParsers, path)
	r.mu.Unlock()
}

// parserForChange resolves the vendorParser OnChange should use for one
// path. For the two stateless vendors this is just parserFor(vendor): a
// fresh value is fine since nothing carries over between calls. codex is
// not — the Reader keeps one *codexParser per path, created on first
// sight and reused on every later call, which is what makes running
// totals and session_meta survive across a growing file's OnChange
// calls. See codexParser's doc comment and Controller ruling R3.
func (r *Reader) parserForChange(vendor, path string) vendorParser {
	if vendor != "codex" {
		return parserFor(vendor)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if p, ok := r.codexParsers[path]; ok {
		return p
	}
	if r.codexParsers == nil {
		r.codexParsers = map[string]*codexParser{}
	}
	p := &codexParser{}
	r.codexParsers[path] = p
	return p
}

// walkableFor reports whether name can carry usage for vendor. Walkable
// never reads a parser's state for any vendor — including codex — so a
// throwaway instance is fine here even though real parsing must go
// through parserForChange's Reader-owned map.
func walkableFor(vendor, name string) bool {
	if vendor == "codex" {
		return (&codexParser{}).Walkable(name)
	}
	return parserFor(vendor).Walkable(name)
}

// OnChange reads any new complete lines in path starting from the
// previously-recorded offset, emits Events, and updates the offset.
// It never advances past an incomplete (non-\n-terminated) tail.
func (r *Reader) OnChange(path string) error {
	r.mu.Lock()
	start := r.offsets[path]
	src := r.src
	r.mu.Unlock()
	vendor, source := src.Vendor, src.ID()
	p := r.parserForChange(vendor, path)

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
	if stat.Size() < start {
		start = 0
		// The file shrank or was replaced: a previously-seen codex path
		// is about to be read from byte offset 0 again for a reason
		// other than "never seen before", so its running totals and
		// declared model must not survive into this read. See
		// codexParser.Reset's doc comment.
		if cp, ok := p.(*codexParser); ok {
			cp.Reset()
		}
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return err
	}

	data, err := io.ReadAll(f)
	if err != nil {
		return err
	}

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
		// Normalise to forward-slash so the project + subagent detection
		// works the same on Windows as on Unix.
		slashPath := filepath.ToSlash(path)
		evs, perr := p.Parse(line, slashPath)
		if perr != nil {
			r.mu.Lock()
			r.parseErrors++
			r.mu.Unlock()
			continue
		}
		project := p.Project(src.Root, slashPath)
		isSub := p.IsSubagent(src.Root, slashPath)
		for _, ev := range evs {
			ev.Project = project
			ev.IsSubagent = isSub
			ev.Vendor = vendor
			ev.Source = source
			r.out <- ev
		}
	}

	r.mu.Lock()
	r.offsets[path] = start + int64(consumed)
	r.mu.Unlock()
	return nil
}

// projectFromPath returns the canonical project key from a transcript
// file path. For ~/.claude/projects/<encoded>/<session>.jsonl or
// ~/.claude/projects/<encoded>/<session>/subagents/agent-*.jsonl this
// returns "<encoded>" — i.e. the segment immediately under projects/.
// The encoded form is the cwd with path separators replaced by '-', so
// it's stable across worktrees and uniquely identifies a project.
func projectFromPath(path string) string {
	idx := strings.Index(path, "/projects/")
	if idx < 0 {
		return ""
	}
	rest := path[idx+len("/projects/"):]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		return rest[:i]
	}
	return rest
}

// InitialScan walks root/**/*.jsonl recursively and reads every file
// whose mtime is at or after notBefore. Files are read in parallel
// across runtime.NumCPU() workers — OnChange is concurrency-safe on
// distinct paths (mutex covers only offsets/counters; the event
// channel send is independently safe). The recursion is required to
// pick up subagent transcripts, which Claude Code writes to
// <project>/<session-uuid>/subagents/agent-*.jsonl — these carry the
// usage of Task-tool subagents and account for the bulk of token
// volume on heavy days. After this returns, the reader's offset map
// reflects the end of every scanned file.
func (r *Reader) InitialScan(root string, notBefore time.Time) error {
	r.mu.Lock()
	vendor := r.src.Vendor
	r.mu.Unlock()

	paths := make(chan string, 256)

	walkErr := make(chan error, 1)
	go func() {
		walkErr <- filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if !walkableFor(vendor, d.Name()) {
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return nil
			}
			if info.ModTime().Before(notBefore) {
				return nil
			}
			paths <- path
			return nil
		})
		close(paths)
	}()

	workers := runtime.NumCPU()
	if workers < 2 {
		workers = 2
	}
	if workers > 8 {
		// Past 8 we hit diminishing returns and risk fd pressure on
		// modest ulimits. Disk read bandwidth is the bottleneck.
		workers = 8
	}
	var wg sync.WaitGroup
	wg.Add(workers)
	for i := 0; i < workers; i++ {
		go func() {
			defer wg.Done()
			for path := range paths {
				_ = r.OnChange(path)
			}
		}()
	}
	wg.Wait()
	return <-walkErr
}

// InitialScanSource walks one configured source's root, tagging every
// event with that source's vendor and identity.
func (r *Reader) InitialScanSource(src sources.Source, notBefore time.Time) error {
	r.mu.Lock()
	r.src = src
	r.mu.Unlock()
	return r.InitialScan(src.Root, notBefore)
}

// OnChangeSource handles a changed file belonging to a known source.
func (r *Reader) OnChangeSource(src sources.Source, path string) error {
	r.mu.Lock()
	r.src = src
	r.mu.Unlock()
	return r.OnChange(path)
}
