package taskboard

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// corpus_base_survives_test.go is the SURVIVAL arm of task-1ca34359dc0805df.
//
// The incremental re-list (PR #18468) is only ever paid for on the SECOND
// re-list of one process: the first walk is what MAKES the base. Two separate
// faults meant that second re-list essentially never happened in the field, and
// each is proved here by a test that reds when its fix is reverted:
//
//  1. the leader of a single flight was handed the cache's own containers, and
//     its caller (fetchSnapshotWith -> syncDetails) writes them in place. A
//     waiter iterating the same map is `fatal error: concurrent map iteration
//     and map write` — a PROCESS KILL, measured on guerrilla 2026-09-18 at 29.3 s
//     from launch, both of two runs, each time seconds after the cold walk
//     landed. A board that dies cannot have a second re-list.
//
//  2. a walk that came back NON-exhaustive wiped the stored base. That is
//     self-perpetuating: the base thrown away is exactly what would have made
//     the next walk cheap enough to finish.
//
// Both tests drive the real fetchTaskCorpus seam. Neither uses -race: the gate
// runs CGO_ENABLED=0, where the race detector does not exist, so the assertions
// are on OBSERVABLE aliasing (mutate one holder, read another) rather than on a
// detector firing.

// TestTheLeaderDoesNotShareTheCachesContainers reds on revert of the
// copyTasks/copyDetails at the leader's return in fetchTaskCorpus.
//
// It asserts the property the crash is a symptom of, not the crash: the corpus a
// caller receives must be ITS OWN, because the board writes through it.
func TestTheLeaderDoesNotShareTheCachesContainers(t *testing.T) {
	l := newSlowLedger(t, 1500)
	close(l.release)
	cc := &corpusCache{live: true}
	now := time.Now()

	tasks, details, exh, err := fetchTaskCorpus(context.Background(), l.client(), cc, now)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	// PRECONDITION, asserted rather than assumed: without an exhaustive walk
	// there is no stored base at all and every assertion below would pass
	// vacuously against a zero value.
	if !exh {
		t.Fatal("precondition failed: the walk was not exhaustive, so no base was stored and this test measures nothing")
	}
	base := cc.snapshot()
	if !base.exhaustive || len(base.tasks) != 1500 || len(base.details) == 0 {
		t.Fatalf("precondition failed: the cache holds exhaustive=%v tasks=%d details=%d, want a full 1500-row base with details", base.exhaustive, len(base.tasks), len(base.details))
	}
	if len(tasks) != 1500 {
		t.Fatalf("precondition failed: the caller got %d rows, want 1500", len(tasks))
	}

	// Now do to the returned corpus exactly what fetchSnapshotWith does to it:
	// write through the map (syncDetails) and reorder the slice.
	const victim = "t-0000"
	d, ok := details[victim]
	if !ok {
		t.Fatalf("precondition failed: %s is absent from the returned details, so writing it proves nothing", victim)
	}
	d.Task.Title = "MUTATED BY THE CALLER"
	details[victim] = d
	tasks[0].Title = "MUTATED BY THE CALLER"

	after := cc.snapshot()
	if got := after.details[victim].Task.Title; got == "MUTATED BY THE CALLER" {
		t.Fatalf("the caller's write reached the cache's stored base (details[%s].Task.Title = %q): the leader was handed the cache's own map, so the board's syncDetails rewrites the base behind its back — and a waiter iterating that map while this write lands is `fatal error: concurrent map iteration and map write`", victim, got)
	}
	if got := after.tasks[0].Title; got == "MUTATED BY THE CALLER" {
		t.Fatalf("the caller's write reached the cache's stored base (tasks[0].Title = %q): the leader shares the base's backing array", got)
	}
}

// TestAWaiterAndTheLeaderDoNotShareOneDetailMap is the concurrent half. It is
// the shape that actually killed the process: leader and waiter both come out of
// one flight, and the leader's caller writes the map the waiter is copying.
func TestAWaiterAndTheLeaderDoNotShareOneDetailMap(t *testing.T) {
	l := newSlowLedger(t, 1500)
	cc := &corpusCache{live: true}
	c := l.client()
	now := time.Now()

	type result struct {
		details DetailIndex
		err     error
	}
	out := make(chan result, 2)
	fetch := func() {
		_, details, _, err := fetchTaskCorpus(context.Background(), c, cc, now)
		out <- result{details, err}
	}

	go fetch()
	select {
	case <-l.arrived:
	case <-time.After(5 * time.Second):
		t.Fatal("the fixture never saw the first request: the precondition of this test (a walk actually in flight) did not hold, so its verdict would mean nothing")
	}
	go fetch()
	time.Sleep(100 * time.Millisecond)
	close(l.release)

	var got []result
	for i := 0; i < 2; i++ {
		select {
		case r := <-out:
			got = append(got, r)
		case <-time.After(15 * time.Second):
			t.Fatal("a corpus fetch never returned")
		}
	}
	for i, r := range got {
		if r.err != nil {
			t.Fatalf("caller %d failed: %v", i, r.err)
		}
		if len(r.details) == 0 {
			t.Fatalf("caller %d got an EMPTY detail index: the precondition of the aliasing check below does not hold", i)
		}
	}
	base := cc.snapshot()
	if !base.exhaustive || len(base.details) == 0 {
		t.Fatal("precondition failed: the flight stored no base, so the aliasing check below has nothing to compare against")
	}
	// Assert against the CACHE, not against each other. Leader and waiter come
	// out of one flight and the cache's base holds the flight's own containers,
	// so "my map is not the base's map" is the one property that must hold for
	// EVERY caller — and it is exactly what makes the concurrent write safe: the
	// board's syncDetails runs on a private map, never on the one the cache
	// keeps and another caller may be copying.
	const victim = "t-0000"
	for i, r := range got {
		d, ok := r.details[victim]
		if !ok {
			t.Fatalf("precondition failed: %s is absent from caller %d's details", victim, i)
		}
		marker := fmt.Sprintf("MUTATED BY CALLER %d", i)
		d.Task.Title = marker
		r.details[victim] = d
		if got := cc.snapshot().details[victim].Task.Title; got == marker {
			t.Fatalf("caller %d writes THROUGH to the cache's stored base (details[%s].Task.Title = %q): it was handed the flight's own map, which the cache keeps and the other caller may be iterating — `fatal error: concurrent map iteration and map write`", i, victim, got)
		}
	}
}

