package taskboard

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
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
		switch r.URL.Path {
		case "/v1/tasks":
			if r.Header.Get("Authorization") == "" {
				t.Errorf("list request missing bearer token")
			}
			w.WriteHeader(listStatus)
			if listStatus == http.StatusOK {
				_, _ = w.Write(listBody)
			}
		case "/v1/tasks/prime":
			w.WriteHeader(primeStatus)
			if primeStatus == http.StatusOK {
				_, _ = w.Write(primeBody)
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
	if snap.Counts["in_progress"] != 3 {
		t.Fatalf("counts = %v, want in_progress:3", snap.Counts)
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

	b := BuildBoard(snap, RepoContext{}, refNow)
	if got := docIDs(b.Now); !eq(got, []string{"t9", "t1"}) {
		t.Fatalf("board NOW off the fetched snapshot = %v", got)
	}
}

func TestFetchSnapshot_ListError(t *testing.T) {
	srv := fixtureServer(t, http.StatusInternalServerError, http.StatusOK)
	defer srv.Close()
	if _, err := FetchSnapshot(newClient(srv.URL)); err == nil {
		t.Fatalf("expected error when the list endpoint fails")
	}
}

func TestFetchSnapshot_PrimeError(t *testing.T) {
	srv := fixtureServer(t, http.StatusOK, http.StatusInternalServerError)
	defer srv.Close()
	if _, err := FetchSnapshot(newClient(srv.URL)); err == nil {
		t.Fatalf("expected error when the prime endpoint fails")
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
