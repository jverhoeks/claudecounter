package insights

import (
	"fmt"

	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

const maxLoopWindow = 4

// loopFindings splits tool calls into the main and subagent streams and reports
// the strongest back-to-back repeated cycle in each (window size 1..4 repeated
// >= LoopMin times). Streams are analyzed independently so interleaved main +
// subagent traffic never forms a phantom loop.
func loopFindings(s *session.Session, th Thresholds) []Finding {
	var main, sub []string
	for _, c := range s.ToolCalls {
		tok := c.Name + ":" + c.Target
		if c.Sub {
			sub = append(sub, tok)
		} else {
			main = append(main, tok)
		}
	}
	var out []Finding
	if f, ok := bestLoop(main, th.LoopMin, "main"); ok {
		out = append(out, f)
	}
	if f, ok := bestLoop(sub, th.LoopMin, "subagent"); ok {
		out = append(out, f)
	}
	return out
}

// bestLoop scans seq for the longest-running contiguous repetition of any
// window of size 1..maxLoopWindow and returns a Finding if the run repeats at
// least loopMin times. "Longest-running" is scored by total covered length so
// a 3× two-call cycle (covers 6) beats a 3× one-call cycle (covers 3).
func bestLoop(seq []string, loopMin int, stream string) (Finding, bool) {
	bestReps, bestCover, bestW, bestAt := 0, 0, 0, 0
	for w := 1; w <= maxLoopWindow; w++ {
		for i := 0; i+w <= len(seq); i++ {
			reps := 1
			for j := i + w; j+w <= len(seq); j += w {
				if !windowEqual(seq, i, j, w) {
					break
				}
				reps++
			}
			if reps >= loopMin && reps*w > bestCover {
				bestReps, bestCover, bestW, bestAt = reps, reps*w, w, i
			}
		}
	}
	if bestReps < loopMin {
		return Finding{}, false
	}
	cycle := seq[bestAt : bestAt+bestW]
	return Finding{
		Category: CatLoop,
		Detail:   fmt.Sprintf("%s stream: cycle [%s] repeated %d×", stream, joinCycle(cycle), bestReps),
		Count:    bestReps,
	}, true
}

func windowEqual(seq []string, a, b, w int) bool {
	for k := 0; k < w; k++ {
		if seq[a+k] != seq[b+k] {
			return false
		}
	}
	return true
}

func joinCycle(cycle []string) string {
	out := ""
	for i, c := range cycle {
		if i > 0 {
			out += " → "
		}
		// token is "Name:Target"; show Name plus a short target tail.
		name, target := c, ""
		for k := 0; k < len(c); k++ {
			if c[k] == ':' {
				name, target = c[:k], c[k+1:]
				break
			}
		}
		if target != "" {
			out += name + " " + trunc(target, 24)
		} else {
			out += name
		}
	}
	return out
}
