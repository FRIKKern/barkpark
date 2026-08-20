package taskboard

// now_truth_test.go — the D115/D120 collapsed-truth contract: the NOW band and
// the in-flight count derive from the deduped union of the window list and the
// lifecycle-filtered in-flight fetch, never from raw prime lifecycle_counts
// (twin-doubled: prime has no collapse_twins while /v1/tasks collapses, so a
// lifecycle-divergent twin — published done, draft in_progress — counts twice)
// and never from the window alone (a 1000-row clamp can drop a claimed row).
//
// Twin divergence is SYNTHESIZED throughout: the live prime-vs-union delta is
// 0 today, so a live inequality assert would be vacuously green.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// nowTruthServer serves the three snapshot legs with independently scripted
// bodies/failures. The two list legs share the /v1/tasks path and are told
// apart by the lifecycle_status query — exactly how the API reads them.
func nowTruthServer(t *testing.T, windowBody, inflightBody, primeBody string, failWindow, failInflight, failPrime bool) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/tasks" && r.URL.Query().Get("lifecycle_status") == "in_progress":
			if got := r.URL.Query().Get("limit"); got != "1000" {
				t.Errorf("in-flight leg limit = %q, want \"1000\"", got)
			}
			if failInflight {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":"inflight boom"}`))
				return
			}
			_, _ = w.Write([]byte(inflightBody))
		case r.URL.Path == "/v1/tasks":
			if got := r.URL.Query().Get("limit"); got != "1000" {
				t.Errorf("window leg limit = %q, want \"1000\"", got)
			}
			if failWindow {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":"list boom"}`))
				return
			}
			_, _ = w.Write([]byte(windowBody))
		case r.URL.Path == "/v1/tasks/prime":
			if failPrime {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":"prime boom"}`))
				return
			}
			_, _ = w.Write([]byte(primeBody))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// The synthesized twin-divergent corpus:
//
//   - "visible" — in_progress, claimed, present in BOTH legs (the dedup case).
//   - "moved"   — done in the window, in_progress in the filtered leg (fetch
//     timing: it closed between the two GETs). List wins, so it must NOT
//     count in flight and must NOT enter NOW.
//   - "plain"   — open, window only.
//   - "hidden"  — in_progress, claimed, ABSENT from the window (the clamp
//     casualty the union rescues into NOW, detail included).
//
// Prime's in_progress bucket says 4 — twin-doubled (D115) — while the deduped
// union holds exactly 2 in-flight rows (visible + hidden).
const (
	nowTruthWindowBody = `{"ok":true,"docs":[
		{"doc_id":"visible","title":"Visible claim","kind":"task","lifecycle_status":"in_progress",
		 "claim":{"worker":"wA","epoch":1,"ts_iso":"2026-07-03T11:00:00Z"},
		 "inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-03T11:30:00Z"},
		{"doc_id":"moved","title":"Closed between the fetches","kind":"task","lifecycle_status":"done",
		 "inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-03T11:45:00Z"},
		{"doc_id":"plain","title":"Open row","kind":"task","lifecycle_status":"open",
		 "inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-03T10:00:00Z"}
	]}`
	nowTruthInflightBody = `{"ok":true,"docs":[
		{"doc_id":"visible","title":"Visible claim (stale copy)","kind":"task","lifecycle_status":"in_progress",
		 "claim":{"worker":"wA","epoch":1,"ts_iso":"2026-07-03T11:00:00Z"},
		 "inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-03T11:29:00Z"},
		{"doc_id":"moved","title":"Stale in-flight copy","kind":"task","lifecycle_status":"in_progress",
		 "claim":{"worker":"wC","epoch":2,"ts_iso":"2026-07-03T11:10:00Z"},
		 "inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-03T11:20:00Z"},
		{"doc_id":"hidden","title":"Clamp casualty","kind":"task","lifecycle_status":"in_progress",
		 "claim":{"worker":"wB","epoch":3,"ts_iso":"2026-07-03T11:15:00Z"},
		 "content":{"description":"rescued at full depth"},
		 "inserted_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-03T11:40:00Z"}
	]}`
	nowTruthPrimeBody = `{"ok":true,"counts":{"in_progress":4,"open":1,"done":1},"recent_events":[],"ready":[]}`
)

