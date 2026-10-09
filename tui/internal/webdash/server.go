// Package webdash serves the analytics dashboards (--web-dashboards) to
// the browser: one embedded page and a small JSON API over the same
// data the terminal dashboard draws from.
//
// The scan runs once at start (and again on POST /api/refresh); every
// query is answered from memory. The server binds 127.0.0.1 only and
// rejects requests whose Host isn't loopback, so a web page can't reach
// it through DNS rebinding.
package webdash

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"os/exec"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/dashboard"
	"github.com/jverhoeks/claudecounter/tui/internal/hints"
	"github.com/jverhoeks/claudecounter/tui/internal/perf"
)

//go:embed index.html
var page []byte

// Server holds the last scan and answers the page's queries from it.
type Server struct {
	load dashboard.Loader

	mu      sync.RWMutex
	data    *dashboard.Data
	loading bool
	done    atomic.Int64
	total   atomic.Int64
}

func New(load dashboard.Loader) *Server { return &Server{load: load} }

// Rescan reloads the data in the background; a scan already running wins.
func (s *Server) Rescan() {
	s.mu.Lock()
	if s.loading {
		s.mu.Unlock()
		return
	}
	s.loading = true
	s.mu.Unlock()
	s.done.Store(0)
	s.total.Store(0)
	go func() {
		d := s.load(func(done, total int) {
			s.done.Store(int64(done))
			s.total.Store(int64(total))
		})
		s.mu.Lock()
		s.data, s.loading = &d, false
		s.mu.Unlock()
	}()
}

func (s *Server) snapshot() (*dashboard.Data, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.data, s.loading
}

// Handler is the page and its API.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:")
		w.Write(page)
	})
	mux.HandleFunc("GET /api/status", s.status)
	mux.HandleFunc("POST /api/refresh", func(w http.ResponseWriter, r *http.Request) {
		s.Rescan()
		s.status(w, r)
	})
	mux.HandleFunc("GET /api/spend", s.ready(s.spend))
	mux.HandleFunc("GET /api/perf", s.ready(s.perf))
	mux.HandleFunc("GET /api/hints", s.ready(s.hints))
	return loopbackOnly(mux)
}

// loopbackOnly drops requests addressed to any host but this machine.
func loopbackOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil {
			host = r.Host
		}
		if host != "127.0.0.1" && host != "localhost" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type statusJSON struct {
	Loading  bool      `json:"loading"`
	Done     int64     `json:"done"`
	Total    int64     `json:"total"`
	Ready    bool      `json:"ready"`
	AsOf     time.Time `json:"asOf"`
	Warnings []string  `json:"warnings"`
	Samples  int       `json:"samples"`
}

func (s *Server) status(w http.ResponseWriter, _ *http.Request) {
	d, loading := s.snapshot()
	st := statusJSON{Loading: loading, Done: s.done.Load(), Total: s.total.Load(), Warnings: []string{}}
	if d != nil {
		st.Ready, st.AsOf, st.Samples = true, d.Spend.AsOf, len(d.Samples)
		st.Warnings = append(st.Warnings, d.Warnings...)
	}
	writeJSON(w, st)
}

func (s *Server) ready(h func(http.ResponseWriter, *http.Request, *dashboard.Data)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		d, _ := s.snapshot()
		if d == nil {
			http.Error(w, "still scanning", http.StatusServiceUnavailable)
			return
		}
		h(w, r, d)
	}
}

func intParam(r *http.Request, name string, def int) int {
	if v, err := strconv.Atoi(r.URL.Query().Get(name)); err == nil && v > 0 {
		return v
	}
	return def
}

type spendJSON struct {
	dashboard.SpendView
	HeatCap   float64              `json:"heatCap"`
	HeatStops []dashboard.HeatStop `json:"heatStops"`
}

