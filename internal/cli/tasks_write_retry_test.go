package cli

// Proofs for the ledger-write retry (tasks_write_retry.go).
//
// The property under test is NOT "does it retry" — a blind retry is trivial and
// wrong. It is: A WRITE THAT ALREADY LANDED IS NEVER RE-SENT. Every 5xx path
// below therefore counts POSTs, because the count is the defect: a claim
// re-sent after landing 409s or bumps the fencing epoch, and a close re-sent
// after landing fails its own CAS.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// lwManifest carries the six task verbs the retry policy attaches to PLUS the
// two reads its read-backs use (task.get, task.prime). The read verbs are not
// decoration: without task.get in the manifest there is no read-back URL to
// build, ledgerWriteFor declines the policy, and every test below would pass
// vacuously against an unretried send.
const lwManifest = `{
  "manifest_version": "test",
  "server": {"name": "test", "version": "0", "base_url": "http://example.invalid"},
  "auth_tier": "read",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {
      "id": "task.get", "noun": "task", "verb": "get", "summary": "get",
      "http": {"method": "GET", "path_template": "/v1/tasks/:doc_id"},
      "auth_tier": "read",
      "args": [{"name": "doc_id", "required": true, "type": "string", "summary": "id"}],
      "flags": [],
      "writes": false, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "json"
    },
    {
      "id": "task.prime", "noun": "task", "verb": "prime", "summary": "prime",
      "http": {"method": "GET", "path_template": "/v1/tasks/prime"},
      "auth_tier": "read",
      "args": [],
      "flags": [{"name": "worker", "type": "string", "summary": "w"}, {"name": "limit", "type": "int", "summary": "n"}],
      "writes": false, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "json"
    },
    {
      "id": "task.claim", "noun": "task", "verb": "claim", "summary": "claim",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/claim"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"}
      ],
      "flags": [],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    },
    {
      "id": "task.next", "noun": "task", "verb": "next", "summary": "next",
      "http": {"method": "POST", "path_template": "/v1/tasks/claim"},
      "auth_tier": "read",
      "args": [{"name": "worker_id", "required": true, "type": "string", "summary": "w"}],
      "flags": [],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    },
    {
      "id": "task.close", "noun": "task", "verb": "close", "summary": "close",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/close"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"},
        {"name": "observed_epoch", "required": true, "type": "int", "summary": "e"},
        {"name": "lifecycle_status", "required": false, "type": "string", "summary": "seal"},
        {"name": "reason", "required": false, "type": "string", "summary": "why"}
      ],
      "flags": [{"name": "set", "type": "string", "summary": "extra"}],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    },
    {
      "id": "task.pulse", "noun": "task", "verb": "pulse", "summary": "pulse",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/pulse"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"}
      ],
      "flags": [{"name": "now", "type": "string", "summary": "now-line"}],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    },
    {
      "id": "task.stamp", "noun": "task", "verb": "stamp", "summary": "stamp",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/stamp"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"},
        {"name": "observed_epoch", "required": true, "type": "int", "summary": "e"}
      ],
      "flags": [
        {"name": "criterion", "type": "int", "summary": "idx"},
        {"name": "criterion-text", "type": "string", "summary": "text"},
        {"name": "met", "type": "bool", "summary": "met"},
        {"name": "evidence", "type": "string", "summary": "ev"},
        {"name": "miss", "type": "bool", "summary": "miss"},
        {"name": "note", "type": "string", "summary": "note"}
      ],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// lwFake is a Barkpark whose write route can be scripted to fail, and whose
// STORE commits (or does not) independently of what it answers. Modelling the
// two as one is exactly the mistake the whole feature exists to correct.
type lwFake struct {
	mu sync.Mutex
	// posts counts every write POST. It IS the assertion in most tests here.
	posts int
	gets  int
	// statuses[i] is what the (i+1)th POST answers; the last entry repeats.
	statuses []int
	// commitOnPost, when > 0, is the POST attempt at which the write actually
	// lands in the store — so commitOnPost=1 with statuses=[500] is the
	// 500 + LANDED case that must NEVER produce a second POST.
	commitOnPost int
	// readStatus is what the read-back routes answer (200 unless a test wants
	// an unreadable ledger).
	readStatus int
	retryAfter string

	lifecycle string
	worker    string
	epoch     int
	closedAt  string
	closedBy  string
	nowLine   string
	criteria  []map[string]any
}

func (f *lwFake) statusFor(n int) int {
	if len(f.statuses) == 0 {
		return http.StatusOK
	}
	if n-1 < len(f.statuses) {
		return f.statuses[n-1]
	}
	return f.statuses[len(f.statuses)-1]
}

func (f *lwFake) docJSON() []byte {
	claim := map[string]any{"worker": f.worker, "epoch": f.epoch, "ts_iso": time.Now().UTC().Format(time.RFC3339Nano)}
	if f.closedAt != "" {
		claim["closed_at"] = f.closedAt
		claim["closed_by"] = f.closedBy
	}
	if f.nowLine != "" {
		claim["now"] = map[string]any{"text": f.nowLine, "ts": "2026-09-01T10:00:00Z"}
	}
	doc := map[string]any{
		"doc_id":           "bp-task-x",
		"status":           "published",
		"lifecycle_status": f.lifecycle,
		"content":          map[string]any{"acceptance_criteria": f.criteria},
	}
	if f.worker != "" {
		doc["claim"] = claim
	}
	body, _ := json.Marshal(map[string]any{"ok": true, "doc": doc})
	return body
}

// lwServe stands the fake up and points the CLI at it. It also stubs the retry
// waits: the SCHEDULE is proven by TestLedgerWriteBackoffSchedule with an
// injected sleeper, so spending 6 real seconds here would buy nothing.
func lwServe(t *testing.T, f *lwFake) {
	t.Helper()
	if f.readStatus == 0 {
		f.readStatus = http.StatusOK
	}
	realSleep := ledgerSleep
	ledgerSleep = func(time.Duration) {}
	t.Cleanup(func() { ledgerSleep = realSleep })

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()

		if r.Method == http.MethodGet {
			f.gets++
			if f.readStatus != http.StatusOK {
				w.WriteHeader(f.readStatus)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"store_unreachable"}`))
				return
			}
			if strings.HasSuffix(r.URL.Path, "/prime") {
				rows := []any{}
				if f.worker != "" {
					rows = append(rows, map[string]any{
						"doc_id": "bp-task-x",
						"claim":  map[string]any{"worker": f.worker, "epoch": f.epoch, "ts_iso": time.Now().UTC().Format(time.RFC3339Nano)},
					})
				}
				body, _ := json.Marshal(map[string]any{"ok": true, "in_progress": rows})
				_, _ = w.Write(body)
				return
			}
			_, _ = w.Write(f.docJSON())
			return
		}

		f.posts++
		n := f.posts
		if f.commitOnPost > 0 && n >= f.commitOnPost {
			f.commit(r)
		}
		status := f.statusFor(n)
		if status != http.StatusOK {
			if f.retryAfter != "" {
				w.Header().Set("Retry-After", f.retryAfter)
			}
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"internal_error","message":"boom"}}`))
			return
		}
		_, _ = w.Write(f.docJSON())
	}))
	t.Cleanup(srv.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(lwManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", srv.URL)
	t.Setenv("BARKPARK_API_TOKEN", "lw-stub")
}

// commit applies the write to the store — the half a status code says nothing
// about.
func (f *lwFake) commit(r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	str := func(k string) string {
		if s, ok := body[k].(string); ok {
			return s
		}
		return ""
	}
	switch {
	case strings.HasSuffix(r.URL.Path, "/close"):
		seal := str("lifecycle_status")
		if seal == "" {
			seal = "done"
		}
		f.lifecycle = seal
		f.closedBy = str("worker_id")
		f.closedAt = "2026-09-01T20:41:44Z"
	case strings.HasSuffix(r.URL.Path, "/pulse"):
		f.nowLine = r.URL.Query().Get("now")
		f.epoch++
	case strings.HasSuffix(r.URL.Path, "/stamp"):
		idx := 0
		if len(f.criteria) > 0 {
			f.criteria[idx]["met"] = true
			f.criteria[idx]["evidence"] = r.URL.Query().Get("evidence")
		}
	default: // claim (targeted or queue)
		f.worker = str("worker_id")
		f.epoch = 1
		f.lifecycle = "in_progress"
	}
}

// ── (a) a transient 5xx is retried ──────────────────────────────────────────

// 500 then 200 on a claim the store never took: the retry fires exactly once
// and the second POST wins. Two POSTs, not one (no retry) and not four.
//
// MUTATION PROOF: set `req.ledger = nil` in sendManifestRequest (or delete the
// branch) and this goes red at "claim POST fired 1 times, want 2".
func TestLedgerWriteRetriesATransient500(t *testing.T) {
	f := &lwFake{lifecycle: "open", statuses: []int{500, 200}, commitOnPost: 2}
	lwServe(t, f)

	out, code := captureExecuteCode(t, []string{"task", "claim", "bp-task-x", "w4"})

	if f.posts != 2 {
		t.Fatalf("claim POST fired %d times, want 2 (one failure + one retry); out:\n%s", f.posts, out)
	}
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — the retry succeeded; out:\n%s", code, out)
	}
	if !strings.Contains(out, "retrying 1/3") {
		t.Errorf("the retry must announce itself on stderr; got:\n%s", out)
	}
}

// ── (b) THE SPINE: a write that already landed is never re-sent ─────────────

// 500 + LANDED. The claim COMMITTED and then the response failed. The read-back
// before the retry finds our claim, so the retry never happens: ONE POST.
//
// MUTATION PROOF: delete the `if last.state == ledgerLandedYes` early return in
// sendLedgerWrite and this goes red at "claim POST fired 4 times, want 1" — the
// exact duplicate-write this feature exists to prevent.
func TestLedgerWriteDoesNotResendAClaimThatAlreadyLanded(t *testing.T) {
	f := &lwFake{lifecycle: "open", statuses: []int{500}, commitOnPost: 1}
	lwServe(t, f)

	out, code := captureExecuteCode(t, []string{"task", "claim", "bp-task-x", "w4"})

	if f.posts != 1 {
		t.Fatalf("claim POST fired %d times, want 1 — the write had ALREADY LANDED and was re-sent anyway; out:\n%s", f.posts, out)
	}
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — the store holds the claim; out:\n%s", code, out)
	}
	if !strings.Contains(out, "ALREADY HOLDS") {
		t.Errorf("the caller must be told the store already held it; got:\n%s", out)
	}
	if !strings.Contains(out, "epoch 1") {
		t.Errorf("the receipt should carry the fencing epoch the read-back found; got:\n%s", out)
	}
}

// The same property for the SEAL: a close that committed under a 500 is not
// re-sent, so its CAS is never failed by its own duplicate.
func TestLedgerWriteDoesNotResendACloseThatAlreadyLanded(t *testing.T) {
	f := &lwFake{lifecycle: "in_progress", worker: "w4", epoch: 1, statuses: []int{500}, commitOnPost: 1}
	lwServe(t, f)

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w4", "1", "done", "shipped"})

	if f.posts != 1 {
		t.Fatalf("close POST fired %d times, want 1 — a landed close was re-sent into its own CAS; out:\n%s", f.posts, out)
	}
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if !strings.Contains(out, "the store holds it") {
		t.Errorf("the close receipt should still be rendered from the store; got:\n%s", out)
	}
}

// And for the now-line: a pulse that landed is not re-sent, because a re-sent
// pulse BUMPS THE CLAIM EPOCH and invalidates the close that follows it.
func TestLedgerWriteDoesNotResendAPulseThatAlreadyLanded(t *testing.T) {
	f := &lwFake{lifecycle: "in_progress", worker: "w4", epoch: 3, statuses: []int{500}, commitOnPost: 1}
	lwServe(t, f)

	out, code := captureExecuteCode(t, []string{"task", "pulse", "bp-task-x", "w4", "--now", "warm-up pinned"})

	if f.posts != 1 {
		t.Fatalf("pulse POST fired %d times, want 1 — the re-send would have bumped the epoch again; out:\n%s", f.posts, out)
	}
	if f.epoch != 4 {
		t.Fatalf("epoch = %d, want 4 (bumped exactly once); out:\n%s", f.epoch, out)
	}
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
}

// ── (c) a 4xx is an ANSWER, never a retry ───────────────────────────────────

func TestLedgerWriteNeverRetriesA4xx(t *testing.T) {
	for _, status := range []int{404, 409, 422} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			f := &lwFake{lifecycle: "open", statuses: []int{status}}
			lwServe(t, f)

			out, code := captureExecuteCode(t, []string{"task", "claim", "bp-task-x", "w4"})

			if f.posts != 1 {
				t.Fatalf("HTTP %d retried: POST fired %d times, want 1 — a refusal is an answer; out:\n%s", status, f.posts, out)
			}
			if code == exitOK {
				t.Fatalf("HTTP %d exited 0; out:\n%s", status, out)
			}
			if strings.Contains(out, "retrying") {
				t.Errorf("HTTP %d announced a retry it must not perform; got:\n%s", status, out)
			}
		})
	}
}

// ── (d) exhausted, with an unreadable ledger, says UNKNOWN ──────────────────

// Every attempt 500s AND the read-back 500s too — the realistic shape, because
// the box that cannot serve the write cannot serve the read that would explain
// it. The refusal must name the attempt count and must say UNKNOWN, never
// "not landed": telling an agent a write was lost when nobody could check is
// the false certainty that makes it re-send by hand.
func TestLedgerWriteExhaustedWithUnreadableStoreSaysUnknown(t *testing.T) {
	f := &lwFake{lifecycle: "open", statuses: []int{500}, readStatus: 500}
	lwServe(t, f)

	out, code := captureExecuteCode(t, []string{"task", "claim", "bp-task-x", "w4"})

	if want := ledgerWriteRetries + 1; f.posts != want {
		t.Fatalf("claim POST fired %d times, want %d (1 + %d retries); out:\n%s", f.posts, want, ledgerWriteRetries, out)
	}
	if code == exitOK {
		t.Fatalf("an exhausted ledger write exited 0; out:\n%s", out)
	}
	for _, want := range []string{"after 4 attempts", "unknown", "UNKNOWN"} {
		if !strings.Contains(out, want) {
			t.Errorf("the refusal must contain %q; got:\n%s", want, out)
		}
	}
	if strings.Contains(out, "does not hold it") {
		t.Errorf("an unreadable ledger must never be reported as a confirmed absence; got:\n%s", out)
	}
}

// The counterpart: when the store IS readable and confirms the write is absent,
// the refusal says so — a confirmed absence is safe to re-run by hand, and
// saying "unknown" there would be its own kind of dishonesty.
func TestLedgerWriteExhaustedWithReadableStoreSaysNotLanded(t *testing.T) {
	f := &lwFake{lifecycle: "open", statuses: []int{500}}
	lwServe(t, f)

	out, _ := captureExecuteCode(t, []string{"task", "claim", "bp-task-x", "w4"})

	if !strings.Contains(out, "does not hold it") {
		t.Errorf("a readable store that lacks the write should be reported as a confirmed absence; got:\n%s", out)
	}
}

// ── (e) the backoff schedule ────────────────────────────────────────────────

// The schedule, proven without spending it. Jitter is injected as identity so
// the table is exact; ledgerJitter's own spread is asserted separately below.
func TestLedgerWriteBackoffSchedule(t *testing.T) {
	var waited []time.Duration
	lw := &ledgerWrite{
		verb:     "claim",
		jitter:   func(d time.Duration) time.Duration { return d },
		sleep:    func(d time.Duration) { waited = append(waited, d) },
		notify:   func(string) {},
		readback: func() ledgerLandedVerdict { return ledgerLandedVerdict{state: ledgerLandedNo} },
		send: func() (int, []byte, string, http.Header, error) {
			return 500, []byte(`{"ok":false}`), "application/json", nil, nil
		},
	}
	req := &manifestRequest{ledger: lw}

	status, _, _, err := sendLedgerWrite(req)
	if status != 500 || err != nil {
		t.Fatalf("status=%d err=%v, want the last 500 handed back", status, err)
	}
	want := []time.Duration{500 * time.Millisecond, 1500 * time.Millisecond, 4 * time.Second}
	if len(waited) != len(want) {
		t.Fatalf("waited %v, want %v", waited, want)
	}
	for i := range want {
		if waited[i] != want[i] {
			t.Errorf("wait %d = %s, want %s", i+1, waited[i], want[i])
		}
	}
}

// Jitter must actually spread — a fleet that all failed on the same second must
// not re-send on the same next one — and must stay inside ±15%.
func TestLedgerJitterSpreadsWithinBounds(t *testing.T) {
	base := time.Second
	seen := map[time.Duration]bool{}
	for i := 0; i < 200; i++ {
		d := ledgerJitter(base)
		if d < 850*time.Millisecond || d > 1150*time.Millisecond {
			t.Fatalf("jittered %s outside ±15%% of %s", d, base)
		}
		seen[d] = true
	}
	if len(seen) < 2 {
		t.Errorf("jitter produced a single value %v — it is not spreading anything", seen)
	}
}

// A server that names its own recovery window wins over the table, and a
// ridiculous one is capped rather than obeyed.
func TestLedgerRetryAfterIsHonouredAndCapped(t *testing.T) {
	cases := []struct {
		name  string
		value string
		want  time.Duration
		ok    bool
	}{
		{"seconds", "2", 2 * time.Second, true},
		{"capped", "3600", ledgerRetryAfterCap, true},
		{"negative", "-5", 0, false},
		{"garbage", "soon", 0, false},
		{"absent", "", 0, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			hdr := http.Header{}
			if tc.value != "" {
				hdr.Set("Retry-After", tc.value)
			}
			got, ok := ledgerRetryAfter(hdr)
			if ok != tc.ok || (ok && got != tc.want) {
				t.Fatalf("ledgerRetryAfter(%q) = (%s, %v), want (%s, %v)", tc.value, got, ok, tc.want, tc.ok)
			}
		})
	}
}

// And the header actually reaches the wait, through the real dispatch.
func TestLedgerWriteHonoursRetryAfterHeader(t *testing.T) {
	f := &lwFake{lifecycle: "open", statuses: []int{503, 200}, commitOnPost: 2, retryAfter: "2"}
	lwServe(t, f)

	out, code := captureExecuteCode(t, []string{"task", "claim", "bp-task-x", "w4"})

	if code != exitOK || f.posts != 2 {
		t.Fatalf("exit=%d posts=%d, want exitOK and 2; out:\n%s", code, f.posts, out)
	}
	if !strings.Contains(out, "in 2s") {
		t.Errorf("the server's Retry-After should set the wait; got:\n%s", out)
	}
}

// ── the queue claim, which names no row ─────────────────────────────────────

// `bp task next` picks the task server-side, so its read-back is the worker's
// own live claims. A queue claim that landed under a 500 must not be re-sent —
// the second one would claim a SECOND task and orphan the first.
func TestLedgerWriteDoesNotResendAQueueClaimThatAlreadyLanded(t *testing.T) {
	f := &lwFake{lifecycle: "open", statuses: []int{500}, commitOnPost: 1}
	lwServe(t, f)

	out, _ := captureExecuteCode(t, []string{"task", "next", "w4"})

	if f.posts != 1 {
		t.Fatalf("queue-claim POST fired %d times, want 1 — the re-send would have claimed a second task; out:\n%s", f.posts, out)
	}
	if !strings.Contains(out, "ALREADY HOLDS") {
		t.Errorf("the caller must be told the queue already claimed for them; got:\n%s", out)
	}
}

// A claim this worker was ALREADY holding before the command started is not
// evidence that this command's claim landed — the predicate is anchored on the
// claim's own timestamp against the command's start.
func TestQueueClaimLandedIgnoresAPreExistingClaim(t *testing.T) {
	old := time.Now().UTC().Add(-time.Hour)
	body, _ := json.Marshal(map[string]any{"ok": true, "in_progress": []any{
		map[string]any{"doc_id": "bp-task-old", "claim": map[string]any{
			"worker": "w4", "epoch": 2, "ts_iso": old.Format(time.RFC3339Nano)}},
	}})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	v := ledgerQueueClaimLanded(srv.URL+"/v1/tasks/prime", nil, "w4", time.Now().UTC())
	if v.state != ledgerLandedNo {
		t.Fatalf("state = %v (%s), want ledgerLandedNo — an hour-old lease is not this command's claim", v.state, v.detail)
	}
}

// ── the per-verb landed predicates ──────────────────────────────────────────

func lwRow(t *testing.T, doc map[string]any) (ledgerDocRow, []byte) {
	t.Helper()
	raw, _ := json.Marshal(map[string]any{"ok": true, "doc": doc})
	var row ledgerDocRow
	if err := json.Unmarshal(raw, &row); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return row, raw
}

func TestClaimLandedPredicate(t *testing.T) {
	cases := []struct {
		name string
		doc  map[string]any
		want ledgerLandedState
	}{
		{"no claim at all", map[string]any{"lifecycle_status": "open"}, ledgerLandedNo},
		{"held by someone else", map[string]any{"claim": map[string]any{"worker": "other", "epoch": 1}}, ledgerLandedNo},
		{"ours, live, fenced", map[string]any{"claim": map[string]any{"worker": "w4", "epoch": 7}}, ledgerLandedYes},
		{"ours but no epoch", map[string]any{"claim": map[string]any{"worker": "w4", "epoch": 0}}, ledgerLandedNo},
		{"ours but released", map[string]any{"claim": map[string]any{"worker": "w4", "epoch": 7, "released_at": "2026-09-01T00:00:00Z"}}, ledgerLandedNo},
		{"ours but closed out", map[string]any{"claim": map[string]any{"worker": "w4", "epoch": 7, "closed_at": "2026-09-01T00:00:00Z"}}, ledgerLandedNo},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			row, raw := lwRow(t, tc.doc)
			if got := claimLanded(row, raw, "w4").state; got != tc.want {
				t.Fatalf("state = %v, want %v", got, tc.want)
			}
		})
	}
}

// THE REGRESSION GUARD FOR task-735080f28a2bfecd (#14819): the still-held test
// keys on claim.closed_at, NEVER on claim.worker. The server KEEPS the claim
// map on a successful close and stamps closed_by/closed_at onto it, so a sealed
// row that names a worker is the NORMAL shape. Reading it as "still held" here
// would report a landed close as unlanded and RE-SEND it into its own CAS.
func TestCloseLandedKeysOnClosedAtNotOnClaimWorker(t *testing.T) {
	sealedAndNamed := map[string]any{
		"lifecycle_status": "done",
		"claim": map[string]any{
			"worker": "w4", "epoch": 1,
			"closed_by": "w4", "closed_at": "2026-09-01T20:41:44Z",
		},
	}
	row, raw := lwRow(t, sealedAndNamed)
	if got := closeLanded(row, raw, "w4", "done").state; got != ledgerLandedYes {
		t.Fatalf("state = %v, want ledgerLandedYes — a sealed row that still NAMES its worker is a landed close, not a held one", got)
	}

	sealedButUnsettled := map[string]any{
		"lifecycle_status": "done",
		"claim":            map[string]any{"worker": "w4", "epoch": 1},
	}
	row, raw = lwRow(t, sealedButUnsettled)
	if got := closeLanded(row, raw, "w4", "done").state; got != ledgerLandedNo {
		t.Fatalf("state = %v, want ledgerLandedNo — a seal with NO close-out stamp is the genuine half-landed close", got)
	}
}

func TestCloseLandedPredicate(t *testing.T) {
	cases := []struct {
		name     string
		doc      map[string]any
		wantSeal string
		want     ledgerLandedState
	}{
		{"still open", map[string]any{"lifecycle_status": "open"}, "done", ledgerLandedNo},
		{"wrong seal", map[string]any{"lifecycle_status": "cancelled",
			"claim": map[string]any{"worker": "w4", "closed_at": "t"}}, "done", ledgerLandedNo},
		{"cancelled as asked", map[string]any{"lifecycle_status": "cancelled",
			"claim": map[string]any{"worker": "w4", "closed_at": "t", "closed_by": "w4"}}, "cancelled", ledgerLandedYes},
		{"sealed, no claim", map[string]any{"lifecycle_status": "done"}, "done", ledgerLandedYes},
		{"closed out by someone else", map[string]any{"lifecycle_status": "done",
			"claim": map[string]any{"worker": "w4", "closed_by": "other", "closed_at": "t"}}, "done", ledgerLandedNo},
		{"no lifecycle at all", map[string]any{}, "done", ledgerLandedUnknown},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			row, raw := lwRow(t, tc.doc)
			if got := closeLanded(row, raw, "w4", tc.wantSeal).state; got != tc.want {
				t.Fatalf("state = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestPulseLandedPredicate(t *testing.T) {
	sent := "warm-up pinned, rerunning"
	cases := []struct {
		name string
		doc  map[string]any
		want ledgerLandedState
	}{
		{"no now-line", map[string]any{"claim": map[string]any{"worker": "w4"}}, ledgerLandedNo},
		{"our line", map[string]any{"claim": map[string]any{"worker": "w4",
			"now": map[string]any{"text": sent}}}, ledgerLandedYes},
		{"our line, whitespace only", map[string]any{"claim": map[string]any{"worker": "w4",
			"now": map[string]any{"text": "  " + sent + " "}}}, ledgerLandedYes},
		{"an older line", map[string]any{"claim": map[string]any{"worker": "w4",
			"now": map[string]any{"text": "something else"}}}, ledgerLandedNo},
		{"someone else's claim", map[string]any{"claim": map[string]any{"worker": "other",
			"now": map[string]any{"text": sent}}}, ledgerLandedNo},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			row, raw := lwRow(t, tc.doc)
			if got := pulseLanded(row, raw, "w4", sent).state; got != tc.want {
				t.Fatalf("state = %v, want %v", got, tc.want)
			}
		})
	}
}

// THE DELIBERATE DIVERGENCE FROM stampMismatches (task-22bc2e2578ef1222, open):
// the RETRY predicate tests evidence PRESENCE, not byte-equality. Evidence
// containing `%{` has twice come back from the store differing from what was
// sent, with the cause unsettled — and for a retry, a byte-equality test would
// call a LANDED stamp "not landed" and re-send it, manufacturing the duplicate
// write out of an open read-back question. The receipt keeps the strict test.
func TestStampLandedTestsEvidencePresenceNotByteEquality(t *testing.T) {
	doc := map[string]any{"content": map[string]any{"acceptance_criteria": []any{
		map[string]any{"criterion": "c0", "met": true, "evidence": "PR #14819 (stored differently)"},
	}}}
	row, raw := lwRow(t, doc)
	req := stampRequest{index: 0, text: "c0", met: true, evidence: `boom %{error: %{code: "x"}}`}
	if got := stampLanded(row, raw, req).state; got != ledgerLandedYes {
		t.Fatalf("state = %v, want ledgerLandedYes — a stored met with non-empty evidence is a landed stamp; "+
			"re-sending it because the TEXT differs is how task-22bc2e2578ef1222 becomes a duplicate write", got)
	}
}

func TestStampLandedPredicate(t *testing.T) {
	crit := func(m map[string]any) map[string]any {
		return map[string]any{"content": map[string]any{"acceptance_criteria": []any{m}}}
	}
	cases := []struct {
		name string
		doc  map[string]any
		req  stampRequest
		want ledgerLandedState
	}{
		{"met landed", crit(map[string]any{"criterion": "c0", "met": true, "evidence": "PR #1"}),
			stampRequest{index: 0, text: "c0", met: true, evidence: "PR #1"}, ledgerLandedYes},
		{"met not landed", crit(map[string]any{"criterion": "c0", "met": false}),
			stampRequest{index: 0, text: "c0", met: true, evidence: "PR #1"}, ledgerLandedNo},
		{"met without evidence is not landed", crit(map[string]any{"criterion": "c0", "met": true, "evidence": ""}),
			stampRequest{index: 0, text: "c0", met: true, evidence: "PR #1"}, ledgerLandedNo},
		{"wrong row for the text", crit(map[string]any{"criterion": "SOMETHING ELSE", "met": true, "evidence": "x"}),
			stampRequest{index: 0, text: "c0", met: true, evidence: "x"}, ledgerLandedNo},
		{"index out of range is unknown", crit(map[string]any{"criterion": "c0"}),
			stampRequest{index: 5, met: true, evidence: "x"}, ledgerLandedUnknown},
		{"miss landed", crit(map[string]any{"criterion": "c0",
			"attempts": []any{map[string]any{"note": "gate red on ci"}}}),
			stampRequest{index: 0, miss: true, note: "gate red on ci"}, ledgerLandedYes},
		{"miss not landed", crit(map[string]any{"criterion": "c0"}),
			stampRequest{index: 0, miss: true, note: "gate red on ci"}, ledgerLandedNo},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			row, raw := lwRow(t, tc.doc)
			if got := stampLanded(row, raw, tc.req).state; got != tc.want {
				t.Fatalf("state = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestReleaseLandedPredicate(t *testing.T) {
	cases := []struct {
		name string
		doc  map[string]any
		want ledgerLandedState
	}{
		{"no claim", map[string]any{}, ledgerLandedYes},
		{"released", map[string]any{"claim": map[string]any{"worker": "w4", "released_at": "t"}}, ledgerLandedYes},
		{"still live", map[string]any{"claim": map[string]any{"worker": "w4", "epoch": 1}}, ledgerLandedNo},
		{"somebody else's", map[string]any{"claim": map[string]any{"worker": "other", "epoch": 1}}, ledgerLandedNo},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			row, raw := lwRow(t, tc.doc)
			if got := releaseLanded(row, raw, "w4").state; got != tc.want {
				t.Fatalf("state = %v, want %v", got, tc.want)
			}
		})
	}
}

// A read-back that could not be performed is UNKNOWN — never "not landed".
func TestLedgerReadAndTreatsEveryReadFailureAsUnknown(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/500":
			w.WriteHeader(http.StatusInternalServerError)
		case "/garbage":
			_, _ = w.Write([]byte(`not json at all`))
		default:
			_, _ = w.Write([]byte(`{"ok":false,"reason":"nope"}`))
		}
	}))
	defer srv.Close()

	for _, path := range []string{"/500", "/garbage", "/notok"} {
		v := ledgerReadAnd(srv.URL+path, nil, func(ledgerDocRow, []byte) ledgerLandedVerdict {
			return ledgerLandedVerdict{state: ledgerLandedYes}
		})
		if v.state != ledgerLandedUnknown {
			t.Errorf("%s: state = %v, want ledgerLandedUnknown (%s)", path, v.state, v.detail)
		}
	}
}

// ── the fault classification ────────────────────────────────────────────────

func TestLedgerFaultIsTransient(t *testing.T) {
	cases := []struct {
		status int
		err    error
		want   bool
	}{
		{200, nil, false},
		{404, nil, false},
		{409, nil, false},
		{422, nil, false},
		{429, nil, false}, // rate limiting is an ANSWER, and a retry would deepen it
		{500, nil, true},
		{502, nil, true},
		{503, nil, true},
		{504, nil, true},
		{0, fmt.Errorf("dial tcp: connection refused"), true},
		{0, fmt.Errorf("context deadline exceeded"), true},
		{200, fmt.Errorf("response exceeds cap"), false}, // a client-side cap, not a server fault
	}
	for _, tc := range cases {
		if got := ledgerFaultIsTransient(tc.status, tc.err); got != tc.want {
			t.Errorf("ledgerFaultIsTransient(%d, %v) = %v, want %v", tc.status, tc.err, got, tc.want)
		}
	}
}

// A dropped connection is retried the same as a 5xx, and its exhaustion still
// names the attempt count.
func TestLedgerWriteRetriesADroppedConnection(t *testing.T) {
	attempts := 0
	var lines []string
	lw := &ledgerWrite{
		verb:   "close",
		jitter: func(d time.Duration) time.Duration { return d },
		sleep:  func(time.Duration) {},
		notify: func(s string) { lines = append(lines, s) },
		readback: func() ledgerLandedVerdict {
			return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "read failed"}
		},
		send: func() (int, []byte, string, http.Header, error) {
			attempts++
			return 0, nil, "", nil, fmt.Errorf("dial tcp: connection refused")
		},
	}
	_, _, _, err := sendLedgerWrite(&manifestRequest{ledger: lw})

	if attempts != ledgerWriteRetries+1 {
		t.Fatalf("sent %d times, want %d", attempts, ledgerWriteRetries+1)
	}
	if err == nil {
		t.Fatal("an exhausted transport failure returned no error")
	}
	if !strings.Contains(err.Error(), "4 attempts") || !strings.Contains(err.Error(), "unknown") {
		t.Errorf("error must name the attempt count and the UNKNOWN read-back; got %v", err)
	}
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "connection error") {
		t.Errorf("the retry lines should name the fault; got:\n%s", joined)
	}
}

// ── the policy is attached at the shared seam, so MCP inherits it ───────────

// The MCP task_* write tools call execManifestCommand (mcp_tasks.go), which
// builds through buildManifestRequest and sends through sendManifestRequest —
// the same two functions the CLI dispatch uses. This drives THAT path and
// proves the retry rides it with no per-tool code.
func TestMCPTaskWritesInheritLedgerRetry(t *testing.T) {
	// This test drives the HEADLESS dispatch, which has no writer to capture —
	// silence the retry lines so the suite output stays readable. The counter
	// this test asserts on is the POST count, not the announcement.
	t.Setenv("BARKPARK_QUIET_RETRIES", "1")
	f := &lwFake{lifecycle: "open", statuses: []int{500, 200}, commitOnPost: 2}
	lwServe(t, f)

	g, ctx, m := lwDispatchContext(t)
	cmd, ok := m.Tree().Lookup("task", "claim")
	if !ok {
		t.Fatal("manifest has no task.claim")
	}
	status, _, err := execManifestCommand(g, ctx, m, *cmd, []string{"bp-task-x", "w4"})
	if err != nil {
		t.Fatalf("execManifestCommand: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200 — the headless dispatch did not retry", status)
	}
	if f.posts != 2 {
		t.Fatalf("POST fired %d times, want 2 — the MCP dispatch did not inherit the retry", f.posts)
	}
}

// And the MCP path equally must not re-send a write that landed.
func TestMCPTaskWritesDoNotResendALandedWrite(t *testing.T) {
	// This test drives the HEADLESS dispatch, which has no writer to capture —
	// silence the retry lines so the suite output stays readable. The counter
	// this test asserts on is the POST count, not the announcement.
	t.Setenv("BARKPARK_QUIET_RETRIES", "1")
	f := &lwFake{lifecycle: "open", statuses: []int{500}, commitOnPost: 1}
	lwServe(t, f)

	g, ctx, m := lwDispatchContext(t)
	cmd, _ := m.Tree().Lookup("task", "claim")
	status, _, err := execManifestCommand(g, ctx, m, *cmd, []string{"bp-task-x", "w4"})
	if err != nil {
		t.Fatalf("execManifestCommand: %v", err)
	}
	if status != http.StatusOK || f.posts != 1 {
		t.Fatalf("status=%d posts=%d, want 200 and 1 POST", status, f.posts)
	}
}

// Only the six claim/seal verbs carry the policy. A read carries none, and a
// last-writer-wins field update (task.move / task.stage) is deliberately out —
// it would pay a read-back for a re-send that is harmless.
func TestLedgerPolicyIsAttachedOnlyToClaimAndSealWrites(t *testing.T) {
	lwServe(t, &lwFake{lifecycle: "open"})
	g, ctx, m := lwDispatchContext(t)

	claim, _ := m.Tree().Lookup("task", "claim")
	req, derr := buildManifestRequest(g, ctx, m, *claim, []string{"bp-task-x", "w4"}, false)
	if derr != nil {
		t.Fatalf("build claim: %v", derr)
	}
	if req.ledger == nil {
		t.Error("task.claim carries no ledger-write policy")
	}

	get, _ := m.Tree().Lookup("task", "get")
	req, derr = buildManifestRequest(g, ctx, m, *get, []string{"bp-task-x"}, false)
	if derr != nil {
		t.Fatalf("build get: %v", derr)
	}
	if req.ledger != nil {
		t.Error("task.get — a READ — carries a ledger-write policy")
	}
}

// lwDispatchContext resolves the globals/context/manifest the headless dispatch
// needs, against whatever lwServe pointed the environment at. g.yes is set the
// way every headless caller must set it (the prod write-guard lives in
// runCommand, not in execManifestCommand).
func lwDispatchContext(t *testing.T) (globals, manifest.Context, *manifest.Manifest) {
	t.Helper()
	m, err := loadManifestFile(os.Getenv("BARKPARK_MANIFEST"))
	if err != nil {
		t.Fatalf("load manifest: %v", err)
	}
	ctx := manifest.Context{
		Server:  os.Getenv("BARKPARK_API_URL"),
		Token:   os.Getenv("BARKPARK_API_TOKEN"),
		Dataset: "production",
	}
	return globals{yes: true}, ctx, m
}
