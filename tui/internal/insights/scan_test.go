package insights

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

const scanFixture = `{"type":"user","timestamp":"2026-06-01T10:00:00Z","sessionId":"s1","cwd":"/tmp/proj","permissionMode":"default","message":{"role":"user","content":"do X"}}
{"type":"assistant","timestamp":"2026-06-01T10:00:05Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8[1m]","usage":{"input_tokens":100,"output_tokens":5},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"go test"}}]}}
`

func TestScan(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "-tmp-proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, "s1.jsonl"), []byte(scanFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	reports, err := Scan(root, priceTable(), DefaultThresholds(), time.Time{}, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(reports) != 1 {
		t.Fatalf("want 1 report, got %d", len(reports))
	}
	if reports[0].Project != "-tmp-proj" {
		t.Errorf("Project = %q", reports[0].Project)
	}
	if reports[0].Model != "claude-opus-4-8[1m]" {
		t.Errorf("Model = %q", reports[0].Model)
	}
}

func TestScan_CacheRoundTrip(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "-tmp-proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(proj, "s1.jsonl")
	if err := os.WriteFile(file, []byte(scanFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	cache := newCacheAt(t.TempDir(), true)

	first, err := Scan(root, priceTable(), DefaultThresholds(), time.Time{}, cache, false)
	if err != nil || len(first) != 1 {
		t.Fatalf("first scan: %v %d", err, len(first))
	}
	// Second scan should hit the cache and return an identical report.
	second, err := Scan(root, priceTable(), DefaultThresholds(), time.Time{}, cache, false)
	if err != nil || len(second) != 1 {
		t.Fatalf("second scan: %v %d", err, len(second))
	}
	if second[0].ID != first[0].ID || second[0].Model != first[0].Model {
		t.Errorf("cache hit differs: %+v vs %+v", second[0], first[0])
	}
}