func (s *Server) spend(w http.ResponseWriter, r *http.Request, d *dashboard.Data) {
	dim := dashboard.Dimension(r.URL.Query().Get("dim"))
	valid := false
	for _, x := range dashboard.Dimensions {
		valid = valid || x == dim
	}
	if !valid {
		dim = dashboard.DimModel
	}
	v := dashboard.Spend(d.Spend, dashboard.SpendQuery{
		RangeDays: intParam(r, "range", 30), Dim: dim, Focus: r.URL.Query().Get("focus"),
	}, d.Sources)
	writeJSON(w, spendJSON{SpendView: v, HeatCap: dashboard.HeatCap(v.Heatmap), HeatStops: dashboard.HeatStops})
}

type perfJSON struct {
	perf.Report
	Percentiles []string `json:"percentiles"`
	Efforts     []string `json:"efforts"`
	ContextBins []string `json:"contextBins"`
}

func (s *Server) perf(w http.ResponseWriter, r *http.Request, d *dashboard.Data) {
	q := r.URL.Query()
	agent := perf.Agent(q.Get("agent"))
	if agent != perf.AgentMain && agent != perf.AgentSubagent {
		agent = perf.AgentAll
	}
	bucket := perf.Bucket(q.Get("bucket"))
	if bucket != perf.BucketHour && bucket != perf.BucketDay && bucket != perf.BucketWeek {
		bucket = ""
	}
	rep := perf.BuildReport(d.Samples, perf.Filters{
		Model: q.Get("model"), RangeDays: intParam(r, "range", 7), Bucket: bucket, Agent: agent, Effort: q.Get("effort"),
	}, d.Spend.AsOf)
	out := perfJSON{Report: rep}
	for _, p := range perf.Percentiles {
		out.Percentiles = append(out.Percentiles, p.Label)
	}
	out.Efforts = perf.Efforts
	for _, b := range perf.ContextBins {
		out.ContextBins = append(out.ContextBins, b.Label)
	}
	writeJSON(w, out)
}

type hintsJSON struct {
	Days       int          `json:"days"`
	SpendUSD   float64      `json:"spendUSD"`
	Disclaimer string       `json:"disclaimer"`
	Hints      []hints.Hint `json:"hints"`
	Periods    []int        `json:"periods"`
}

func (s *Server) hints(w http.ResponseWriter, r *http.Request, d *dashboard.Data) {
	days := intParam(r, "days", 7)
	now := d.Spend.AsOf
	writeJSON(w, hintsJSON{
		Days:       days,
		SpendUSD:   hints.Spend(hints.InPeriod(d.Samples, days, now), d.Pricing),
		Disclaimer: hints.Disclaimer,
		Hints:      hints.Build(d.Samples, d.Pricing, d.Settings, days, now),
		Periods:    hints.Periods,
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

// Listen binds a random five-digit loopback port, retrying on collisions.
func Listen() (net.Listener, error) {
	var last error
	for range 20 {
		port := 10000 + rand.IntN(65536-10000)
		l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			return l, nil
		}
		last = err
	}
	return nil, fmt.Errorf("no free port: %w", last)
}

// OpenBrowser opens url in the default browser.
func OpenBrowser(url string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	return cmd.Start()
}

// Run starts the scan, serves on l and (if open) opens the browser; it
// returns when ctx is done.
func Run(ctx context.Context, load dashboard.Loader, l net.Listener, open bool, log io.Writer) error {
	s := New(load)
	s.Rescan()
	srv := &http.Server{Handler: s.Handler(), ReadHeaderTimeout: 10 * time.Second}
	url := fmt.Sprintf("http://localhost:%d/", l.Addr().(*net.TCPAddr).Port)
	fmt.Fprintf(log, "claudecounter dashboards at %s  (ctrl+c to stop)\n", url)
	if open {
		if err := OpenBrowser(url); err != nil {
			fmt.Fprintln(log, "couldn't open a browser:", err)
		}
	}
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(l) }()
	select {
	case <-ctx.Done():
		shut, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		return srv.Shutdown(shut)
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}
