package insights

import (
	"testing"
	"time"
)

func TestCache_RoundTrip(t *testing.T) {
	c := newCacheAt(t.TempDir(), true)
	key := c.Key("s1", time.Unix(1000, 0), 42)
	if _, ok := c.GetReport(key); ok {
		t.Fatal("expected miss on empty cache")
	}
	want := SessionReport{ID: "s1", Model: "m", USD: 1.5, WasteUSD: 0.5}
	c.PutReport(key, want)
	got, ok := c.GetReport(key)
	if !ok {
		t.Fatal("expected hit after put")
	}
	if got.ID != want.ID || got.USD != want.USD {
		t.Errorf("roundtrip: %+v", got)
	}
}

func TestCache_KeyInvalidation(t *testing.T) {
	c := newCacheAt(t.TempDir(), true)
	k1 := c.Key("s1", time.Unix(1000, 0), 42)
	k2 := c.Key("s1", time.Unix(2000, 0), 42) // mtime changed
	k3 := c.Key("s1", time.Unix(1000, 0), 99) // size changed
	if k1 == k2 || k1 == k3 || k2 == k3 {
		t.Errorf("keys should differ: %s %s %s", k1, k2, k3)
	}
}

func TestCache_Judgment(t *testing.T) {
	c := newCacheAt(t.TempDir(), true)
	d := Digest{ID: "s1", Prompts: []string{"hi"}}
	hash := DigestHash(d)
	if _, ok := c.GetJudgment(hash); ok {
		t.Fatal("expected miss")
	}
	c.PutJudgment(hash, Judgment{SessionID: "s1", Friction: 5, Available: true})
	got, ok := c.GetJudgment(hash)
	if !ok || got.Friction != 5 {
		t.Errorf("judgment roundtrip: %+v ok=%v", got, ok)
	}
	// Unavailable judgments are not cached.
	c.PutJudgment(DigestHash(Digest{ID: "s2"}), Judgment{Available: false})
	if _, ok := c.GetJudgment(DigestHash(Digest{ID: "s2"})); ok {
		t.Error("unavailable judgment should not be cached")
	}
}

func TestCache_Mined(t *testing.T) {
	c := newCacheAt(t.TempDir(), true)
	hash := "abc"
	c.PutMined(hash, ProjectMined{Project: "p", Available: true,
		Candidates: []MemoryCandidate{{Suggestion: "run tests"}}})
	got, ok := c.GetMined(hash)
	if !ok || len(got.Candidates) != 1 {
		t.Errorf("mined roundtrip: %+v ok=%v", got, ok)
	}
}

func TestCache_Disabled(t *testing.T) {
	c := newCacheAt(t.TempDir(), false)
	key := c.Key("s1", time.Unix(1000, 0), 42)
	c.PutReport(key, SessionReport{ID: "s1"})
	if _, ok := c.GetReport(key); ok {
		t.Error("disabled cache should never hit")
	}
}
