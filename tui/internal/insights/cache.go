package insights

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Cache persists per-session Tier-1 reports keyed by file identity
// (id + mtime + size) so unchanged transcripts are never re-parsed. It is
// best-effort: every read/write error degrades to a fresh compute, never a
// crash. A disabled cache is a no-op (always misses, never writes).
type Cache struct {
	dir     string
	enabled bool
}

// cacheDir resolves $XDG_CACHE_HOME/claudeinsights, else ~/.cache/claudeinsights.
func cacheDir() string {
	if x := os.Getenv("XDG_CACHE_HOME"); x != "" {
		return filepath.Join(x, "claudeinsights")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache", "claudeinsights")
}

// OpenCache returns a Cache rooted at the standard cache dir. enabled=false
// yields a no-op cache.
func OpenCache(enabled bool) *Cache {
	return newCacheAt(cacheDir(), enabled)
}

func newCacheAt(dir string, enabled bool) *Cache {
	c := &Cache{dir: dir, enabled: enabled}
	if enabled {
		// Failure here just means later writes fail and we recompute.
		_ = os.MkdirAll(dir, 0o755)
	}
	return c
}

// Key derives a stable cache key from a transcript's identity. Any change to
// the file's mtime or size produces a new key, so growth/edits invalidate.
func (c *Cache) Key(id string, mtime time.Time, size int64) string {
	h := sha256.Sum256([]byte(id + "|" + mtime.UTC().Format(time.RFC3339Nano) + "|" + itoa(size)))
	return hex.EncodeToString(h[:])
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

func (c *Cache) path(key string) string {
	return filepath.Join(c.dir, "report-"+key+".json")
}

// GetReport returns a cached report and true on hit; false on miss, disabled
// cache, or any read/decode error.
func (c *Cache) GetReport(key string) (SessionReport, bool) {
	if !c.enabled {
		return SessionReport{}, false
	}
	data, err := os.ReadFile(c.path(key))
	if err != nil {
		return SessionReport{}, false
	}
	var r SessionReport
	if err := json.Unmarshal(data, &r); err != nil {
		return SessionReport{}, false
	}
	return r, true
}

// PutReport writes a report to the cache. Errors are swallowed.
func (c *Cache) PutReport(key string, r SessionReport) {
	if !c.enabled {
		return
	}
	data, err := json.Marshal(r)
	if err != nil {
		return
	}
	_ = os.WriteFile(c.path(key), data, 0o644)
}

// DigestHash is the content hash of a digest, used as the LLM cache key base.
func DigestHash(d Digest) string {
	data, _ := json.Marshal(d)
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

// llmPath names an LLM cache file. kind distinguishes judgments from mined
// results; the prompt version is folded into the name so a prompt change
// invalidates every stale entry without a manual purge.
func (c *Cache) llmPath(kind, base string) string {
	return filepath.Join(c.dir, fmt.Sprintf("llm-%s-v%d-%s.json", kind, judgePromptVersion, base))
}

// GetJudgment returns a cached per-session judgment (hash = DigestHash).
func (c *Cache) GetJudgment(hash string) (Judgment, bool) {
	if !c.enabled {
		return Judgment{}, false
	}
	data, err := os.ReadFile(c.llmPath("judge", hash))
	if err != nil {
		return Judgment{}, false
	}
	var j Judgment
	if err := json.Unmarshal(data, &j); err != nil {
		return Judgment{}, false
	}
	return j, true
}

// PutJudgment caches a per-session judgment. Only successful ones are stored,
// so a transient LLM failure isn't pinned. Errors swallowed.
func (c *Cache) PutJudgment(hash string, j Judgment) {
	if !c.enabled || !j.Available {
		return
	}
	if data, err := json.Marshal(j); err == nil {
		_ = os.WriteFile(c.llmPath("judge", hash), data, 0o644)
	}
}

// GetMined / PutMined cache a project's CLAUDE.md candidates, keyed by a hash
// of the project's combined digests.
func (c *Cache) GetMined(hash string) (ProjectMined, bool) {
	if !c.enabled {
		return ProjectMined{}, false
	}
	data, err := os.ReadFile(c.llmPath("mine", hash))
	if err != nil {
		return ProjectMined{}, false
	}
	var m ProjectMined
	if err := json.Unmarshal(data, &m); err != nil {
		return ProjectMined{}, false
	}
	return m, true
}

func (c *Cache) PutMined(hash string, m ProjectMined) {
	if !c.enabled || !m.Available {
		return
	}
	if data, err := json.Marshal(m); err == nil {
		_ = os.WriteFile(c.llmPath("mine", hash), data, 0o644)
	}
}

// GetActions / PutActions cache the synthesized action list, keyed by a hash of
// the judged session set.
func (c *Cache) GetActions(hash string) (ActionList, bool) {
	if !c.enabled {
		return ActionList{}, false
	}
	data, err := os.ReadFile(c.llmPath("actions", hash))
	if err != nil {
		return ActionList{}, false
	}
	var a ActionList
	if err := json.Unmarshal(data, &a); err != nil {
		return ActionList{}, false
	}
	return a, true
}

func (c *Cache) PutActions(hash string, a ActionList) {
	if !c.enabled || !a.Available {
		return
	}
	if data, err := json.Marshal(a); err == nil {
		_ = os.WriteFile(c.llmPath("actions", hash), data, 0o644)
	}
}
