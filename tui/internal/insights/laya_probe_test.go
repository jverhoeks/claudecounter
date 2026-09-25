//go:build layaprobe

// Manual checks against the real Laya model (downloads it if absent, runs
// uv + torch). Not part of the normal suite:
//
//	go test -tags layaprobe -run TestLaya -v -count=1 ./internal/insights/
//	LAYA_DIGEST=d.json go test -tags layaprobe -run TestLayaDigest -v ./internal/insights/
package insights

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/gomlx/go-huggingface/hub"
)

func TestLayaFetchOnline(t *testing.T) {
	start := time.Now()
	dir, err := fetchLaya(context.Background(), hub.New(layaModel).WithProgressBar(false))
	t.Logf("dir=%s err=%v in %v", dir, err, time.Since(start))
}

func TestLayaProbe(t *testing.T) {
	start := time.Now()
	s, err := NewLayaScorer().Score(context.Background(), []Digest{
		{Prompts: []string{"In tui/internal/pricing/defaults.go add claude-opus-5-5 at $4/$20, cache read $0.20, and a test in pricing_test.go asserting it.", "thanks, looks good"}},
		{Prompts: []string{"fix it", "no, that's the wrong file again", "you broke the build, revert that", "still failing, same error as before", "no! I said don't touch the tests"}},
	})
	t.Logf("elapsed %v err %v", time.Since(start), err)
	for i, x := range s {
		t.Logf("%d: %+v escalate=%v", i, x, escalate(x))
	}
}

// TestLayaDigest scores one `claudeinsights --session <id> --digest` file.
func TestLayaDigest(t *testing.T) {
	b, err := os.ReadFile(os.Getenv("LAYA_DIGEST"))
	if err != nil {
		t.Skip("set LAYA_DIGEST to a --digest JSON file")
	}
	var d Digest
	if err := json.Unmarshal(b, &d); err != nil {
		t.Fatal(err)
	}
	s, err := NewLayaScorer().Score(context.Background(), []Digest{d})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%+v escalate=%v", s[0], escalate(s[0]))
}
