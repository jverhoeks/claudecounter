package insights

import "github.com/jverhoeks/claudecounter/tui/internal/session"

// DigestTool is one tool call, flattened for the digest/LLM input.
type DigestTool struct {
	Name   string `json:"name"`
	Target string `json:"target,omitempty"`
	Err    bool   `json:"err,omitempty"`
	Sub    bool   `json:"sub,omitempty"`
}

// Digest is a compact, redacted, size-bounded view of one session. It serves
// three purposes at once: the on-disk cache entry, the input handed to the
// local `claude -p` judge, and a human/script-readable export. Heavy slices
// from the parsed session are truncated to keep LLM input small; what was
// dropped is recorded so nothing silently disappears.
type Digest struct {
	ID            string        `json:"id"`
	Project       string        `json:"project"`
	Cwd           string        `json:"cwd"`
	Model         string        `json:"model"`
	Start         string        `json:"start"`
	End           string        `json:"end"`
	Prompts       []string      `json:"prompts"`
	DroppedPrompt int           `json:"dropped_prompts,omitempty"`
	Tools         []DigestTool  `json:"tools"`
	DroppedTool   int           `json:"dropped_tools,omitempty"`
	Metrics       SessionReport `json:"metrics"`
}

// BuildDigest assembles a Digest from a parsed session and its already-computed
// Tier-1 report. maxPrompts/maxTools cap counts; maxRunes caps each prompt's
// length. Pure: no I/O.
func BuildDigest(s *session.Session, r SessionReport, maxPrompts, maxTools, maxRunes int) Digest {
	d := Digest{
		ID:      s.ID,
		Project: r.Project,
		Cwd:     s.Cwd,
		Model:   r.Model,
		Metrics: r,
	}
	if !s.Start.IsZero() {
		d.Start = s.Start.UTC().Format("2006-01-02T15:04:05Z")
	}
	if !s.End.IsZero() {
		d.End = s.End.UTC().Format("2006-01-02T15:04:05Z")
	}

	for i, p := range s.UserPrompts {
		if i >= maxPrompts {
			d.DroppedPrompt = len(s.UserPrompts) - maxPrompts
			break
		}
		d.Prompts = append(d.Prompts, trunc(p.Text, maxRunes))
	}

	for i, c := range s.ToolCalls {
		if i >= maxTools {
			d.DroppedTool = len(s.ToolCalls) - maxTools
			break
		}
		d.Tools = append(d.Tools, DigestTool{
			Name:   c.Name,
			Target: trunc(c.Target, maxRunes),
			Err:    c.IsErr,
			Sub:    c.Sub,
		})
	}
	return d
}
