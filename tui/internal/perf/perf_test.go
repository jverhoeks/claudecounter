package perf

import (
	"math"
	"math/rand"
	"sort"
	"strings"
	"testing"
	"time"
)

// A prompt, a two-block reply with a tool call, the tool's (failed)
// result, an attachment written after the next request went out, and a
// second reply that the user interrupted. Same fixture as the macapp's
// PerformanceTests.
var session = strings.Join([]string{
	`{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"fix the bug"}}`,
	`{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-10-01T10:00:03.000Z","requestId":"r1","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":""}],"usage":{"input_tokens":2,"output_tokens":400,"cache_read_input_tokens":30000,"cache_creation_input_tokens":1000,"output_tokens_details":{"thinking_tokens":120}}}}`,
	`{"type":"assistant","uuid":"a2","parentUuid":"a1","timestamp":"2026-10-01T10:00:07.000Z","requestId":"r1","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{}}],"usage":{"input_tokens":2,"output_tokens":400,"cache_read_input_tokens":30000,"cache_creation_input_tokens":1000}}}`,
	`{"type":"user","uuid":"u2","parentUuid":"a2","timestamp":"2026-10-01T10:00:08.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"<tool_use_error>String to replace not found in file.</tool_use_error>"}]}}`,
	`{"type":"attachment","uuid":"x1","parentUuid":"u2","timestamp":"2026-10-01T10:00:10.000Z"}`,
	`{"type":"assistant","uuid":"a3","parentUuid":"x1","timestamp":"2026-10-01T10:00:10.500Z","requestId":"r2","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":2,"output_tokens":50,"cache_read_input_tokens":31000,"cache_creation_input_tokens":500}}}`,
	`{"type":"user","uuid":"u3","parentUuid":"a3","timestamp":"2026-10-01T10:00:12.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}`,
	`{"type":"assistant","uuid":"e1","parentUuid":"u3","timestamp":"2026-10-01T10:00:13.000Z","requestId":"r3","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[],"usage":{"input_tokens":0,"output_tokens":0}}}`,
	"not json",
}, "\n") + "\n"

func near(t *testing.T, name string, got, want, tol float64) {
	t.Helper()
	if math.Abs(got-want) > tol {
		t.Errorf("%s = %v, want %v ± %v", name, got, want, tol)
	}
}

func TestParse_PairsRequestsWithTheirStart(t *testing.T) {
	s := Parse([]byte(session), "/p/projects/x/s.jsonl")
	if len(s) != 2 || s[0].RequestID != "r1" || s[1].RequestID != "r2" {
		t.Fatalf("requests = %+v", s)
	}
	r1 := s[0]
	near(t, "firstBlock", r1.FirstBlock, 3, 1e-6)
	near(t, "duration", r1.Duration, 7, 1e-6)
	if r1.Output != 400 || r1.Context != 31002 || r1.Thinking == nil || *r1.Thinking != 120 || r1.Effort != "high" {
		t.Errorf("r1 = %+v", r1)
	}
	if r1.ToolCalls != 1 || r1.ToolErrors.Misuse != 1 || r1.IsSubagent {
		t.Errorf("r1 tools = %+v", r1)
	}
	// r2's direct parent is an attachment written after the request went
	// out; the start is the tool_result before it.
	near(t, "r2 firstBlock", s[1].FirstBlock, 2.5, 1e-6)
	if !s[1].Interrupted {
		t.Error("r2 should be interrupted")
	}
}

func TestParse_SubagentPathIsSubagent(t *testing.T) {
	for _, x := range Parse([]byte(session), "/p/projects/x/s/subagents/agent-1.jsonl") {
		if !x.IsSubagent {
			t.Errorf("%s not subagent", x.RequestID)
		}
	}
}

func TestParse_IgnoresIncompleteTail(t *testing.T) {
	cut := strings.TrimSuffix(session, "\n")
	cut = cut[:strings.LastIndex(cut, "\n")] // drop "not json" — still 2 requests
	if n := len(Parse([]byte(cut), "/p/x/s.jsonl")); n != 2 {
		t.Errorf("got %d samples", n)
	}
}

func TestParse_FlagsCacheRebuildAfterIdle(t *testing.T) {
	lines := strings.Join([]string{
		`{"type":"user","uuid":"u1","timestamp":"2026-10-01T10:00:00Z","message":{"content":"a"}}`,
		`{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-10-01T10:00:02Z","requestId":"r1","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":10,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0}}}`,
		`{"type":"user","uuid":"u2","parentUuid":"a1","timestamp":"2026-10-01T12:00:00Z","message":{"content":"b"}}`,
		`{"type":"assistant","uuid":"a2","parentUuid":"u2","timestamp":"2026-10-01T12:00:04Z","requestId":"r2","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":100500}}}`,
	}, "\n") + "\n"
	s := Parse([]byte(lines), "/p/projects/x/s.jsonl")
	if len(s) != 2 || s[0].Rebuild != RebuildNone || s[1].Rebuild != RebuildAfterIdle {
		t.Errorf("rebuilds = %+v", s)
	}
}

