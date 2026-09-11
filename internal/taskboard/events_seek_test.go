package taskboard

import (
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
)

// events_seek_test.go guards the catch-up SEEK (seekEventsTip): the board must
// reach the tip of the keyset feed in O(log N) tiny probes, land on the tip
// EXACTLY, and never walk the discarded history.
//
// The measurement this replaces, taken on guerrilla 2026-09-09 with counters
// compiled into the binary: a `bp tasks` launch made 654 GET /v1/tasks/events
// requests and pulled 159 MB in its first 150 seconds, because the drain paged
// a 363451-id backlog 500 events at a time at ~70 KB a page.

// syntheticFeed is a keyset feed with `tip` as its highest event id. It answers
// the same contract the server does — a page of ids strictly greater than
// `since`, has_more when the page came back full, and the cursor echoed on an
// empty page — and counts every request and every event byte-equivalent it
// served, so a test can assert the SHAPE of the traffic rather than its effect.
type syntheticFeed struct {
	tip    int64
	calls  int
	events int // total events handed out across all calls
	maxLim int // the largest limit ever asked for
}

func (f *syntheticFeed) fetch(_ *apiclient.Client, since int64, limit int) (TaskEventsPage, error) {
	f.calls++
	if limit <= 0 {
		limit = taskEventsPageLimit
	}
	if limit > f.maxLim {
		f.maxLim = limit
	}
	if since < 0 {
		since = 0
	}
	page := TaskEventsPage{OK: true, Cursor: since}
	for id := since + 1; id <= f.tip && len(page.Events) < limit; id++ {
		page.Events = append(page.Events, TaskEvent{ID: id, Event: "task.updated", DocID: "task-x"})
		page.Cursor = id
	}
	f.events += len(page.Events)
	page.HasMore = len(page.Events) == limit
	return page, nil
}

// seekModel is a board wired to a synthetic feed with an immediate timer seam,
// so the whole catch-up runs at test speed while every request is real work the
// feed counts.
func seekModel(t *testing.T, f *syntheticFeed) Model {
	t.Helper()
	// A real (if empty) server behind the client: the catch-up's final re-list is
	// a genuine command this test runs, and a nil client would crash in it rather
	// than measure anything.
	cs := newCountingServer(t)
	at := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	m := newModel(cs.client(), "", Config{BaseURL: cs.srv.URL})
	m.now = func() time.Time { return at }
	m.tick = func(_ time.Duration, fn func(time.Time) tea.Msg) tea.Cmd {
		return func() tea.Msg { return fn(at) }
	}
	m.fetchEvents = f.fetch
	return m
}

// catchUp drives the poll chain from a cold cursor until the feed answers a
// SETTLED page — no events left and no more to walk — and returns how many times
// it went round. The timer seam fires instantly here, so the chain would poll a
// caught-up feed forever; settling is the loop's real terminating condition and
// stopping on it is what makes the request count below the cost of the CATCH-UP
// rather than the cost of the test's patience. Snapshot refetches run for real
// against the empty counting server — this test is about the FEED traffic, but
// executing the re-list is what keeps the request counts from being vacuous.
func catchUp(t *testing.T, m Model, f *syntheticFeed) (Model, int) {
	t.Helper()
	rounds := 0
	settled := false
	queue := []tea.Msg{eventsPollMsg{gen: m.eventsGen}}
	for len(queue) > 0 {
		rounds++
		if rounds > 20000 {
			t.Fatalf("catch-up did not settle after %d rounds (%d feed calls)", rounds, f.calls)
		}
		msg := queue[0]
		queue = queue[1:]
		var cmd tea.Cmd
		switch v := msg.(type) {
		case eventsPollMsg:
			m, cmd = m.handleEventsPoll(v)
		case eventsResultMsg:
			if v.err == nil && !v.page.HasMore && len(v.page.Events) == 0 {
				settled = true
			}
			m, cmd = m.handleEventsResult(v)
		default:
			continue
		}
		for _, out := range runCmd(cmd) {
			switch out.(type) {
			case eventsPollMsg:
				if !settled {
					queue = append(queue, out)
				}
			case eventsResultMsg:
				queue = append(queue, out)
			}
		}
	}
	return m, rounds
}

