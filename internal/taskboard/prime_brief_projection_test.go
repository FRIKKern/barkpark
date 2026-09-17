package taskboard

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// prime_brief_projection_test.go pins task-ac9e7dd0d4e53d24's fix: the LIVE
// board asks /v1/tasks/prime for the `brief` projection (the body it already
// consumed identically), while every ONE-SHOT verb keeps the full view and the
// deep event tail that computeResumables reads.
//
// EACH ARM NAMES THE FAILURE DIRECTION IT CATCHES, because "the flag is in the
// file" is not "the flag fires":
//
//   - drop `&view=brief` from fetchPrime          -> TestLiveBoardPrimeAsksForTheBriefProjection reds
//   - send it on the one-shot path too            -> TestOneShotPrimeKeepsTheFullView reds
//   - let brief's 5-row tail reach the Snapshot   -> TestBriefEventTailIsRebuiltAcrossTicks reds
//   - merge/reorder on the one-shot path          -> TestOneShotEventTailIsUntouched reds
//
// The quiet control is TestBriefProjectionDoesNotChangeWhatTheBoardReads: the
// composed Snapshot off a brief body and off a full body agree on ready ids and
// counts, so an arm cannot pass by breaking the decode.

// primeRecorder is a task server that records every /v1/tasks/prime query and
// serves a body in the view that query asked for. Ready cards differ by view
// exactly as the real controller's do (full = render_doc, brief = brief card),
// and only the brief arm trims recent_events to 5 — the coupling this fix pays
// for.
type primeRecorder struct {
	mu      sync.Mutex
	queries []string
	events  int // how many events the FULL arm returns
}

func (p *primeRecorder) seen() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, len(p.queries))
	copy(out, p.queries)
	return out
}

func (p *primeRecorder) primeBody(view string) []byte {
	n := p.events
	if view == "brief" {
		n = 5
	}
	base := time.Date(2026, 9, 17, 22, 0, 0, 0, time.UTC)
	events := make([]map[string]any, 0, n)
	for i := 0; i < n; i++ {
		events = append(events, map[string]any{
			"event":  "task.claimed",
			"doc_id": fmt.Sprintf("t-%03d", i),
			// Newest first, one second apart — the shape prime returns.
			"at": base.Add(time.Duration(-i) * time.Second).Format(time.RFC3339Nano),
		})
	}
	ready := make([]map[string]any, 0, 2)
	for _, id := range []string{"ready-1", "ready-2"} {
		card := map[string]any{"doc_id": id, "title": "t", "lifecycle_status": "open"}
		if view != "brief" {
			// The full arm's card is the fat one this fix stops paying for.
			card["content"] = map[string]any{"description": "x", "acceptance_criteria": []any{}}
			card["edge_counts"] = map[string]any{"in": 0, "out": 0}
		}
		ready = append(ready, card)
	}
	b, _ := json.Marshal(map[string]any{
		"ok":            true,
		"counts":        map[string]int{"open": 7},
		"ready":         ready,
		"in_progress":   []any{},
		"recent_events": events,
	})
	return b
}

