package insights

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gomlx/go-huggingface/hub"
)

// LayaScore is the local Laya classifier's read on one session: calibrated
// scores and probabilities, no text. Laya is an encoder, not a generator, so
// quotes, root causes and advice still come from the Judge.
type LayaScore struct {
	Friction          int     `json:"friction"`           // 0-10
	PromptSpecificity int     `json:"prompt_specificity"` // 0-10
	PCorrection       float64 `json:"p_correction"`
	PLoop             float64 `json:"p_loop"`
}

// Scorer scores digests in one batch, so the model's load cost is paid once.
type Scorer interface {
	Score(ctx context.Context, ds []Digest) ([]LayaScore, error)
}

//go:embed laya_score.py
var layaScript string

// layaQuestions is the Laya request schema. Score questions use 5 levels,
// mapped onto the judge's 0-10 scale.
var layaQuestions = map[string]any{
	"friction": map[string]any{
		"type":         "score",
		"instructions": "How much rework or frustration does this coding session show?",
		"criteria": []string{"smooth, no rework", "minor rework", "some rework or re-asking",
			"lots of rework and repeated corrections", "painful: thrashing and frustration"},
	},
	"prompt_specificity": map[string]any{
		"type":         "score",
		"instructions": "How clear and specific is the user's first prompt?",
		"criteria": []string{"vague, no target or goal", "somewhat vague", "clear goal, missing details",
			"clear and specific", "precise: target, constraints and done-criteria stated"},
	},
	"correction": map[string]any{
		"type":         "noul",
		"instructions": "Does the user push back on, correct, or re-ask the assistant because it got something wrong?",
	},
	"loop": map[string]any{
		"type":         "noul",
		"instructions": "Does the session show an unproductive loop, such as the same fix retried or thrashing?",
	},
}

// layaModel is the English Laya checkpoint. layaFiles is everything its
// reference runtime reads: the upstream inference code ships in the repo.
const layaModel = "convaiinnovations/laya"

var layaFiles = []string{
	"rl_agent_config.json", "rl_agent_api.py", "rl_common.py", "model.safetensors",
	"encoder/config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json",
}

// fetchLaya returns the local snapshot directory holding layaFiles,
// downloading whatever is missing. It shares ~/.cache/huggingface/hub with
// Python's huggingface_hub, so an existing checkpoint is reused and no
// request is made once every file is cached.
func fetchLaya(ctx context.Context, repo *hub.Repo) (string, error) {
	paths, err := repo.DownloadFilesCtx(ctx, layaFiles...)
	if err != nil {
		return "", fmt.Errorf("laya download: %w", err)
	}
	return filepath.Dir(paths[0]), nil // layaFiles[0] sits at the repo root
}

// LayaScorer fetches the checkpoint natively (fetchLaya) and runs
// laya_score.py on it under `uv run`, which provisions torch and
// transformers in uv's cache on first use.
type LayaScorer struct {
	Timeout time.Duration
}

// NewLayaScorer allows for the first run's torch install and weight load.
func NewLayaScorer() *LayaScorer { return &LayaScorer{Timeout: 10 * time.Minute} }

func (l *LayaScorer) Score(ctx context.Context, ds []Digest) ([]LayaScore, error) {
	if len(ds) == 0 {
		return nil, nil
	}
	in, err := json.Marshal(map[string]any{"questions": layaQuestions, "states": layaStates(ds)})
	if err != nil {
		return nil, err
	}
	cctx, cancel := context.WithTimeout(ctx, l.Timeout)
	defer cancel()
	dir, err := fetchLaya(cctx, hub.New(layaModel).WithProgressBar(false))
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(cctx, "uv", "run", "--no-project", "--quiet",
		"--with", "torch", "--with", "transformers", "--with", "safetensors",
		"--with", "numpy", "python", "-c", layaScript, dir)
	// transformers probes TensorFlow at import and can deadlock (upstream README).
	cmd.Env = append(os.Environ(), "USE_TF=0")
	cmd.Stdin = bytes.NewReader(in)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("laya: %w: %s", err, lastLine(stderr.String()))
	}
	return parseLaya(out, len(ds))
}

// layaStates puts the first prompt first: Laya reads 512 tokens and cuts the
// state from the end, so the later prompts are what gets truncated.
func layaStates(ds []Digest) []map[string]any {
	states := make([]map[string]any, len(ds))
	for i, d := range ds {
		first, later := "", []string{}
		if len(d.Prompts) > 0 {
			first, later = d.Prompts[0], d.Prompts[1:]
		}
		states[i] = map[string]any{"first_prompt": first, "later_prompts": later}
	}
	return states
}

func parseLaya(out []byte, n int) ([]LayaScore, error) {
	var raw []map[string]struct {
		Score float64 `json:"score"`
		Noul  float64 `json:"noul"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, fmt.Errorf("laya output: %w", err)
	}
	if len(raw) != n {
		return nil, fmt.Errorf("laya returned %d results for %d sessions", len(raw), n)
	}
	scores := make([]LayaScore, n)
	for i, a := range raw {
		scores[i] = LayaScore{
			Friction:          int(math.Round(a["friction"].Score * 2.5)),
			PromptSpecificity: int(math.Round(a["prompt_specificity"].Score * 2.5)),
			PCorrection:       a["correction"].Noul,
			PLoop:             a["loop"].Noul,
		}
	}
	return scores, nil
}

func lastLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return s[i+1:]
	}
	return s
}

// escalate reports whether a session's Laya read warrants the text judge.
func escalate(s LayaScore) bool {
	return s.Friction >= 5 || s.PCorrection >= 0.5 || s.PLoop >= 0.5
}

// JudgeHybrid scores every digest locally with Laya and sends only the rough
// ones to j for quotes, root cause and advice; the scores shown are Laya's in
// both cases, so sessions stay comparable. If Laya fails, every digest goes to
// j (the pre-Laya behaviour) and the error is returned for the caller to report.
func JudgeHybrid(ctx context.Context, sc Scorer, j Judge, ds []Digest) ([]Judgment, error) {
	scores, layaErr := sc.Score(ctx, ds)
	out := make([]Judgment, len(ds))
	for i, d := range ds {
		if layaErr != nil {
			out[i] = JudgeSession(ctx, j, d)
			continue
		}
		s := scores[i]
		if escalate(s) {
			out[i] = JudgeSession(ctx, j, d)
		} else {
			out[i] = Judgment{SessionID: d.ID, Available: true}
		}
		out[i].Laya = &s
		if out[i].Available {
			out[i].Friction, out[i].PromptSpecificity = s.Friction, s.PromptSpecificity
		}
	}
	return out, layaErr
}