// TestNowCompleteness_UnionRescuesWindowAbsentRow — the headline D120 proof:
// an in_progress row absent from the 1000-row window still lands in board.Now
// (with its full-depth detail), the window copy wins on overlap, and the
// in-flight count collapses to the union truth — never prime's twin-doubled 4,
// never the filtered leg's raw length 3.
func TestNowCompleteness_UnionRescuesWindowAbsentRow(t *testing.T) {
	srv := nowTruthServer(t, nowTruthWindowBody, nowTruthInflightBody, nowTruthPrimeBody, false, false, false)

	snap, details, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshotFull: %v", err)
	}
	if len(snap.Tasks) != 4 {
		t.Fatalf("union = %d tasks %v, want 4 (visible, moved, plain, hidden)", len(snap.Tasks), docIDs(snap.Tasks))
	}
	byID := map[string]Task{}
	for _, tk := range snap.Tasks {
		byID[tk.DocID] = tk
	}
	// LIST copy wins on overlap: "moved" keeps its window lifecycle (done) and
	// window title, not the stale in-flight copy's.
	if got := byID["moved"]; got.Lifecycle != lifeDone || got.Title != "Closed between the fetches" {
		t.Fatalf("moved = %q/%q, want the window copy (done) to win over the stale in-flight copy", got.Lifecycle, got.Title)
	}
	if got := byID["visible"]; got.Title != "Visible claim" {
		t.Fatalf("visible title = %q, want the window copy to win", got.Title)
	}
	// The collapsed denominator: 2 (visible + hidden). Prime said 4 (twin-
	// doubled); the filtered leg carried 3 rows (one stale). Both wrong
	// denominators must lose.
	if got := snap.Counts["in_progress"]; got != 2 {
		t.Fatalf("Counts[in_progress] = %d, want 2 (union truth; prime said 4, filtered leg had 3 rows)", got)
	}
	// Only the in_progress bucket collapses — done/open stay prime-raw until
	// the api twin fix (ttw20-bl-prime-counts-collapse-twins).
	if snap.Counts["open"] != 1 || snap.Counts["done"] != 1 {
		t.Fatalf("non-in_progress buckets changed: %v, want open:1 done:1 prime-raw", snap.Counts)
	}

	// NOW-completeness: the window-absent claimed row is on the board.
	b := BuildBoard(snap, RepoContext{}, refNow)
	now := docIDs(b.Now)
	if !containsID(now, "hidden") || !containsID(now, "visible") {
		t.Fatalf("board.Now = %v, want both hidden (union-rescued) and visible", now)
	}
	if containsID(now, "moved") {
		t.Fatalf("board.Now = %v — the stale in-flight copy of a done row leaked into NOW", now)
	}

	// The rescued row opens at full depth: its detail hydrated off the
	// in-flight leg's envelope, not the thin-frame fallback.
	d, ok := details["hidden"]
	if !ok {
		t.Fatalf("details lack the union-rescued row; thin-frame fallback would be the plan, not the safety net")
	}
	if d.Description != "rescued at full depth" {
		t.Fatalf("hidden detail description = %q, want the in-flight envelope's content hydrated", d.Description)
	}
	if d.Task.Lifecycle != lifeInProgress {
		t.Fatalf("hidden detail lifecycle = %q, want in_progress (syncDetails must cover union rows)", d.Task.Lifecycle)
	}
}

// TestInflightEmptyEnvelopeDegradesToWindowTruth — {"docs":[]} on the filtered
// leg is a legitimate empty population (or a filter-drift 200-empty), never an
// error: the count degrades to window truth, still ignoring prime's raw bucket.
func TestInflightEmptyEnvelopeDegradesToWindowTruth(t *testing.T) {
	srv := nowTruthServer(t, nowTruthWindowBody, `{"ok":true,"docs":[]}`, nowTruthPrimeBody, false, false, false)

	snap, _, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshotFull with an empty in-flight envelope: %v", err)
	}
	if len(snap.Tasks) != 3 {
		t.Fatalf("tasks = %d, want the 3 window rows", len(snap.Tasks))
	}
	if got := snap.Counts["in_progress"]; got != 1 {
		t.Fatalf("Counts[in_progress] = %d, want 1 (window truth: visible), never prime's 4", got)
	}
}

