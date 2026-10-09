package webdash

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/dashboard"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

func get(t *testing.T, h http.Handler, method, target, host string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, target, nil)
	r.Host = host
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestRejectsForeignHost(t *testing.T) {
	h := New(func(func(int, int)) dashboard.Data { return dashboard.Data{} }).Handler()
	if w := get(t, h, "GET", "/", "evil.example:12345"); w.Code != http.StatusForbidden {
		t.Fatalf("foreign host: got %d, want 403", w.Code)
	}
	if w := get(t, h, "GET", "/", "localhost:12345"); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "claudecounter") {
		t.Fatalf("localhost: got %d", w.Code)
	}
}

func TestScanningThenReady(t *testing.T) {
	release := make(chan struct{})
	s := New(func(func(int, int)) dashboard.Data {
		<-release
		return dashboard.Data{Spend: dashboard.NewHistory(pricing.Table{}).Snapshot(time.Now()), Pricing: pricing.Table{}}
	})
	h := s.Handler()
	s.Rescan()
	if w := get(t, h, "GET", "/api/spend", "127.0.0.1:1"); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("before scan: got %d, want 503", w.Code)
	}
	close(release)
	for deadline := time.Now().Add(2 * time.Second); ; {
		if d, _ := s.snapshot(); d != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("scan never finished")
		}
		time.Sleep(5 * time.Millisecond)
	}
	for _, path := range []string{"/api/spend?range=7&dim=bogus", "/api/perf?range=7", "/api/hints?days=7", "/api/status"} {
		w := get(t, h, "GET", path, "127.0.0.1:1")
		if w.Code != http.StatusOK {
			t.Fatalf("%s: got %d %s", path, w.Code, w.Body)
		}
		var v map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
	}
	if w := get(t, h, "GET", "/api/spend?dim=bogus", "127.0.0.1:1"); !strings.Contains(w.Body.String(), `"dim":"model"`) {
		t.Fatalf("unknown dim should fall back to model: %s", w.Body)
	}
	if w := get(t, h, "GET", "/api/refresh", "127.0.0.1:1"); w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET refresh: got %d, want 405", w.Code)
	}
}
