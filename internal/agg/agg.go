package agg

import (
	"sync"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/pricing"
	"github.com/jjverhoeks/claudecounter/internal/reader"
)

type TokenCounts struct {
	In, Out, CacheCreate, CacheRead uint64
}

type ModelDay struct {
	USD    float64
	Tokens TokenCounts
}

type Totals struct {
	Day     map[string]ModelDay
	Month   map[string]ModelDay
	Unknown int
	AsOf    time.Time
}

type civilDay struct {
	Y int
	M time.Month
	D int
}

func dayOf(t time.Time) civilDay {
	lt := t.Local()
	return civilDay{lt.Year(), lt.Month(), lt.Day()}
}

type Aggregator struct {
	mu      sync.Mutex
	pricing pricing.Table
	byDay   map[civilDay]map[string]ModelDay
	unknown int
	now     func() time.Time
}

func New(p pricing.Table) *Aggregator {
	return NewWithClock(p, time.Now)
}

func NewWithClock(p pricing.Table, now func() time.Time) *Aggregator {
	return &Aggregator{
		pricing: p,
		byDay:   map[civilDay]map[string]ModelDay{},
		now:     now,
	}
}

func (a *Aggregator) Apply(e reader.Event) {
	a.mu.Lock()
	defer a.mu.Unlock()

	day := dayOf(e.Timestamp)
	bucket, ok := a.byDay[day]
	if !ok {
		bucket = map[string]ModelDay{}
		a.byDay[day] = bucket
	}
	md := bucket[e.Model]
	md.Tokens.In += e.Usage.InputTokens
	md.Tokens.Out += e.Usage.OutputTokens
	md.Tokens.CacheCreate += e.Usage.CacheCreationInputTokens
	md.Tokens.CacheRead += e.Usage.CacheReadInputTokens

	if a.pricing.Has(e.Model) {
		md.USD += a.pricing.Cost(e.Model, e.Usage)
	} else {
		a.unknown++
	}
	bucket[e.Model] = md
}

func (a *Aggregator) Snapshot() Totals {
	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.now().Local()
	today := civilDay{now.Year(), now.Month(), now.Day()}

	t := Totals{
		Day:     map[string]ModelDay{},
		Month:   map[string]ModelDay{},
		Unknown: a.unknown,
		AsOf:    now,
	}

	if bucket, ok := a.byDay[today]; ok {
		for m, md := range bucket {
			t.Day[m] = md
		}
	}
	for day, bucket := range a.byDay {
		if day.Y != now.Year() || day.M != now.Month() {
			continue
		}
		for m, md := range bucket {
			agg := t.Month[m]
			agg.USD += md.USD
			agg.Tokens.In += md.Tokens.In
			agg.Tokens.Out += md.Tokens.Out
			agg.Tokens.CacheCreate += md.Tokens.CacheCreate
			agg.Tokens.CacheRead += md.Tokens.CacheRead
			t.Month[m] = agg
		}
	}
	return t
}
