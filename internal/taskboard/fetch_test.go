package taskboard

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// fixtureParts splits the shared fixture into the list-envelope body
// ({"ok":true,"docs":[…]}) and the prime body, so the httptest server can serve
// each endpoint exactly as the API does.
func fixtureParts(t *testing.T) (listBody, primeBody []byte) {
	t.Helper()
	raw, err := os.ReadFile("testdata/tasks_fixture.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f struct {
		Docs  json.RawMessage `json:"docs"`
		Prime json.RawMessage `json:"prime"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	list, err := json.Marshal(map[string]json.RawMessage{"docs": f.Docs})
	if err != nil {
		t.Fatalf("marshal list body: %v", err)
	}
	return list, f.Prime
}

// fixtureServer serves the two task endpoints from the fixture. A per-path
// status override lets a test force an error on just one endpoint.
func fixtureServer(t *testing.T, listStatus, primeStatus int) *httptest.Server {
	t.Helper()
	listBody, primeBody := fixtureParts(t)
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("%s request missing bearer token", r.URL.Path)
		}
		switch r.URL.Path {
		case "/v1/tasks":
			w.WriteHeader(listStatus)
			if listStatus == http.StatusOK {
				_, _ = w.Write(listBody)
			} else {
				_, _ = w.Write([]byte(`{"error":"list boom"}`))
			}
		case "/v1/tasks/prime":
			// The overlay wants the deepest ready head one call allows.
			if got := r.URL.Query().Get("limit"); got != "100" {
				t.Errorf("prime request limit = %q, want \"100\"", got)
			}
			w.WriteHeader(primeStatus)
			if primeStatus == http.StatusOK {
				_, _ = w.Write(primeBody)
			} else {
				_, _ = w.Write([]byte(`{"error":"prime boom"}`))
			}
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func newClient(baseURL string) *apiclient.Client {
	return apiclient.New(apiclient.Config{BaseURL: baseURL, Token: "test-token"})
}

func TestFetchSnapshot(t *testing.T) {
	srv := fixtureServer(t, http.StatusOK, http.StatusOK)
	defer srv.Close()

	snap, err := FetchSnapshot(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshot: %v", err)
	}
	if len(snap.Tasks) != 21 {
		t.Fatalf("decoded %d tasks, want 21", len(snap.Tasks))
	}
	if snap.Counts["in_progress"] != 5 {
		t.Fatalf("counts = %v, want in_progress:5", snap.Counts)
	}
	if len(snap.Events) != 2 {
		t.Fatalf("events = %d, want 2", len(snap.Events))
	}
	if snap.FetchedAt.IsZero() {
		t.Fatalf("FetchedAt not stamped")
	}

	// Spot-check the envelope decode: t1 carries a live claim + criteria; the
	// composed snapshot must build into a coherent board.
	byID := map[string]Task{}
	for _, tk := range snap.Tasks {
		byID[tk.DocID] = tk
	}
	t1 := byID["t1"]
	if t1.Claim == nil || t1.Claim.Worker != "opus-3" || t1.Claim.Epoch != 4 {
		t.Fatalf("t1 claim = %+v, want worker opus-3 epoch 4", t1.Claim)
	}
	if t1.Claim.ClaimedAt != mustParse(t, "2026-07-03T11:00:00Z") {
		t.Fatalf("t1 claim time = %v, want ts_iso value", t1.Claim.ClaimedAt)
	}
	if t1.Criteria == nil || t1.Criteria.Total != 3 {
		t.Fatalf("t1 criteria = %+v, want {2 3}", t1.Criteria)
	}
	if got := t1.Priority; got != "2" {
		t.Fatalf("t1 priority = %q, want \"2\" (int coerced)", got)
	}

	// Derived readiness rides prime.ready onto the composed snapshot: t2 is
	// STORED "open" on the wire (the server never stores "ready") but lands
	// here as ready because prime's queue names it.
	if got := byID["t2"].Lifecycle; got != "ready" {
		t.Fatalf("t2 lifecycle = %q, want \"ready\" (prime overlay)", got)
	}
	if got := byID["t4"].Lifecycle; got != "open" {
		t.Fatalf("t4 lifecycle = %q, want \"open\" (not in prime.ready)", got)
	}

	b := BuildBoard(snap, RepoContext{}, refNow)
	if got := docIDs(b.Now); !eq(got, []string{"t9", "t1"}) {
		t.Fatalf("board NOW off the fetched snapshot = %v", got)
	}
}

// TestFetchSnapshot_ListError — a failing list endpoint fails the fetch with an
// error naming the path, the status AND the server's reason, so the shell's
// degraded banner is actionable rather than a bare "error".
func TestFetchSnapshot_ListError(t *testing.T) {
	srv := fixtureServer(t, http.StatusInternalServerError, http.StatusOK)
	defer srv.Close()
	_, err := FetchSnapshot(newClient(srv.URL))
	if err == nil {
		t.Fatalf("expected error when the list endpoint fails")
	}
	for _, want := range []string{"/v1/tasks", "status 500", "list boom"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("list error %q should contain %q", err, want)
		}
	}
}

func TestFetchSnapshot_PrimeError(t *testing.T) {
	srv := fixtureServer(t, http.StatusOK, http.StatusInternalServerError)
	defer srv.Close()
	_, err := FetchSnapshot(newClient(srv.URL))
	if err == nil {
		t.Fatalf("expected error when the prime endpoint fails")
	}
	for _, want := range []string{"/v1/tasks/prime", "status 500", "prime boom"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("prime error %q should contain %q", err, want)
		}
	}
}

// TestComposeSnapshot_ReadyOverlay — the overlay upgrades ONLY stored
// open|blocked tasks named by prime's ready queue. A row that moved between
// the two fetches (claimed -> in_progress, closed -> done) keeps its stored
// lifecycle, and a ready id absent from the list is ignored.
func TestComposeSnapshot_ReadyOverlay(t *testing.T) {
	tasks := []Task{
		{DocID: "a", Lifecycle: lifeOpen},
		{DocID: "b", Lifecycle: lifeBlocked},
		{DocID: "c", Lifecycle: lifeInProgress},
		{DocID: "d", Lifecycle: lifeDone},
		{DocID: "e", Lifecycle: lifeOpen},
	}
	extras := primeExtras{readyIDs: map[string]bool{"a": true, "b": true, "c": true, "d": true, "zz": true}}
	snap := composeSnapshot(tasks, extras, refNow)

	want := map[string]string{
		"a": lifeReady,      // open + ready -> ready
		"b": lifeReady,      // blocked with satisfied deps is claimable -> ready
		"c": lifeInProgress, // claimed between the fetches: stored truth wins
		"d": lifeDone,       // terminal: stored truth wins
		"e": lifeOpen,       // not in the ready queue
	}
	for _, tk := range snap.Tasks {
		if tk.Lifecycle != want[tk.DocID] {
			t.Errorf("%s lifecycle = %q, want %q", tk.DocID, tk.Lifecycle, want[tk.DocID])
		}
	}
	if snap.FetchedAt != refNow {
		t.Fatalf("FetchedAt = %v, want %v", snap.FetchedAt, refNow)
	}
}

// TestComposeSnapshot_ReadyHeadClamp — a prime ready head that comes back at the
// clamp maximum flags the snapshot as clamped (the overlay is honest-but-partial
// beyond the top of the queue); a shorter head does not.
func TestComposeSnapshot_ReadyHeadClamp(t *testing.T) {
	// composeSnapshot flags the clamp off extras.readyCount (the on-the-wire
	// count), independent of the deduped readyIDs map.
	mkExtras := func(n int) primeExtras {
		return primeExtras{readyIDs: map[string]bool{}, readyCount: n}
	}
	cases := []struct {
		name        string
		readyCount  int
		wantClamped bool
	}{
		{"short head is unclamped", 49, false},
		{"one under the clamp", primeReadyLimit - 1, false},
		{"exactly the clamp is clamped", primeReadyLimit, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			snap := composeSnapshot(nil, mkExtras(tc.readyCount), refNow)
			if snap.ReadyHeadClamped != tc.wantClamped {
				t.Fatalf("readyCount=%d -> ReadyHeadClamped=%v, want %v",
					tc.readyCount, snap.ReadyHeadClamped, tc.wantClamped)
			}
		})
	}
}

// TestFetchSnapshot_ReadyHeadNotClamped — the shared fixture's short ready head
// (4 rows) leaves the composed snapshot unclamped through the real fetch path.
func TestFetchSnapshot_ReadyHeadNotClamped(t *testing.T) {
	srv := fixtureServer(t, http.StatusOK, http.StatusOK)
	defer srv.Close()
	snap, err := FetchSnapshot(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshot: %v", err)
	}
	if snap.ReadyHeadClamped {
		t.Fatalf("ReadyHeadClamped = true on a 4-row ready head, want false")
	}
}

func TestBodyHint(t *testing.T) {
	cases := []struct{ in, want string }{
		{``, ""},
		{`  `, ""},
		{`{"error":"unauthorized"}`, `: {"error":"unauthorized"}`},
		{"line one\n  line two", ": line one line two"},
		{strings.Repeat("x", 200), ": " + strings.Repeat("x", 120) + "…"},
	}
	for _, tc := range cases {
		if got := bodyHint([]byte(tc.in)); got != tc.want {
			t.Errorf("bodyHint(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestDecodeExpiredClaim — a swept lease (worker null, epoch retained) decodes
// to a NON-nil Claim with an empty worker, which is what lets BuildBoard tell
// an expired claim from a live one.
func TestDecodeExpiredClaim(t *testing.T) {
	body := []byte(`{"docs":[{"doc_id":"x","lifecycle_status":"open",
		"claim":{"worker":null,"epoch":3,"ts_iso":"2026-07-01T12:00:00Z"}}]}`)
	tasks, err := decodeTaskList(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	c := tasks[0].Claim
	if c == nil || c.Worker != "" || c.Epoch != 3 {
		t.Fatalf("expired claim = %+v, want non-nil worker=\"\" epoch=3", c)
	}
}

// TestDecodeClaimedAtFallback — a claim timestamp under the friendlier
// "claimed_at" key is honoured when "ts_iso" is absent.
func TestDecodeClaimedAtFallback(t *testing.T) {
	body := []byte(`{"docs":[{"doc_id":"x","claim":{"worker":"w","epoch":1,"claimed_at":"2026-07-03T09:00:00Z"}}]}`)
	tasks, err := decodeTaskList(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got := tasks[0].Claim.ClaimedAt; got != mustParse(t, "2026-07-03T09:00:00Z") {
		t.Fatalf("claimed_at fallback = %v", got)
	}
}

func TestCoercePriority(t *testing.T) {
	cases := []struct{ in, want string }{
		{`2`, "2"},
		{`"high"`, "high"},
		{`null`, ""},
		{``, ""},
		{`   `, ""},
		{`0`, "0"},
	}
	for _, tc := range cases {
		if got := coercePriority([]byte(tc.in)); got != tc.want {
			t.Errorf("coercePriority(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