func TestClassify(t *testing.T) {
	cases := map[string]ToolErrorClass{
		"<tool_use_error>File has not been read yet.": ClassMisuse,
		"Exit code 1\n": ClassExit,
		"Permission for this action was denied by the auto mode classifier": ClassPolicy,
		"ENOENT: no such file or directory, posix_spawn 'rg'":               ClassEnvironment,
	}
	for in, want := range cases {
		if got := ClassifyToolError(in); got != want {
			t.Errorf("%q → %v, want %v", in, got, want)
		}
	}
}

func TestFit_RecoversKnownParameters(t *testing.T) {
	// duration = 2 s + 10 ms/token + 0.01 s per 1k context, plus
	// one-sided waits on a quarter of the requests.
	rng := rand.New(rand.NewSource(1))
	base := time.Unix(1_790_000_000, 0)
	var samples []Sample
	for i := 0; i < 2000; i++ {
		out := uint64(20 + rng.Intn(3981))
		ctx := uint64(10_000 + rng.Intn(290_001))
		d := 2 + float64(out)*0.010 + float64(ctx)/1000*0.01 + (rng.Float64()*0.4 - 0.2)
		if i%4 == 0 {
			d += 1 + rng.Float64()*59
		}
		samples = append(samples, Sample{RequestID: "r", Time: base, Model: "m", FirstBlock: 1, Duration: d, Output: out, Context: ctx})
	}
	f := FitSamples(samples)
	if f == nil {
		t.Fatal("no fit")
	}
	near(t, "itlMs", f.ITLMs, 10, 0.5)
	near(t, "ttft", f.TTFT, 2.5, 0.3) // at the 50k reference context
	near(t, "ctx/100k", f.ContextCostPer100k, 1, 0.2)
}

func TestQuantileAndBuckets(t *testing.T) {
	if v, _ := Quantile([]float64{1, 2, 3, 4}, 0.5); v != 2.5 {
		t.Errorf("median = %v", v)
	}
	if _, ok := Quantile(nil, 0.5); ok {
		t.Error("empty quantile should be absent")
	}
	wed := time.Date(2026, 10, 7, 15, 30, 0, 0, time.Local)
	if got := BucketStart(wed, BucketWeek); !got.Equal(time.Date(2026, 10, 5, 0, 0, 0, 0, time.Local)) {
		t.Errorf("week start = %v", got)
	}
	if n := len(Buckets(wed, wed.Add(72*time.Hour), BucketDay)); n != 4 {
		t.Errorf("day buckets = %d", n)
	}
}

func TestReport_BucketsLineUpAndThinDataHasNoDrift(t *testing.T) {
	now := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	var samples []Sample
	th := uint64(70)
	for i := 0; i < 300; i++ {
		effort := ""
		if i%2 == 0 {
			effort = "high"
		}
		samples = append(samples, Sample{
			RequestID: "r", Time: now.Add(-time.Duration(i) * 3000 * time.Second), Model: "m", IsSubagent: i%3 == 0,
			Effort: effort, FirstBlock: 2, Duration: 2 + float64(i%50)*0.1, Output: uint64(100 + i*10),
			Context: 50_000, CacheRead: 45_000, Thinking: &th, ToolCalls: 1,
		})
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i].Time.Before(samples[j].Time) })
	r := BuildReport(samples, Filters{RangeDays: 30}, now)
	if r.Model != "m" || r.Requests != 300 || r.Filters.ResolvedBucket() != BucketDay {
		t.Fatalf("report = %s %d %s", r.Model, r.Requests, r.Filters.ResolvedBucket())
	}
	for _, series := range [][]*float64{r.CacheHitRate, r.MisuseRate, r.OutputP50, r.ContextP50, r.MeanInFlight} {
		if len(series) != len(r.Buckets) {
			t.Errorf("series len %d vs %d buckets", len(series), len(r.Buckets))
		}
	}
	total := 0
	for _, c := range r.Counts {
		total += c
	}
	if total != 300 {
		t.Errorf("counts sum = %d", total)
	}
	var think *float64
	for _, v := range r.ThinkingP50 {
		if v != nil {
			think = v
			break
		}
	}
	if think == nil || *think != 70 {
		t.Errorf("thinking p50 = %v", think)
	}
	if r.TTFTDrift != nil || r.MisuseDrift != nil {
		t.Error("100 per third is under the drift floor")
	}
	shares := map[string]float64{}
	for _, c := range r.EffortMatrix {
		shares[c.Effort] = c.Share
	}
	near(t, "high share", shares["high"], 0.5, 1e-9)
	near(t, "none share", shares["none"], 0.5, 1e-9)
	filtered := BuildReport(samples, Filters{RangeDays: 30, Effort: "high"}, now)
	if filtered.Requests != 150 || len(filtered.EffortMatrix) != 2 {
		t.Errorf("filtered = %d requests, %d cells", filtered.Requests, len(filtered.EffortMatrix))
	}
	if main := BuildReport(samples, Filters{RangeDays: 30, Agent: AgentMain}, now); main.Requests != 200 {
		t.Errorf("main = %d", main.Requests)
	}
}
