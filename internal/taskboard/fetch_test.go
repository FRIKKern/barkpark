package taskboard

import (
	"bytes"
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
			// Serves BOTH list legs — the window fetch and the D120 in-flight
			// fetch (?lifecycle_status=in_progress) — with the SAME full body,
			// deliberately simulating an older server that ignores the filter:
			// the union dedup must keep the composed snapshot identical (the
			// fixture's prime in_progress count matches its corpus, so the
			// collapsed recount is invariant here). The filter-honoring path is
			// exercised by now_truth_test.go's own server.
			if got := r.URL.Query().Get("limit"); got != "1000" {
				t.Errorf("%s request limit = %q, want \"1000\"", r.URL.RawQuery, got)
			}
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
	// The checklist TEXT decodes off content.acceptance_criteria: two titled met
	// entries plus one malformed (non-map) entry that keeps its slot as unmet with
	// empty text, so len(CriteriaItems) tracks criteria_progress.total exactly.
	if len(t1.CriteriaItems) != t1.Criteria.Total {
		t.Fatalf("t1 CriteriaItems = %d, want %d (== criteria_progress.total)",
			len(t1.CriteriaItems), t1.Criteria.Total)
	}
	if got := t1.CriteriaItems[0]; got.Criterion != "Ready overlay decodes onto the composed snapshot" || !got.Met {
		t.Fatalf("t1 criterion[0] = %+v, want the first met item", got)
	}
	if got := t1.CriteriaItems[2]; got.Criterion != "" || got.Met {
		t.Fatalf("t1 criterion[2] = %+v, want the malformed slot unmet+empty", got)
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

func TestGetJSONRetriesTransientServerFailure(t *testing.T) {
	attempts := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts++
		if attempts < snapshotFetchAttempts {
			http.Error(w, `{"error":{"code":"internal_error"}}`, http.StatusInternalServerError)
			return
		}
		_, _ = w.Write([]byte(`{"ok":true,"docs":[]}`))
	}))
	defer srv.Close()

	body, err := getJSON(newClient(srv.URL), "/v1/tasks?limit=1000")
	if err != nil {
		t.Fatalf("transient 500s did not recover: %v", err)
	}
	if attempts != snapshotFetchAttempts {
		t.Fatalf("attempts = %d, want %d", attempts, snapshotFetchAttempts)
	}
	if !strings.Contains(string(body), `"docs":[]`) {
		t.Fatalf("recovered body = %q", body)
	}
}

func TestGetJSONDoesNotRetryClientFailure(t *testing.T) {
	attempts := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts++
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}))
	defer srv.Close()

	_, err := getJSON(newClient(srv.URL), "/v1/tasks?limit=1000")
	if err == nil || !strings.Contains(err.Error(), "status 401") {
		t.Fatalf("client failure = %v, want status 401", err)
	}
	if attempts != 1 {
		t.Fatalf("401 attempts = %d, want 1", attempts)
	}
}

