package dashboard

import (
	"fmt"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

// Collect scans srcs (files modified at or after notBefore) into a new
// History. Callers filter out unreachable sources first.
func Collect(srcs []sources.Source, table pricing.Table, notBefore time.Time) (*History, error) {
	h := NewHistory(table)
	evCh := make(chan reader.Event, 1024)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for e := range evCh {
			h.Apply(e)
		}
	}()
	var err error
	for _, s := range srcs {
		if e := reader.New(evCh).InitialScanSource(s, notBefore); e != nil && err == nil {
			err = fmt.Errorf("scan %s: %w", s.ID(), e)
		}
	}
	close(evCh)
	<-done
	return h, err
}