// TestAShortWalkDoesNotDestroyAUsableBase reds on revert of the removed
// `else cc.store(corpusBase{})`.
//
// The fixture answers a PRE-CURSOR envelope (no `page.next_cursor` key), which
// is the honest exhaustive=false the walk reports when it cannot prove it saw
// the whole world. Whatever the cause — a short walk must never be able to take
// a usable base with it.
func TestAShortWalkDoesNotDestroyAUsableBase(t *testing.T) {
	var precursor bool
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/tasks", func(w http.ResponseWriter, r *http.Request) {
		base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
		docs := make([]map[string]any, 0, 3)
		for i := 0; i < 3; i++ {
			docs = append(docs, map[string]any{
				"doc_id":           fmt.Sprintf("t-%04d", i),
				"rev":              "r",
				"title":            fmt.Sprintf("Row %04d", i),
				"lifecycle_status": "open",
				"kind":             "task",
				"updated_at":       base.Add(time.Duration(3-i) * time.Minute).Format(time.RFC3339Nano),
				"content":          map[string]any{},
			})
		}
		page := map[string]any{}
		if !precursor {
			page["next_cursor"] = nil
		}
		body, _ := json.Marshal(map[string]any{"ok": true, "docs": docs, "page": page})
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	cc := &corpusCache{live: true}
	now := time.Now()

	// First walk: cursor-capable, exhaustive, so it lays down a real base.
	if _, _, exh, err := fetchTaskCorpus(context.Background(), c, cc, now); err != nil || !exh {
		t.Fatalf("precondition failed: the seeding walk returned exhaustive=%v err=%v, want a complete walk", exh, err)
	}
	seeded := cc.snapshot()
	if !incrementalUsable(seeded, now) {
		t.Fatal("precondition failed: the seeded base is not incrementally usable, so there is nothing for a short walk to destroy and this test would pass vacuously")
	}

	// Now the server goes pre-cursor. The walk cannot prove completeness.
	precursor = true
	// Push past fullResyncEvery so the incremental path refuses and the FULL
	// walk — the one that used to wipe — is the one that runs.
	later := now.Add(fullResyncEvery + time.Minute)
	_, _, exh, err := fetchTaskCorpus(context.Background(), c, cc, later)
	if err != nil {
		t.Fatalf("short walk: %v", err)
	}
	if exh {
		t.Fatal("precondition failed: the short walk reported exhaustive=true, so it was not short and this test measures nothing")
	}

	after := cc.snapshot()
	if !after.exhaustive || len(after.tasks) != len(seeded.tasks) || !after.watermark.Equal(seeded.watermark) || !after.lastFull.Equal(seeded.lastFull) {
		t.Fatalf("a NON-exhaustive walk destroyed the stored base (exhaustive=%v tasks=%d watermark=%v lastFull=%v, want the seeded %v/%d/%v/%v): losing state because a walk ran out of budget is the defect — and it is self-perpetuating, since the base it throws away is what would have made the next walk cheap enough to finish",
			after.exhaustive, len(after.tasks), after.watermark, after.lastFull,
			seeded.exhaustive, len(seeded.tasks), seeded.watermark, seeded.lastFull)
	}
}

// TestTheWirelogSpellsThePageSize is the arm for the fourth wirelog column.
// Without it the board's 546 KB incremental head page and its 11 MB exhaustive
// page are the same `/v1/tasks` row of the tally, and the question the byte
// counter exists to answer — did the incremental re-list arm? — cannot be read
// off the log at all.
func TestTheWirelogSpellsThePageSize(t *testing.T) {
	cases := []struct{ path, want string }{
		{headFetchPath + "&cursor=", "limit=50"},
		{listFetchPath + "&cursor=abc", "limit=1000"},
		{taskEventsPath, ""},
		{taskEventsPath + "?since=12", ""},
	}
	for _, tc := range cases {
		if got := wireLogLimit(tc.path); got != tc.want {
			t.Errorf("wireLogLimit(%q) = %q, want %q", tc.path, got, tc.want)
		}
	}
	// The aggregation key must still strip the query, or a cursor walk scatters
	// across one key per token and no tally is computable.
	if got := wireLogKey(headFetchPath + "&cursor=zz"); got != "/v1/tasks" {
		t.Errorf("wireLogKey stripped to %q, want /v1/tasks", got)
	}
}
