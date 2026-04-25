package reader

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/pricing"
)

type Event struct {
	Timestamp time.Time
	SessionID string
	Cwd       string
	Model     string
	MessageID string // Anthropic message id
	RequestID string // Anthropic request id; combined with MessageID for dedupe
	Usage     pricing.Usage
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
}

func New(out chan<- Event) *Reader {
	return &Reader{
		offsets: map[string]int64{},
		out:     out,
	}
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
		if !ok {
			continue
		}
		r.out <- ev
	}

	r.mu.Lock()
	r.offsets[path] = start + int64(consumed)
	r.mu.Unlock()
	return nil
}

// InitialScan walks root/**/*.jsonl recursively and reads every file
// whose mtime is at or after notBefore. The recursion is required to
// pick up subagent transcripts, which Claude Code writes to
// <project>/<session-uuid>/subagents/agent-*.jsonl — these carry the
// usage of Task-tool subagents and account for the bulk of token volume
// on heavy days. After this returns, the reader's offset map reflects
// the end of every scanned file.
func (r *Reader) InitialScan(root string, notBefore time.Time) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			// Don't abort the whole scan if a single subdir is unreadable.
			return nil
		}
		if d.IsDir() {
			return nil
		}
		if filepath.Ext(d.Name()) != ".jsonl" {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		if info.ModTime().Before(notBefore) {
			return nil
		}
		_ = r.OnChange(path)
		return nil
	})
}
