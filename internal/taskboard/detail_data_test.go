package taskboard

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// detailFixtureParts splits testdata/detail_fixture.json into the list-envelope
// body ({"docs":[…]}) and the prime body, exactly as the API serves each
// endpoint. Same split as fetch_test.go's fixtureParts, over the detail fixture.
func detailFixtureParts(t *testing.T) (listBody, primeBody []byte) {
	t.Helper()
	raw, err := os.ReadFile("testdata/detail_fixture.json")
	if err != nil {
		t.Fatalf("read detail fixture: %v", err)
	}
	var f struct {
		Docs  json.RawMessage `json:"docs"`
		Prime json.RawMessage `json:"prime"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode detail fixture: %v", err)
	}
	list, err := json.Marshal(map[string]json.RawMessage{"docs": f.Docs})
	if err != nil {
		t.Fatalf("marshal list body: %v", err)
	}
	return list, f.Prime
}

// decodeDetailFixture decodes the fixture list body straight into the board
// Tasks + DetailIndex — no network, no overlay — for the pure-derivation tests
// (ChildrenOf/DrivenTasks/PaperRefs/toDetail). The FetchSnapshotFull test below
// exercises the overlay + syncDetails path over an httptest server instead.
func decodeDetailFixture(t *testing.T) ([]Task, DetailIndex) {
	t.Helper()
	listBody, _ := detailFixtureParts(t)
	tasks, details, err := decodeTaskListFull(listBody)
	if err != nil {
		t.Fatalf("decodeTaskListFull: %v", err)
	}
	return tasks, details
}

func TestDecodeTaskPurposePreservesAuthoredZeroScoreAndPlacement(t *testing.T) {
	p := decodeTaskPurpose(map[string]any{
		"part_of": "Reader trust epic",
		"impact":  "unblocks operator adoption",
		"importance": map[string]any{
			"score":  float64(0),
			"reason": "deliberately deprioritized",
		},
	})
	if p.PartOf != "Reader trust epic" || p.Impact != "unblocks operator adoption" {
		t.Fatalf("purpose placement/impact lost: %+v", p)
	}
	if !p.Importance.Set || p.Importance.Score != 0 {
		t.Fatalf("authored zero score was mistaken for missing: %+v", p.Importance)
	}
}

// detailFixtureServer serves the two task endpoints from the detail fixture so
// FetchSnapshotFull runs its real fetch+decode+overlay path.
func detailFixtureServer(t *testing.T) *httptest.Server {
	t.Helper()
	listBody, primeBody := detailFixtureParts(t)
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/tasks":
			_, _ = w.Write(listBody)
		case "/v1/tasks/prime":
			_, _ = w.Write(primeBody)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

// TestFetchSnapshotFull proves detail hydration rides the SAME two calls as the
// board fetch (zero extra network) and that syncDetails re-embeds the ready
// overlay so a detail can never contradict the board row it was opened from.
func TestFetchSnapshotFull(t *testing.T) {
	srv := detailFixtureServer(t)
	defer srv.Close()

	snap, details, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshotFull: %v", err)
	}
	if len(snap.Tasks) != 6 {
		t.Fatalf("decoded %d tasks, want 6", len(snap.Tasks))
	}
	if len(details) != 6 {
		t.Fatalf("hydrated %d details, want 6 (one per task)", len(details))
	}
	if snap.FetchedAt.IsZero() {
		t.Fatalf("FetchedAt not stamped")
	}
	if snap.Counts["in_progress"] != 2 {
		t.Fatalf("counts = %v, want in_progress:2 from prime", snap.Counts)
	}

	// The prime ready queue names drafts.cc-1 (stored open); the overlay upgrades
	// it to "ready" on the snapshot AND syncDetails carries that onto the detail.
	if got := details["drafts.cc-1"].Task.Lifecycle; got != "ready" {
		t.Fatalf("detail cc-1 lifecycle = %q, want \"ready\" (overlay must reach the detail)", got)
	}
	byID := map[string]Task{}
	for _, tk := range snap.Tasks {
		byID[tk.DocID] = tk
	}
	if got := byID["drafts.cc-1"].Lifecycle; got != "ready" {
		t.Fatalf("snapshot cc-1 lifecycle = %q, want \"ready\"", got)
	}

	// The reading fields are present on the detail, not just the board row.
	goal := details["drafts.cc-goal"]
	if goal.Description == "" || goal.DesignDoc != "cloud-console-epic-wish" {
		t.Fatalf("cc-goal detail under-hydrated: %+v", goal)
	}
}

// TestToDetailHydration reads every content field the board row drops, from the
// live-shaped envelopes, one assertion table per doc.
func TestToDetailHydration(t *testing.T) {
	_, details := decodeDetailFixture(t)

	tests := []struct {
		name  string
		docID string
		check func(t *testing.T, d TaskDetail)
	}{
		{
			name:  "goal: design+papers+criteria+evidence+coderefs",
			docID: "drafts.cc-goal",
			check: func(t *testing.T, d TaskDetail) {
				if d.Description == "" {
					t.Errorf("Description empty")
				}
				if d.Design != "One LiveView per tab, shared assign pipeline." {
					t.Errorf("Design = %q", d.Design)
				}
				if d.DesignDoc != "cloud-console-epic-wish" {
					t.Errorf("DesignDoc = %q", d.DesignDoc)
				}
				if !eq(d.Papers, []string{"cloud-console-epic-wish", "cloud-ops-notes"}) {
					t.Errorf("Papers = %v", d.Papers)
				}
				// Evidence is index-aligned with Task.CriteriaItems by construction.
				if !eq(d.Evidence, []string{"#1102", "", "deployed to guerrilla"}) {
					t.Errorf("Evidence = %v", d.Evidence)
				}
				if len(d.CriteriaItems) != len(d.Evidence) {
					t.Errorf("Evidence (%d) not aligned with CriteriaItems (%d)", len(d.Evidence), len(d.CriteriaItems))
				}
				// code_refs map -> sorted "key: value" lines; empty commits dropped.
				if !eq(d.CodeRefs, []string{
					"branch: feat/cloud-console",
					"prs: 1112, 1108",
					"worktree: /Volumes/SATECHI/github/barkpark",
				}) {
					t.Errorf("CodeRefs = %v", d.CodeRefs)
				}
				if d.Assignee != "cloud-loop" {
					t.Errorf("Assignee = %q", d.Assignee)
				}
				if !d.LastWorkedAt.Equal(mustParse(t, "2026-07-03T10:45:00Z")) {
					t.Errorf("LastWorkedAt = %v", d.LastWorkedAt)
				}
				if d.PreviousWorker != "" || !d.ClaimExpiredAt.IsZero() {
					t.Errorf("live claim leaked swept-history: prev=%q exp=%v", d.PreviousWorker, d.ClaimExpiredAt)
				}
			},
		},
		{
			name:  "swept: previous_worker + expired_at + close/resolution",
			docID: "drafts.swept-1",
			check: func(t *testing.T, d TaskDetail) {
				if d.PreviousWorker != "sheets-loop" {
					t.Errorf("PreviousWorker = %q", d.PreviousWorker)
				}
				if !d.ClaimExpiredAt.Equal(mustParse(t, "2026-07-03T08:30:00Z")) {
					t.Errorf("ClaimExpiredAt = %v", d.ClaimExpiredAt)
				}
				if d.CloseReason != "superseded by the native tabs" {
					t.Errorf("CloseReason = %q", d.CloseReason)
				}
				if d.ResolutionNote != "folded into #1102" {
					t.Errorf("ResolutionNote = %q", d.ResolutionNote)
				}
				if !d.LastWorkedAt.Equal(mustParse(t, "2026-07-03T07:30:00Z")) {
					t.Errorf("LastWorkedAt = %v", d.LastWorkedAt)
				}
			},
		},
		{
			name:  "blocked: blocked_reason surfaces",
			docID: "drafts.malformed-1",
			check: func(t *testing.T, d TaskDetail) {
				if d.BlockedReason != "waiting on the DNS token owner" {
					t.Errorf("BlockedReason = %q", d.BlockedReason)
				}
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d, ok := details[tc.docID]
			if !ok {
				t.Fatalf("no detail for %q", tc.docID)
			}
			tc.check(t, d)
		})
	}
}

// TestToDetailTolerance — the frozen contract: a malformed or absent content
// field decodes to its zero value, never an error, never a dropped task.
func TestToDetailTolerance(t *testing.T) {
	tasks, details := decodeDetailFixture(t)
	if len(tasks) != 6 {
		t.Fatalf("one odd content dropped a task: %d of 6", len(tasks))
	}

	thin := details["drafts.thin-1"]
	if thin.Description == "" {
		t.Errorf("thin task lost its description")
	}
	for _, z := range []struct {
		name string
		zero bool
	}{
		{"Design", thin.Design == ""},
		{"DesignDoc", thin.DesignDoc == ""},
		{"Papers", thin.Papers == nil},
		{"Evidence", thin.Evidence == nil},
		{"CodeRefs", thin.CodeRefs == nil},
		{"PreviousWorker", thin.PreviousWorker == ""},
		{"ClaimExpiredAt", thin.ClaimExpiredAt.IsZero()},
		{"LastWorkedAt", thin.LastWorkedAt.IsZero()},
	} {
		if !z.zero {
			t.Errorf("thin task field %s not zero-valued", z.name)
		}
	}

	// malformed-1: design_doc is a number, papers is a string, code_refs is a
	// string, last_worked_at is not a timestamp — all degrade to zero.
	mal := details["drafts.malformed-1"]
	if mal.DesignDoc != "" {
		t.Errorf("numeric design_doc should degrade to \"\", got %q", mal.DesignDoc)
	}
	if mal.Papers != nil {
		t.Errorf("non-array papers should degrade to nil, got %v", mal.Papers)
	}
	if mal.CodeRefs != nil {
		t.Errorf("string code_refs should degrade to nil, got %v", mal.CodeRefs)
	}
	if !mal.LastWorkedAt.IsZero() {
		t.Errorf("bad last_worked_at should degrade to zero, got %v", mal.LastWorkedAt)
	}
	// The malformed acceptance_criteria still yields slot-preserving evidence
	// aligned with CriteriaItems (bare-string and criterion-less entries -> "").
	if !eq(mal.Evidence, []string{"note", "", ""}) {
		t.Errorf("malformed evidence = %v, want [note, \"\", \"\"]", mal.Evidence)
	}
	if len(mal.CriteriaItems) != len(mal.Evidence) {
		t.Errorf("malformed Evidence (%d) not aligned with CriteriaItems (%d)", len(mal.Evidence), len(mal.CriteriaItems))
	}
}

// TestChildrenOf — the parent_id index, drafts.-prefix-agnostic on both sides,
// inserted_at ascending.
func TestChildrenOf(t *testing.T) {
	tasks, _ := decodeDetailFixture(t)
	tests := []struct {
		name  string
		docID string
		want  []string
	}{
		{"drafts-prefixed parent id", "drafts.cc-goal", []string{"drafts.cc-1", "drafts.cc-2"}},
		{"bare parent id matches the same children", "cc-goal", []string{"drafts.cc-1", "drafts.cc-2"}},
		{"a leaf has no children", "drafts.cc-1", nil},
		{"unknown id", "nope", nil},
		{"empty id matches nothing", "", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := docIDs(ChildrenOf(tasks, tc.docID)); !eq(got, tc.want) {
				t.Errorf("ChildrenOf(%q) = %v, want %v", tc.docID, got, tc.want)
			}
		})
	}
}

// TestDrivenTasks — snapshot inversion (design_doc==slug || slug ∈ papers[]),
// band-ordered like epic children (in_progress before open, updated desc).
func TestDrivenTasks(t *testing.T) {
	tasks, details := decodeDetailFixture(t)
	tests := []struct {
		name string
		slug string
		want []string
	}{
		{
			name: "design_doc + papers, band + recency ordered",
			slug: "cloud-console-epic-wish",
			// cc-goal (in_progress, upd 11:00) + cc-2 (in_progress, upd 10:00) then cc-1 (open, via papers[] fallback)
			want: []string{"drafts.cc-goal", "drafts.cc-2", "drafts.cc-1"},
		},
		{
			name: "drafts.-prefixed slug matches the same set",
			slug: "drafts.cloud-console-epic-wish",
			want: []string{"drafts.cc-goal", "drafts.cc-2", "drafts.cc-1"},
		},
		{
			name: "papers-only membership",
			slug: "cloud-ops-notes",
			want: []string{"drafts.cc-goal"},
		},
		{"no task names it", "ghost-paper", nil},
		{"empty slug matches nothing", "", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := docIDs(DrivenTasks(tasks, details, tc.slug)); !eq(got, tc.want) {
				t.Errorf("DrivenTasks(%q) = %v, want %v", tc.slug, got, tc.want)
			}
		})
	}
}

// TestPaperRefs — design_doc first, then papers[] in order, deduped on the bare
// slug, empties dropped.
func TestPaperRefs(t *testing.T) {
	_, details := decodeDetailFixture(t)
	tests := []struct {
		name  string
		docID string
		want  []string
	}{
		{"design_doc first, overlap deduped", "drafts.cc-goal", []string{"cloud-console-epic-wish", "cloud-ops-notes"}},
		{"design_doc only", "drafts.cc-2", []string{"cloud-console-epic-wish"}},
		{"top-level papers fallback", "drafts.cc-1", []string{"cloud-console-epic-wish"}},
		{"no paper links", "drafts.thin-1", nil},
		{"malformed refs drop to nil", "drafts.malformed-1", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := details[tc.docID].PaperRefs(); !eq(got, tc.want) {
				t.Errorf("%s PaperRefs() = %v, want %v", tc.docID, got, tc.want)
			}
		})
	}
}

// concurrentFetchServer serves the two task endpoints from the detail fixture
// behind a two-arrival barrier: each request registers, then blocks until the
// OTHER request has also arrived (or a timeout fires). A sequential fetch can
// never satisfy the barrier — its first request would wait for a second that
// the client has not yet sent — so the timeout trips and the test fails. Only
// two genuinely in-flight requests release the barrier, so a green run is proof
// the two GETs overlap.
func concurrentFetchServer(t *testing.T) *httptest.Server {
	t.Helper()
	listBody, primeBody := detailFixtureParts(t)
	var (
		mu        sync.Mutex
		remaining = 2
	)
	barrier := make(chan struct{})
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		remaining--
		if remaining == 0 {
			close(barrier)
		}
		mu.Unlock()
		select {
		case <-barrier:
		case <-time.After(2 * time.Second):
			t.Errorf("request to %s never saw a concurrent peer within 2s — the two fetches are serialized", r.URL.Path)
		}
		switch r.URL.Path {
		case "/v1/tasks":
			_, _ = w.Write(listBody)
		case "/v1/tasks/prime":
			_, _ = w.Write(primeBody)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

// TestFetchSnapshotFull_ConcurrentFetch proves the /v1/tasks and
// /v1/tasks/prime GETs run concurrently (charter D113b): the stub server only
// answers once BOTH requests are in flight, so the fetch completing at all —
// with both results composed into the snapshot — requires overlap.
func TestFetchSnapshotFull_ConcurrentFetch(t *testing.T) {
	srv := concurrentFetchServer(t)
	defer srv.Close()

	snap, details, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshotFull under the concurrency barrier: %v", err)
	}
	// composeSnapshot received the list result...
	if len(snap.Tasks) != 6 {
		t.Fatalf("decoded %d tasks, want 6 (list result must reach composeSnapshot)", len(snap.Tasks))
	}
	if len(details) != 6 {
		t.Fatalf("hydrated %d details, want 6", len(details))
	}
	// ...and the prime result (counts + the ready overlay).
	if snap.Counts["in_progress"] != 2 {
		t.Fatalf("counts = %v, want in_progress:2 (prime result must reach composeSnapshot)", snap.Counts)
	}
	if got := snap.Tasks; got == nil {
		t.Fatal("nil tasks")
	}
	byID := map[string]Task{}
	for _, tk := range snap.Tasks {
		byID[tk.DocID] = tk
	}
	if got := byID["drafts.cc-1"].Lifecycle; got != "ready" {
		t.Fatalf("cc-1 lifecycle = %q, want \"ready\" (prime ready overlay applied)", got)
	}
}

// TestFetchSnapshotFull_EitherErrorNoPartial proves the failure contract is
// unchanged by the concurrent fetch: an error from EITHER endpoint yields the
// same honest degraded outcome — a nil error is never returned, and the
// snapshot/details are the zero value (no partial board) — INCLUDING when the
// other endpoint succeeds.
func TestFetchSnapshotFull_EitherErrorNoPartial(t *testing.T) {
	listBody, primeBody := detailFixtureParts(t)
	cases := []struct {
		name            string
		listOK, primeOK bool
		wantInErr       string
	}{
		{"list fails, prime succeeds", false, true, "/v1/tasks"},
		{"prime fails, list succeeds", true, false, "/v1/tasks/prime"},
		{"both fail — list error takes precedence", false, false, "/v1/tasks"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/v1/tasks":
					if tc.listOK {
						_, _ = w.Write(listBody)
					} else {
						w.WriteHeader(http.StatusInternalServerError)
						_, _ = w.Write([]byte(`{"error":"list boom"}`))
					}
				case "/v1/tasks/prime":
					if tc.primeOK {
						_, _ = w.Write(primeBody)
					} else {
						w.WriteHeader(http.StatusInternalServerError)
						_, _ = w.Write([]byte(`{"error":"prime boom"}`))
					}
				default:
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer srv.Close()

			snap, details, err := FetchSnapshotFull(newClient(srv.URL))
			if err == nil {
				t.Fatalf("expected an error when an endpoint fails, got nil")
			}
			if !strings.Contains(err.Error(), tc.wantInErr) || !strings.Contains(err.Error(), "status 500") {
				t.Fatalf("error %q should name %q and the 500 status", err, tc.wantInErr)
			}
			// No partial snapshot: both must be the zero value.
			if len(snap.Tasks) != 0 || snap.Counts != nil || !snap.FetchedAt.IsZero() {
				t.Fatalf("degraded fetch returned a partial snapshot: %+v", snap)
			}
			if details != nil {
				t.Fatalf("degraded fetch returned partial details: %+v", details)
			}
		})
	}
}