// TestFetchSnapshot_CorpusPastManifestCap — the 2026-07-24 incident: the
// guerrilla corpus crossed apiclient's 8 MiB manifest cap and the board went
// dark. The board's fetch now carries its own maxBoardFetchBytes bound, so a
// list body past 8 MiB (padded with trailing whitespace, which json.Unmarshal
// tolerates) must decode fine.
func TestFetchSnapshot_CorpusPastManifestCap(t *testing.T) {
	listBody, primeBody := fixtureParts(t)
	pad := bytes.Repeat([]byte(" "), (9<<20)-len(listBody)) // total > 8 MiB
	bigList := append(append([]byte{}, listBody...), pad...)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/tasks":
			_, _ = w.Write(bigList)
		case "/v1/tasks/prime":
			_, _ = w.Write(primeBody)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	snap, err := FetchSnapshot(newClient(srv.URL))
	if err != nil {
		t.Fatalf("a corpus past the 8 MiB manifest cap must fetch under the board's own bound, got: %v", err)
	}
	if len(snap.Tasks) == 0 {
		t.Fatal("padded corpus decoded to zero tasks")
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

// The live corpus crossed the capabilities manifest's unrelated 8 MiB ceiling
// in July 2026. Pin the taskboard seam itself so it cannot silently drift back
// to Client.GetConditional and reproduce the permanent offline state.
func TestGetJSONAcceptsTaskSnapshotAboveManifestLimit(t *testing.T) {
	const payloadBytes = (8 << 20) + 1
	body := strings.Repeat(" ", payloadBytes)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	got, err := getJSON(newClient(srv.URL), "/v1/tasks?limit=1000")
	if err != nil {
		t.Fatalf("task snapshot above 8 MiB was rejected: %v", err)
	}
	if len(got) != payloadBytes {
		t.Fatalf("task snapshot bytes = %d, want %d", len(got), payloadBytes)
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

// TestDecodeAcceptanceCriteria pins the checklist decode to the server's
// tolerance contract (api/lib/barkpark/tasks/criteria.ex met?/1): "met" counts
// ONLY when it is EXACTLY boolean true; a missing/"yes"/1 met is unmet; a
// non-map entry (bare string/number/null) or a map without "criterion" keeps
// its slot with empty text — so the decoded length always tracks the total.
func TestDecodeAcceptanceCriteria(t *testing.T) {
	body := []byte(`{"docs":[{"doc_id":"x","content":{"acceptance_criteria":[
		{"criterion":"A","met":true},
		{"criterion":"B","met":false},
		{"criterion":"C"},
		{"criterion":"D","met":"yes"},
		{"criterion":"E","met":1},
		{"met":true},
		"loose non-map entry",
		42,
		null
	]}}]}`)
	tasks, err := decodeTaskList(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	got := tasks[0].CriteriaItems
	want := []CriterionItem{
		{Criterion: "A", Met: true},  // exactly true -> met
		{Criterion: "B", Met: false}, // false -> unmet
		{Criterion: "C", Met: false}, // missing met -> unmet
		{Criterion: "D", Met: false}, // "yes" is not boolean true -> unmet
		{Criterion: "E", Met: false}, // 1 is not boolean true -> unmet
		{Criterion: "", Met: true},   // met true but no criterion text
		{Criterion: "", Met: false},  // non-map string entry keeps its slot
		{Criterion: "", Met: false},  // non-map number entry keeps its slot
		{Criterion: "", Met: false},  // null entry keeps its slot
	}
	if len(got) != len(want) {
		t.Fatalf("decoded %d items, want %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i].Criterion != want[i].Criterion || got[i].Met != want[i].Met {
			t.Errorf("item[%d] = %+v, want %+v", i, got[i], want[i])
		}
		if got[i].Attempts != nil {
			t.Errorf("item[%d] decoded attempts from nothing: %+v", i, got[i].Attempts)
		}
	}
}

// TestDecodeCriterionAttempts pins the D8 attempts[] decode: well-formed
// {note,ts,worker} entries land as the honest-miss trail (Missed() true on an
// unmet criterion), a met criterion is never "missed" whatever its trail, and
// junk — a non-list attempts, non-map entries, an all-junk list — decodes to
// nothing so garbage can never fake a recorded miss.
func TestDecodeCriterionAttempts(t *testing.T) {
	body := []byte(`{"docs":[{"doc_id":"x","content":{"acceptance_criteria":[
		{"criterion":"A","met":false,"attempts":[
			{"note":"gate red: TestFoo","ts":"2026-07-10T10:00:00Z","worker":"opus-1"},
			{"note":"still red","worker":"opus-1"},
			"junk-entry",
			42
		]},
		{"criterion":"B","met":true,"attempts":[{"note":"early miss","worker":"w"}]},
		{"criterion":"C","met":false,"attempts":"not-a-list"},
		{"criterion":"D","met":false,"attempts":["junk",7,null]}
	]}}]}`)
	tasks, err := decodeTaskList(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	items := tasks[0].CriteriaItems
	if len(items) != 4 {
		t.Fatalf("decoded %d items, want 4", len(items))
	}
	a := items[0]
	if len(a.Attempts) != 2 {
		t.Fatalf("A attempts = %+v, want the 2 map entries (junk skipped)", a.Attempts)
	}
	if a.Attempts[0].Note != "gate red: TestFoo" || a.Attempts[0].Worker != "opus-1" ||
		a.Attempts[0].At != mustParse(t, "2026-07-10T10:00:00Z") {
		t.Errorf("A attempt[0] = %+v", a.Attempts[0])
	}
	if !a.Attempts[1].At.IsZero() {
		t.Errorf("A attempt[1] missing ts should decode to zero time, got %v", a.Attempts[1].At)
	}
	if !a.Missed() {
		t.Errorf("A (unmet + attempts) should read as Missed")
	}
	if items[1].Missed() {
		t.Errorf("B is met — the seal supersedes the trail, never Missed")
	}
	if items[2].Attempts != nil || items[2].Missed() {
		t.Errorf("C non-list attempts should decode to nil, got %+v", items[2].Attempts)
	}
	if items[3].Attempts != nil || items[3].Missed() {
		t.Errorf("D all-junk attempts should decode to nil, got %+v", items[3].Attempts)
	}
}

// TestDecodeClaimPulse pins the D9 claim.now decode: the pinned
// {"text","ts","criterion"?} shape lands as a ClaimPulse; a missing/null/
// non-integer criterion reads -1 (the pulse names no rung); an absent, null,
// malformed or empty-text now decodes to NO pulse; a malformed ts decodes to
// the zero time (maximally stale — an undatable pulse must never read fresh).
func TestDecodeClaimPulse(t *testing.T) {
	body := []byte(`{"docs":[
		{"doc_id":"full","claim":{"worker":"w","epoch":2,"ts_iso":"2026-07-10T10:00:00Z",
			"now":{"text":"wiring the decoder","ts":"2026-07-10T10:03:00Z","criterion":1}}},
		{"doc_id":"nocrit","claim":{"worker":"w","epoch":1,"now":{"text":"reading code","ts":"2026-07-10T10:03:00Z"}}},
		{"doc_id":"badcrit","claim":{"worker":"w","epoch":1,"now":{"text":"x","ts":"2026-07-10T10:03:00Z","criterion":"two"}}},
		{"doc_id":"negcrit","claim":{"worker":"w","epoch":1,"now":{"text":"x","ts":"2026-07-10T10:03:00Z","criterion":-3}}},
		{"doc_id":"badts","claim":{"worker":"w","epoch":1,"now":{"text":"x","ts":12345}}},
		{"doc_id":"nulled","claim":{"worker":"w","epoch":1,"now":null}},
		{"doc_id":"emptytext","claim":{"worker":"w","epoch":1,"now":{"text":"  ","ts":"2026-07-10T10:03:00Z"}}},
		{"doc_id":"absent","claim":{"worker":"w","epoch":1}},
		{"doc_id":"garbage","claim":{"worker":"w","epoch":1,"now":"doing stuff"}}
	]}`)
	tasks, err := decodeTaskList(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	byID := map[string]Task{}
	for _, tk := range tasks {
		byID[tk.DocID] = tk
	}
	full := byID["full"].Claim.Now
	if full == nil || full.Text != "wiring the decoder" || full.Criterion != 1 ||
		full.At != mustParse(t, "2026-07-10T10:03:00Z") {
		t.Errorf("full pulse = %+v", full)
	}
	for id, wantCrit := range map[string]int{"nocrit": -1, "badcrit": -1, "negcrit": -1} {
		p := byID[id].Claim.Now
		if p == nil || p.Criterion != wantCrit {
			t.Errorf("%s pulse = %+v, want criterion %d", id, p, wantCrit)
		}
	}
	if p := byID["badts"].Claim.Now; p == nil || !p.At.IsZero() {
		t.Errorf("badts pulse should keep a zero (stale) time, got %+v", p)
	}
	for _, id := range []string{"nulled", "emptytext", "absent", "garbage"} {
		if p := byID[id].Claim.Now; p != nil {
			t.Errorf("%s should decode to NO pulse, got %+v", id, p)
		}
	}
}

// TestDecodeAcceptanceCriteria_AbsentAndMalformed proves the permissive layers:
// no content, content that is not an object, and an acceptance_criteria that is
// not a list all yield a nil slice rather than an error — one odd task can never
// break the whole list decode.
func TestDecodeAcceptanceCriteria_AbsentAndMalformed(t *testing.T) {
	cases := map[string]string{
		"absent content":           `{"doc_id":"x"}`,
		"empty content":            `{"doc_id":"x","content":{}}`,
		"content is not an object": `{"doc_id":"x","content":"oops"}`,
		"criteria is not a list":   `{"doc_id":"x","content":{"acceptance_criteria":{"met":true}}}`,
		"criteria is empty list":   `{"doc_id":"x","content":{"acceptance_criteria":[]}}`,
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			tasks, err := decodeTaskList([]byte(`{"docs":[` + doc + `]}`))
			if err != nil {
				t.Fatalf("decode should not error: %v", err)
			}
			if tasks[0].CriteriaItems != nil {
				t.Errorf("CriteriaItems = %+v, want nil", tasks[0].CriteriaItems)
			}
		})
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

// TestDecodeEnvelopeFence — the board must not render a plausible EMPTY BOARD
// for a 200 that said nothing. A well-formed JSON object WITHOUT the envelope
// key (or with `ok:false`) used to decode to zero rows with a nil error, which
// is indistinguishable from a genuinely empty board; it must now be a named
// decode error. The legitimate-empty cases are pinned in the SAME table so the
// fence can never be tightened into refusing a real empty board.
//
// This is envelope-scoped and does NOT cross detail_data.go's field-scoped
// 'Tolerance contract (frozen wave-5)' — see TestDecodeAcceptanceCriteria_
// AbsentAndMalformed above, which still proves per-doc tolerance is intact.
//
// ORDERING HAZARD: this table is also the guard on nil-check-before-deref. If
// the deref is hoisted above the nil check, every poison row panics here
// instead of returning an error, so a reorder fails the suite.
//
// POISON PARITY WITH THE CLI (measured, not assumed). The CLI's reader-honesty
// lock — TestRunPaginatedAll_RefusesUnreadablePage, internal/cli/
// paginate_all_test.go:94-104 — carries NINE poison bodies. Dropping all nine
// into this package and calling decodeTaskListFull and decodePrime directly
// splits them FIVE / FOUR, identically on both decoders:
//
//   - FENCE-class (5, pinned as rows below): `null`, `{}`, `{"result":null}`,
//     `{"widgets":[…]}` and the ok:false error envelope. Each is valid JSON
//     that decodes cleanly into the envelope struct and leaves the envelope
//     key nil, so ONLY the pointer nil-check refuses them. These are exactly
//     the bodies the fence exists for, and reverting the fence reds them.
//   - UNMARSHAL-class (4, DECLARED here, deliberately NOT pinned as rows): the
//     proxy-502 HTML page, zero bytes, the bare array `[{"a":1}]` and the
//     plaintext body. All four fail json.Unmarshal BEFORE any fence runs, so a
//     row asserting they error would be green both before and after the fix —
//     a vacuous row, the exact failure this table exists to kill.
//
// PARITY MEANS "EVERY CLI POISON THAT CAN TRANSFER IS HERE", NOT "THE TWO TABLES
// ARE EQUAL". These tables are a SUPERSET: `bare error envelope` is a body the
// board carries and the CLI's nine do not. So the counts below describe the
// CLI's nine as they land here, not the size of these tables.
//
// The four-way split is a property of the CURRENT envelope structs, measured at
// origin/main 885ace84a (re-confirmed at review: that sha is an ancestor of
// origin/main b77a7486f, and reverting the pointer fence reds exactly the seven
// poison rows per decoder while every legitimate control stays green). It is not
// a law: widening either envelope field to
// json.RawMessage would make the bare array and the plaintext body decode, at
// which point they become fence-class and belong in the tables below. Re-measure
// before trusting this comment after any change to the structs in fetch.go.
//
// The board's refusal channel is snapshotErrorLabel → ui.ConnProblem, NOT the
// CLI's `unreadable_list_page` code: that token is a contract on the CLI's JSON
// error envelope (renderErrorEnvelope), and a tea TUI has no such transport.
// Every poison row therefore asserts the LABEL, so the classification is pinned
// rather than incidental.
func TestDecodeEnvelopeFence(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		wantErr bool
	}{
		{"null body", `null`, true},
		{"empty object", `{}`, true},
		{"bare error envelope", `{"error":"barkpark_not_found","detail":"no such dataset"}`, true},
		{"ok false error envelope", `{"ok":false,"error":{"code":"forbidden"}}`, true},
		{"docs null", `{"ok":true,"docs":null}`, true},
		// Verbatim from the CLI's poison table (paginate_all_test.go:94-104).
		{"unknown envelope key", `{"widgets":[{"a":1},{"b":2}]}`, true},
		{"result null", `{"result":null}`, true},
		{"legitimate empty board", `{"docs":[]}`, false},
		{"legitimate populated board", `{"ok":true,"docs":[{"doc_id":"x"}]}`, false},
	}
	for _, tc := range cases {
		t.Run("list/"+tc.name, func(t *testing.T) {
			tasks, details, err := decodeTaskListFull([]byte(tc.body))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("decodeTaskListFull(%s) = %d rows, nil error — a silent empty board", tc.body, len(tasks))
				}
				if got := snapshotErrorLabel(err); got != "invalid snapshot" {
					t.Errorf("snapshotErrorLabel(%v) = %q, want %q — the refusal must ride the existing ConnProblem channel", err, got, "invalid snapshot")
				}
				return
			}
			if err != nil {
				t.Fatalf("decodeTaskListFull(%s) errored on a legitimate body: %v", tc.body, err)
			}
			if tasks == nil || details == nil {
				t.Fatalf("decodeTaskListFull(%s) = (%v, %v), want non-nil empties", tc.body, tasks, details)
			}
		})
	}

	primeCases := []struct {
		name    string
		body    string
		wantErr bool
	}{
		{"null body", `null`, true},
		{"empty object", `{}`, true},
		{"bare error envelope", `{"error":"barkpark_not_found"}`, true},
		{"ok false error envelope", `{"ok":false,"error":{"code":"forbidden"}}`, true},
		{"counts null and no ok", `{"counts":null}`, true},
		// Verbatim from the CLI's poison table (paginate_all_test.go:94-104).
		{"unknown envelope key", `{"widgets":[{"a":1},{"b":2}]}`, true},
		{"result null", `{"result":null}`, true},
		// A brief view may legitimately omit counts; an affirmative ok is
		// enough of an envelope to trust.
		{"ok true without counts", `{"ok":true,"recent_events":[]}`, false},
		{"counts present empty", `{"counts":{}}`, false},
		{"counts populated", `{"ok":true,"counts":{"open":2}}`, false},
	}
	for _, tc := range primeCases {
		t.Run("prime/"+tc.name, func(t *testing.T) {
			extras, err := decodePrime([]byte(tc.body))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("decodePrime(%s) = %+v, nil error — a silent empty prime", tc.body, extras)
				}
				if got := snapshotErrorLabel(err); got != "invalid snapshot" {
					t.Errorf("snapshotErrorLabel(%v) = %q, want %q", err, got, "invalid snapshot")
				}
				return
			}
			if err != nil {
				t.Fatalf("decodePrime(%s) errored on a legitimate body: %v", tc.body, err)
			}
		})
	}
}
