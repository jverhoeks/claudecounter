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
	Unknown int // distinct message ids seen with no pricing entry
	Dupes   int // events replaced by a later line for the same message.id
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

// contrib records the per-message-id contribution that's been added to
// byDay so we can subtract it when a later line for the same id arrives
// with updated (growing) usage. Claude Code streams partial writes of
// the same assistant response, and we need last-seen semantics.
type contrib struct {
	day    civilDay
	model  string
	usd    float64
	tokens TokenCounts
}

type Aggregator struct {
	mu          sync.Mutex
	pricing     pricing.Table
	byDay       map[civilDay]map[string]ModelDay
	perMsg      map[string]contrib // last contribution per message.id
	unknownMsgs map[string]struct{}
	dupes       int
	now         func() time.Time
}

func New(p pricing.Table) *Aggregator {
	return NewWithClock(p, time.Now)
}

func NewWithClock(p pricing.Table, now func() time.Time) *Aggregator {
	return &Aggregator{
		pricing:     p,
		byDay:       map[civilDay]map[string]ModelDay{},
		perMsg:      map[string]contrib{},
		unknownMsgs: map[string]struct{}{},
		now:         now,
	}
}

// Apply records an event's contribution. If the event carries a non-empty
// MessageID that has been seen before, its prior contribution is
// subtracted first, so the total reflects last-seen usage.
func (a *Aggregator) Apply(e reader.Event) {
	a.mu.Lock()
	defer a.mu.Unlock()

	newC := contrib{
		day:   dayOf(e.Timestamp),
		model: e.Model,
		tokens: TokenCounts{
			In:          e.Usage.InputTokens,
			Out:         e.Usage.OutputTokens,
			CacheCreate: e.Usage.CacheCreationInputTokens,
			CacheRead:   e.Usage.CacheReadInputTokens,
		},
	}
	if a.pricing.Has(e.Model) {
		newC.usd = a.pricing.Cost(e.Model, e.Usage)
	}

	if e.MessageID != "" {
		if prev, seen := a.perMsg[e.MessageID]; seen {
			a.subtract(prev)
			a.dupes++
		}
		a.perMsg[e.MessageID] = newC

		if !a.pricing.Has(e.Model) {
			a.unknownMsgs[e.MessageID] = struct{}{}
		}
	} else if !a.pricing.Has(e.Model) {
		// Unkeyed event with unknown model — count a synthetic id so
		// the "unknown" metric still advances.
		a.unknownMsgs[""+e.Model+e.Timestamp.String()] = struct{}{}
	}

	a.add(newC)
}

func (a *Aggregator) add(c contrib) {
	bucket, ok := a.byDay[c.day]
	if !ok {
		bucket = map[string]ModelDay{}
		a.byDay[c.day] = bucket
	}
	md := bucket[c.model]
	md.USD += c.usd
	md.Tokens.In += c.tokens.In
	md.Tokens.Out += c.tokens.Out
	md.Tokens.CacheCreate += c.tokens.CacheCreate
	md.Tokens.CacheRead += c.tokens.CacheRead
	bucket[c.model] = md
}

func (a *Aggregator) subtract(c contrib) {
	bucket, ok := a.byDay[c.day]
	if !ok {
		return
	}
	md := bucket[c.model]
	md.USD -= c.usd
	md.Tokens.In -= c.tokens.In
	md.Tokens.Out -= c.tokens.Out
	md.Tokens.CacheCreate -= c.tokens.CacheCreate
	md.Tokens.CacheRead -= c.tokens.CacheRead
	bucket[c.model] = md
}

// Dupes returns the number of times a line was replaced by a later line
// for the same message.id. Expected to be non-zero on real Claude Code
// data because assistant responses stream in growing partial writes.
func (a *Aggregator) Dupes() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.dupes
}

func (a *Aggregator) Snapshot() Totals {
	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.now().Local()
	today := civilDay{now.Year(), now.Month(), now.Day()}

	t := Totals{
		Day:     map[string]ModelDay{},
		Month:   map[string]ModelDay{},
		Unknown: len(a.unknownMsgs),
		Dupes:   a.dupes,
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