// TestInflightFetchRequired — the D120 all-three-required contract: best-effort
// was rejected because a silently dropped in-flight leg would repaint the
// proven-liar prime count. A failing filtered leg fails the snapshot whole
// (zero partials), and error precedence is list > prime > inflight.
func TestInflightFetchRequired(t *testing.T) {
	cases := []struct {
		name                                string
		failWindow, failInflight, failPrime bool
		wantInErr                           string
	}{
		{"inflight fails alone", false, true, false, "inflight boom"},
		{"list precedence over inflight", true, true, false, "list boom"},
		{"prime precedence over inflight", false, true, true, "prime boom"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := nowTruthServer(t, nowTruthWindowBody, nowTruthInflightBody, nowTruthPrimeBody,
				tc.failWindow, tc.failInflight, tc.failPrime)
			snap, details, err := FetchSnapshotFull(newClient(srv.URL))
			if err == nil {
				t.Fatalf("expected an error, got a snapshot with %d tasks", len(snap.Tasks))
			}
			if !strings.Contains(err.Error(), tc.wantInErr) {
				t.Fatalf("error %q should carry %q (precedence list > prime > inflight)", err, tc.wantInErr)
			}
			if tc.name == "inflight fails alone" && !strings.Contains(err.Error(), "lifecycle_status=in_progress") {
				t.Fatalf("error %q should name the in-flight path so the degraded banner says WHICH call failed", err)
			}
			if len(snap.Tasks) != 0 || snap.Counts != nil || details != nil {
				t.Fatalf("degraded fetch returned a partial snapshot: %+v / %+v", snap, details)
			}
		})
	}
}

// TestMergeInflight — the pure union/dedup mechanics, straight on the helper.
func TestMergeInflight(t *testing.T) {
	window := []Task{
		{DocID: "a", Title: "window-a", Lifecycle: lifeDone},
		{DocID: "b", Title: "window-b", Lifecycle: lifeInProgress},
	}
	inflight := []Task{
		{DocID: "a", Title: "stale-a", Lifecycle: lifeInProgress}, // overlap: list wins
		{DocID: "c", Title: "union-c", Lifecycle: lifeInProgress}, // union-only
		{DocID: "c", Title: "dup-c", Lifecycle: lifeInProgress},   // duplicate within the leg
	}
	windowDetails := DetailIndex{
		"a": {Description: "window detail"},
	}
	inflightDetails := DetailIndex{
		"a": {Description: "stale detail"},
		"c": {Description: "union detail"},
	}

	tasks, details := mergeInflight(window, windowDetails, inflight, inflightDetails)
	if got := docIDs(tasks); !eq(got, []string{"a", "b", "c"}) {
		t.Fatalf("union order = %v, want window rows first then union-only appended", got)
	}
	if tasks[0].Title != "window-a" || tasks[0].Lifecycle != lifeDone {
		t.Fatalf("overlap = %q/%q, want the LIST copy to win", tasks[0].Title, tasks[0].Lifecycle)
	}
	if details["a"].Description != "window detail" {
		t.Fatalf("detail overlap = %q, want the list detail to win", details["a"].Description)
	}
	if details["c"].Description != "union detail" {
		t.Fatalf("union-only detail = %q, want the in-flight detail merged in", details["c"].Description)
	}
	if got := countInProgress(tasks); got != 2 {
		t.Fatalf("countInProgress(union) = %d, want 2 (b + c; the stale copy of a must not count)", got)
	}

	// A nil window detail index still carries the in-flight details out.
	_, d2 := mergeInflight(nil, nil, inflight, inflightDetails)
	if d2["c"].Description != "union detail" {
		t.Fatalf("nil-window merge dropped the in-flight details: %+v", d2)
	}
}

// TestThreeFetchesOverlap — the D113b concurrency contract extended to the
// third leg: the stub only answers once ALL THREE requests are in flight, so
// completing at all requires the window, prime and in-flight GETs to overlap.
func TestThreeFetchesOverlap(t *testing.T) {
	var (
		mu        sync.Mutex
		remaining = 3
	)
	barrier := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		remaining--
		if remaining == 0 {
			close(barrier)
		}
		mu.Unlock()
		select {
		case <-barrier:
		case <-time.After(2 * time.Second):
			t.Errorf("request to %s?%s never saw two concurrent peers within 2s — a leg is serialized", r.URL.Path, r.URL.RawQuery)
		}
		switch {
		case r.URL.Path == "/v1/tasks" && r.URL.Query().Get("lifecycle_status") == "in_progress":
			_, _ = w.Write([]byte(nowTruthInflightBody))
		case r.URL.Path == "/v1/tasks":
			_, _ = w.Write([]byte(nowTruthWindowBody))
		case r.URL.Path == "/v1/tasks/prime":
			_, _ = w.Write([]byte(nowTruthPrimeBody))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)

	snap, _, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshotFull under the three-way barrier: %v", err)
	}
	if len(snap.Tasks) != 4 || snap.Counts["in_progress"] != 2 {
		t.Fatalf("barrier fetch composed %d tasks / in_progress %d, want 4 / 2", len(snap.Tasks), snap.Counts["in_progress"])
	}
}

func containsID(ids []string, want string) bool {
	for _, id := range ids {
		if id == want {
			return true
		}
	}
	return false
}
