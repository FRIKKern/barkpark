package taskboard

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// corpus_singleflight_test.go is the COLD-START arm of task-1ca34359dc0805df.
//
// The incremental re-list (corpus.go) made a WARM re-list cheap. It could do
// nothing about the cold one, because there is no base to diff against yet —
// and the board asks for that cold corpus TWICE, concurrently: Init fires
// refetchCmd on a value receiver (nothing records the fetch as in flight), and
// the first events poll's delta arrives long before a ~16 s exhaustive walk
// returns, so the tick path's fetchInFlight guard sees a clean model and starts
// a second full walk beside the first.
//
// Measured on guerrilla 2026-09-17 with the wirelog byte counter: 204,631,877
// bytes of /v1/tasks in the first 60 s from launch, against 99,908,300 for one
// exhaustive walk on the same ledger in the same minute.
//
// The two tests below are the pair the doctrine asks for: one RED when the
// single flight is removed, one that stays quiet when it should — a SEQUENTIAL
// second ask must still reach the server, because "share the walk that is out"
// must never decay into "serve a stale one".

// slowLedger is a cursor-paged /v1/tasks whose FIRST request blocks until the
// test releases it, so a second caller is guaranteed to arrive while the first
// walk is still out. Without that gate the race is real but not reproducible,
// and a test that only sometimes exercises its subject is not a control.
type slowLedger struct {
	srv     *httptest.Server
	rows    int
	calls   int64
	arrived chan struct{} // closed when the first request lands
	release chan struct{} // closed by the test to let the first request finish
	once    sync.Once
}

func newSlowLedger(t *testing.T, rows int) *slowLedger {
	t.Helper()
	l := &slowLedger{
		rows:    rows,
		arrived: make(chan struct{}),
		release: make(chan struct{}),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/tasks", l.serve)
	l.srv = httptest.NewServer(mux)
	t.Cleanup(l.srv.Close)
	return l
}

func (l *slowLedger) client() *apiclient.Client {
	return apiclient.New(apiclient.Config{BaseURL: l.srv.URL})
}

func (l *slowLedger) serve(w http.ResponseWriter, r *http.Request) {
	if atomic.AddInt64(&l.calls, 1) == 1 {
		l.once.Do(func() { close(l.arrived) })
		<-l.release
	}
	q := r.URL.Query()
	limit := 1000
	fmt.Sscanf(q.Get("limit"), "%d", &limit)
	start := 0
	if c := q.Get("cursor"); c != "" {
		fmt.Sscanf(c, "%d", &start)
	}
	end := start + limit
	if end > l.rows {
		end = l.rows
	}
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	docs := make([]map[string]any, 0, end-start)
	for i := start; i < end; i++ {
		docs = append(docs, map[string]any{
			"doc_id":           fmt.Sprintf("t-%04d", i),
			"rev":              "r",
			"title":            fmt.Sprintf("Row %04d", i),
			"lifecycle_status": "open",
			"kind":             "task",
			"updated_at":       base.Add(time.Duration(l.rows-i) * time.Minute).Format(time.RFC3339Nano),
			"content":          map[string]any{},
		})
	}
	page := map[string]any{}
	if _, spelled := q["cursor"]; spelled {
		if end < l.rows {
			page["next_cursor"] = fmt.Sprintf("%d", end)
		} else {
			page["next_cursor"] = nil
		}
	}
	body, _ := json.Marshal(map[string]any{"ok": true, "docs": docs, "page": page})
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func (l *slowLedger) requests() int64 { return atomic.LoadInt64(&l.calls) }

// TestTwoConcurrentCorpusAsksCostOneWalk is the RED-on-revert arm: drop the
// single flight from fetchTaskCorpus and the fixture serves the walk twice.
func TestTwoConcurrentCorpusAsksCostOneWalk(t *testing.T) {
	// 1500 rows at the 1000-row page size is a TWO-page walk, so the assertion
	// distinguishes "one walk" from "one request" — a wrapper that accidentally
	// shared only the first page would still be caught.
	l := newSlowLedger(t, 1500)
	cc := &corpusCache{}
	c := l.client()
	now := time.Now()

	type result struct {
		tasks []Task
		exh   bool
		err   error
	}
	out := make(chan result, 2)
	fetch := func() {
		tasks, _, exh, err := fetchTaskCorpus(context.Background(), c, cc, now)
		out <- result{tasks, exh, err}
	}

	go fetch()
	select {
	case <-l.arrived:
	case <-time.After(5 * time.Second):
		t.Fatal("the fixture never saw the first request: the precondition of this test (a walk actually in flight) did not hold, so its verdict would mean nothing")
	}
	// The first walk is now provably blocked inside the server. Anything the
	// second caller does from here happens WHILE it is out.
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
		if !r.exh {
			t.Fatalf("caller %d got a NON-exhaustive corpus: the shared answer lost the walk's own completeness", i)
		}
		if len(r.tasks) != 1500 {
			t.Fatalf("caller %d got %d rows, want 1500: the shared answer is not the whole corpus", i, len(r.tasks))
		}
	}
	if n := l.requests(); n != 2 {
		t.Fatalf("two concurrent corpus asks cost %d /v1/tasks requests, want 2 (ONE two-page walk): the board is paying for the cold walk twice", n)
	}
	// The waiter must not share the leader's backing array.
	if len(got[0].tasks) > 0 && &got[0].tasks[0] == &got[1].tasks[0] {
		t.Fatal("both callers share one backing array: whichever sorts first races the other")
	}
}

// TestASequentialSecondAskStillReachesTheServer is the quiet arm. Single flight
// must share only a walk that is CURRENTLY OUT; once it lands, the next ask is
// a fresh read (incremental or full, corpus.go decides) and must produce new
// requests. A flight that outlived its walk would be a cache that never expires
// — the byte counter would look wonderful and the board would freeze.
func TestASequentialSecondAskStillReachesTheServer(t *testing.T) {
	l := newSlowLedger(t, 1500)
	close(l.release) // nothing blocks in this arm
	cc := &corpusCache{}
	c := l.client()
	now := time.Now()

	if _, _, _, err := fetchTaskCorpus(context.Background(), c, cc, now); err != nil {
		t.Fatalf("first fetch: %v", err)
	}
	first := l.requests()
	if first == 0 {
		t.Fatal("the first fetch made no request: the fixture is not being read, so the delta below is meaningless")
	}
	if _, _, _, err := fetchTaskCorpus(context.Background(), c, cc, now); err != nil {
		t.Fatalf("second fetch: %v", err)
	}
	if second := l.requests(); second <= first {
		t.Fatalf("a sequential second ask made %d requests total against %d for the first: it was served from a flight that should have been finished, so the board would never see another change", second, first)
	}
}