// TestCatchUpSeeksTheTipInsteadOfWalkingIt is the detector. On main the drain
// walks the backlog 500 events per request: a 363451-id feed is 727 calls and
// ~363k events shipped. With the seek it is a doubling bracket plus a bisection
// — a couple of dozen requests asking for ONE event each.
func TestCatchUpSeeksTheTipInsteadOfWalkingIt(t *testing.T) {
	const tip = 363451 // the measured guerrilla tip, 2026-09-09
	f := &syntheticFeed{tip: tip}
	m := seekModel(t, f)
	if m.eventCursor != 0 {
		t.Fatalf("precondition: a fresh board must start at cursor 0, got %d", m.eventCursor)
	}

	m, _ = catchUp(t, m, f)

	// The control the budget assertion needs: if the loop had not actually
	// caught up, a small call count would be trivially "good".
	if m.eventCursor != tip {
		t.Fatalf("cursor landed at %d, want the tip %d exactly", m.eventCursor, tip)
	}
	const budget = 40
	if f.calls > budget {
		t.Fatalf("catch-up made %d feed requests for a %d-id backlog, want <= %d "+
			"(the drain is walking the history instead of seeking the tip)", f.calls, tip, budget)
	}
	// The seek's real saving is the PAYLOAD, not just the request count: a
	// 500-event page measured ~70 KB against the real server, a 1-event probe
	// ~200 bytes. A "seek" that still asked for 500-event pages would satisfy the
	// call budget above and still ship 20000 events, so count them.
	//
	// The floor is one full page plus the probes: the drain is only DETECTED by a
	// poll coming back full, so that first ordinary 500-event page is paid before
	// there is anything to seek past. Everything after it must be single events.
	if want := taskEventsPageLimit + budget; f.events > want {
		t.Fatalf("catch-up was handed %d events, want <= %d (one detecting page + single-event probes) — "+
			"the probes are asking for pages, not single events", f.events, want)
	}
	if f.maxLim != taskEventsPageLimit {
		t.Fatalf("largest limit asked for was %d, want the ordinary page limit %d — "+
			"the detecting poll must stay a normal poll", f.maxLim, taskEventsPageLimit)
	}
}

// TestSeekLandsOnTheTipExactly is the no-overshoot guard, and it is the one that
// matters for correctness rather than cost. A cursor placed ABOVE the tip
// silently swallows every event created afterwards whose id lands underneath it:
// the board goes permanently stale while its dot still says live. Table-driven
// across boundary shapes so an off-by-one in the bisection cannot hide in one
// lucky tip value.
func TestSeekLandsOnTheTipExactly(t *testing.T) {
	for _, tip := range []int64{0, 1, 2, 1023, 1024, 1025, 2048, 65537, 363451} {
		f := &syntheticFeed{tip: tip}
		got, _, err := seekEventsTip(f.fetch, nil, 0)
		if err != nil {
			t.Fatalf("tip %d: seek failed: %v", tip, err)
		}
		if got != tip {
			t.Fatalf("tip %d: seek returned %d — a cursor off the tip either replays history (low) or swallows future events (high)", tip, got)
		}
	}
}

// TestSeekIsIdempotentOnACaughtUpFeed pins the other end: a board already at the
// tip must spend exactly ONE probe and stay put. Without the early return the
// bracket would bisect a range with no boundary in it.
func TestSeekIsIdempotentOnACaughtUpFeed(t *testing.T) {
	f := &syntheticFeed{tip: 4242}
	got, _, err := seekEventsTip(f.fetch, nil, 4242)
	if err != nil {
		t.Fatalf("seek failed: %v", err)
	}
	if got != 4242 {
		t.Fatalf("a caught-up seek moved the cursor to %d, want 4242", got)
	}
	if f.calls != 1 {
		t.Fatalf("a caught-up seek made %d requests, want exactly 1", f.calls)
	}
}