func (p *primeRecorder) server(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/tasks":
			_, _ = w.Write([]byte(`{"ok":true,"docs":[]}`))
		case "/v1/tasks/prime":
			p.mu.Lock()
			p.queries = append(p.queries, r.URL.RawQuery)
			p.mu.Unlock()
			_, _ = w.Write(p.primeBody(r.URL.Query().Get("view")))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

// TestLiveBoardPrimeAsksForTheBriefProjection — the LOUD arm. Reds if the
// projection is dropped.
func TestLiveBoardPrimeAsksForTheBriefProjection(t *testing.T) {
	rec := &primeRecorder{events: 40}
	srv := rec.server(t)
	defer srv.Close()

	fetch := newSnapshotFetcher()
	if _, _, err := fetch(newClient(srv.URL)); err != nil {
		t.Fatalf("live fetch: %v", err)
	}
	got := rec.seen()
	// ABSENCE DISCIPLINE: print the whole recorded key set before reading it, and
	// refuse a zero-request pass outright.
	t.Logf("recorded prime queries: %q", got)
	if len(got) != 1 {
		t.Fatalf("prime request count = %d, want 1 — recorded: %q", len(got), got)
	}
	if got[0] != "limit=100&view=brief" {
		t.Errorf("live board prime query = %q, want %q (the board throws every rendered card away; the full view is 1.3 MB of it)", got[0], "limit=100&view=brief")
	}
}

// TestOneShotPrimeKeepsTheFullView — the other direction. Reds if the projection
// over-fires onto the verbs whose event tail nothing refills.
func TestOneShotPrimeKeepsTheFullView(t *testing.T) {
	rec := &primeRecorder{events: 40}
	srv := rec.server(t)
	defer srv.Close()

	if _, _, err := FetchSnapshotFull(newClient(srv.URL)); err != nil {
		t.Fatalf("one-shot fetch: %v", err)
	}
	got := rec.seen()
	t.Logf("recorded prime queries: %q", got)
	if len(got) != 1 {
		t.Fatalf("prime request count = %d, want 1 — recorded: %q", len(got), got)
	}
	if got[0] != "limit=100" {
		t.Errorf("one-shot prime query = %q, want %q — `bp task next`/`frontier`/`lint`/`cmux dispatch` get ONE body and computeResumables reads its event tail", got[0], "limit=100")
	}
}

// TestBriefEventTailIsRebuiltAcrossTicks — the arm that makes the projection
// honest. A brief body carries 5 events; three ticks with DISJOINT newest-5
// windows must compose to 15, not 5. Reds if mergeEventTail is removed.
func TestBriefEventTailIsRebuiltAcrossTicks(t *testing.T) {
	var (
		mu    sync.Mutex
		tick  int
		nreq  int
		base  = time.Date(2026, 9, 17, 22, 0, 0, 0, time.UTC)
		chunk = 5
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/tasks" {
			_, _ = w.Write([]byte(`{"ok":true,"docs":[]}`))
			return
		}
		mu.Lock()
		n := tick
		tick++
		nreq++
		mu.Unlock()
		events := make([]map[string]any, 0, chunk)
		for i := 0; i < chunk; i++ {
			idx := n*chunk + i
			events = append(events, map[string]any{
				"event":  "task.lease_expired",
				"doc_id": fmt.Sprintf("t-%03d", idx),
				"at":     base.Add(time.Duration(-idx) * time.Second).Format(time.RFC3339Nano),
			})
		}
		b, _ := json.Marshal(map[string]any{
			"ok": true, "counts": map[string]int{"open": 1},
			"ready": []any{}, "in_progress": []any{}, "recent_events": events,
		})
		_, _ = w.Write(b)
	}))
	defer srv.Close()

	fetch := newSnapshotFetcher()
	var snap Snapshot
	for i := 0; i < 3; i++ {
		s, _, err := fetch(newClient(srv.URL))
		if err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
		snap = s
		t.Logf("after tick %d: Snapshot.Events = %d", i, len(s.Events))
	}
	mu.Lock()
	reqs := nreq
	mu.Unlock()
	if reqs != 3 {
		t.Fatalf("prime request count = %d, want 3 — an absence below would measure nothing", reqs)
	}
	if len(snap.Events) != 15 {
		t.Errorf("Snapshot.Events after 3 brief ticks = %d, want 15 — the brief arm trims recent_events to 5 and the rolling tail is what gives computeResumables its history back", len(snap.Events))
	}
	// And the tail is newest-first, so buildEvAt / computeResumables read it the
	// way they read a server tail.
	for i := 1; i < len(snap.Events); i++ {
		if snap.Events[i].At.After(snap.Events[i-1].At) {
			t.Fatalf("event tail is not newest-first at %d: %s then %s", i, snap.Events[i-1].At, snap.Events[i].At)
		}
	}
}

// TestOneShotEventTailIsUntouched — the QUIET control. A one-shot cache must not
// sort, dedup or cap: it gets the server's own bytes back, in the server's own
// order. Reds if mergeEventTail stops short-circuiting on a non-live cache.
func TestOneShotEventTailIsUntouched(t *testing.T) {
	rec := &primeRecorder{events: 40}
	srv := rec.server(t)
	defer srv.Close()

	snap, _, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("one-shot fetch: %v", err)
	}
	if len(snap.Events) != 40 {
		t.Fatalf("one-shot Snapshot.Events = %d, want 40 (the full arm's whole tail)", len(snap.Events))
	}
	for i, e := range snap.Events {
		if want := fmt.Sprintf("t-%03d", i); e.DocID != want {
			t.Fatalf("one-shot event %d doc_id = %q, want %q — the server's order must survive verbatim", i, e.DocID, want)
		}
	}
}

// TestBriefProjectionDoesNotChangeWhatTheBoardReads — the quiet control that
// stops an arm passing by breaking the decode: brief and full bodies compose the
// SAME ready overlay and the SAME counts.
func TestBriefProjectionDoesNotChangeWhatTheBoardReads(t *testing.T) {
	rec := &primeRecorder{events: 40}
	briefExtras, err := decodePrime(rec.primeBody("brief"))
	if err != nil {
		t.Fatalf("decode brief prime: %v", err)
	}
	fullExtras, err := decodePrime(rec.primeBody(""))
	if err != nil {
		t.Fatalf("decode full prime: %v", err)
	}
	if len(briefExtras.readyIDs) == 0 {
		t.Fatalf("brief ready overlay is EMPTY — an equality below would be vacuous")
	}
	if fmt.Sprint(briefExtras.readyIDs) != fmt.Sprint(fullExtras.readyIDs) {
		t.Errorf("ready overlay differs by view: brief=%v full=%v", briefExtras.readyIDs, fullExtras.readyIDs)
	}
	if briefExtras.readyCount != fullExtras.readyCount {
		t.Errorf("readyCount differs by view: brief=%d full=%d", briefExtras.readyCount, fullExtras.readyCount)
	}
	if fmt.Sprint(briefExtras.counts) != fmt.Sprint(fullExtras.counts) {
		t.Errorf("counts differ by view: brief=%v full=%v", briefExtras.counts, fullExtras.counts)
	}
}
