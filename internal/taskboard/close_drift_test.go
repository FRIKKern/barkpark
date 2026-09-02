package taskboard

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// close_drift_test.go is the BEHAVIOURAL proof for the board's close-drift
// recovery — the thing the old strip copy promised and the board could not do.
//
// The dead end it replaces: the strip said "reopen the task (enter) to re-read,
// then close again". A same-worker re-read preserves the claim's work_digest
// (docs/setup/TASK-SYSTEM.md), so the "close again" repeats the identical 409
// forever. The only close the server can accept after the brief moved is one
// pinned to observed_rev — the revision the worker just re-read — which
// short-circuits check_work_digest and CAS-guards on that exact rev instead
// (api/lib/barkpark/tasks/close.ex).
//
// The fence stays ARMED FIRST (the cmux Stop hook's law): the ordinary close
// sends NO observed_rev, so every close the drift never touched is still
// protected by the work-digest fence. Only the server's own
// doc_changed_since_claim opens the bypass.

// driftServer is the live close fence, in miniature. It answers a close exactly
// as the API does:
//
//   - no observed_rev → 409 doc_changed_since_claim (the work-digest fence: the
//     brief moved under this claim),
//   - observed_rev == the CURRENT rev → 200 (strict full-rev CAS satisfied),
//   - observed_rev == anything else → 409 stale_claim (someone edited again
//     between the read and the close; the close is REFUSED, never applied).
//
// It records every close body so a test can assert what actually went on the
// wire, and `closed` records the rev a close LANDED at (empty = nothing landed).
type driftServer struct {
	mu   sync.Mutex
	rev  string   // the document's current revision, server-side
	revs []string // observed_rev of every close attempt, in order ("" = fence armed)

	closed    bool
	closedRev string
}

func newDriftServer(t *testing.T, rev string) (*driftServer, *httptest.Server) {
	t.Helper()
	d := &driftServer{rev: rev}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/close") {
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"ok":true}`)
			return
		}
		var body struct {
			Rev string `json:"observed_rev"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)

		d.mu.Lock()
		defer d.mu.Unlock()
		d.revs = append(d.revs, body.Rev)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case body.Rev == "":
			w.WriteHeader(http.StatusConflict)
			_, _ = io.WriteString(w, `{"ok":false,"reason":"doc_changed_since_claim"}`)
		case body.Rev == d.rev:
			d.closed, d.closedRev = true, body.Rev
			_, _ = io.WriteString(w, `{"ok":true,"doc":{}}`)
		default:
			w.WriteHeader(http.StatusConflict)
			_, _ = io.WriteString(w, `{"ok":false,"reason":"stale_claim"}`)
		}
	}))
	return d, srv
}

func (d *driftServer) edit(rev string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.rev = rev
}

func (d *driftServer) attempts() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.revs...)
}

func (d *driftServer) landed() (bool, string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.closed, d.closedRev
}

// The whole recovery rests on the board actually HOLDING a revision per row, so
// pin the wire: render_doc's top-level `rev` must reach Task.Rev. Without this
// the strip could name observed_rev while the close had nothing to pin.
func TestDecodeTaskListCarriesTheDocumentRev(t *testing.T) {
	body := []byte(`{"docs":[{"doc_id":"c1","title":"c1","rev":"9f2c1a","lifecycle_status":"in_progress"}]}`)
	tasks, _, err := decodeTaskListFull(body)
	if err != nil {
		t.Fatalf("decodeTaskListFull: %v", err)
	}
	if len(tasks) != 1 {
		t.Fatalf("tasks = %d, want 1", len(tasks))
	}
	if tasks[0].Rev != "9f2c1a" {
		t.Errorf("Task.Rev = %q, want 9f2c1a — the close-drift recovery has no rev to pin without it", tasks[0].Rev)
	}
	// A server that omits rev leaves it empty rather than inventing one; the
	// board then simply keeps the fence armed (closeRevFor returns "").
	tasks, _, err = decodeTaskListFull([]byte(`{"docs":[{"doc_id":"c1","title":"c1"}]}`))
	if err != nil {
		t.Fatalf("decodeTaskListFull: %v", err)
	}
	if tasks[0].Rev != "" {
		t.Errorf("Task.Rev = %q on an envelope with no rev, want empty", tasks[0].Rev)
	}
}

// claimedTaskRev is claimedTask plus the row's document revision — the token the
// post-drift close pins.
func claimedTaskRev(id string, epoch int, rev string) Task {
	t := claimedTask(id, epoch)
	t.Rev = rev
	return t
}

// pressCloseTwice runs the double-press close guard to completion against the
// row under the cursor and feeds the result back through Update, returning the
// model and the ActionResult the server produced.
func pressCloseTwice(t *testing.T, m Model) (Model, ActionResult) {
	t.Helper()
	m, cmd := step(t, m, runes("x")) // arm
	if cmd != nil {
		t.Fatal("the first x fired a close (it must only arm)")
	}
	m, cmd = step(t, m, runes("x")) // fire
	if cmd == nil {
		t.Fatal("the second x did not fire the close")
	}
	msg, ok := cmd().(actionResultMsg)
	if !ok {
		t.Fatal("close command did not produce an actionResultMsg")
	}
	m, _ = step(t, m, msg)
	return m, msg.res
}

// cursorToDoc parks the board cursor on docID, failing loudly if the row is not
// on screen (a silently-missed row would make every later assertion vacuous).
func cursorToDoc(t *testing.T, m Model, docID string) Model {
	t.Helper()
	for i, r := range m.visibleRows() {
		if r.docID == docID {
			m.ui.Cursor = i
			return m
		}
	}
	t.Fatalf("row %q is not on the board (%d visible rows)", docID, len(m.visibleRows()))
	return m
}

// THE FULL JOURNEY. A stale close is refused by the work-digest fence; the board
// arms the observed_rev recovery and says so; a refresh lands the re-read
// revision on screen; the retry closes pinned to THAT EXACT revision and lands.
//
// Every leg is asserted on the WIRE, not on the copy: attempt 1 carries no
// observed_rev (the fence is armed first), attempt 2 carries the rev the refresh
// put on screen, and the server records the close landing at exactly that rev.
func TestCloseDriftRecoversThroughObservedRevAfterAReRead(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "opus-9")
	d, srv := newDriftServer(t, "rev-2") // the brief already moved to rev-2
	defer srv.Close()

	m := testModel(activeOrphans(claimedTaskRev("c1", 7, "rev-1")))
	m.client = testClient(srv.URL)
	m.now = func() time.Time { return time.Unix(10, 0) }
	m = cursorToDoc(t, m, "c1")

	// ── leg 1: the ordinary close, fence armed, refused ────────────────────
	m, res := pressCloseTwice(t, m)
	if res.OK {
		t.Fatal("the drifted close must be REFUSED, not applied")
	}
	if !strings.Contains(res.Message, "observed_rev") {
		t.Errorf("refusal strip = %q, must lead the user to observed_rev", res.Message)
	}
	if m.resyncClose != "c1" {
		t.Fatalf("resyncClose = %q after the drift refusal, want c1 (the recovery is not armed)", m.resyncClose)
	}
	if got := d.attempts(); len(got) != 1 || got[0] != "" {
		t.Fatalf("close attempts = %q, want exactly one rev-less attempt — the work-digest fence must be armed FIRST", got)
	}

	// ── leg 2: the re-read — a landed snapshot puts rev-2 on screen ────────
	// The arm must survive this: the refresh IS the recovery step, and a landed
	// snapshot deliberately clears the strip and the double-press guard.
	m, _ = step(t, m, snapshotMsg{
		snap:    Snapshot{Tasks: []Task{claimedTaskRev("c1", 7, "rev-2")}, FetchedAt: time.Unix(20, 0)},
		details: DetailIndex{},
	})
	if m.resyncClose != "c1" {
		t.Fatalf("resyncClose = %q after the refresh — the re-read cancelled the recovery it was supposed to enable", m.resyncClose)
	}
	m = cursorToDoc(t, m, "c1")

	// ── leg 3: the retry, pinned to the revision that was re-read ──────────
	m, res = pressCloseTwice(t, m)
	if !res.OK {
		t.Fatalf("the observed_rev retry did not land: %q", res.Message)
	}
	got := d.attempts()
	if len(got) != 2 {
		t.Fatalf("close attempts = %q, want 2 (the fenced attempt, then the pinned retry)", got)
	}
	if got[1] != "rev-2" {
		t.Errorf("retry observed_rev = %q, want rev-2 — the close must pin the revision the user re-read", got[1])
	}
	if landed, rev := d.landed(); !landed || rev != "rev-2" {
		t.Errorf("server landed=%v at rev %q, want a close at rev-2 exactly", landed, rev)
	}
	if m.resyncClose != "" {
		t.Error("a landed close left the observed_rev bypass armed — the next close would skip the work-digest fence")
	}
}

// THE SAFETY HALF of the same contract: the retry closes ONLY at the revision
// that was re-read. A SECOND concurrent edit landing after the refresh moves the
// document to rev-3, and the retry — still pinned to the rev-2 the user actually
// read — is REFUSED by the rev CAS rather than overwriting the newer brief.
//
// This is the property a just-in-time "fetch the current rev and close with it"
// implementation would fail: it would pick up rev-3 and close over a brief
// nobody looked at. The board pins the rev ON SCREEN precisely so it cannot.
func TestCloseDriftRefusesWhenASecondEditLandsAfterTheReRead(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "opus-9")
	d, srv := newDriftServer(t, "rev-2")
	defer srv.Close()

	m := testModel(activeOrphans(claimedTaskRev("c1", 7, "rev-1")))
	m.client = testClient(srv.URL)
	m.now = func() time.Time { return time.Unix(10, 0) }
	m = cursorToDoc(t, m, "c1")

	m, res := pressCloseTwice(t, m) // fenced refusal arms the recovery
	if res.OK || m.resyncClose != "c1" {
		t.Fatalf("expected an armed drift refusal, got OK=%v resyncClose=%q", res.OK, m.resyncClose)
	}

	// The user re-reads rev-2 …
	m, _ = step(t, m, snapshotMsg{
		snap:    Snapshot{Tasks: []Task{claimedTaskRev("c1", 7, "rev-2")}, FetchedAt: time.Unix(20, 0)},
		details: DetailIndex{},
	})
	m = cursorToDoc(t, m, "c1")
	// … and somebody edits the brief AGAIN, out from under that read.
	d.edit("rev-3")

	m, res = pressCloseTwice(t, m)
	if res.OK {
		t.Fatal("the close landed over an edit the user never read — the rev CAS must refuse it")
	}
	got := d.attempts()
	if len(got) != 2 || got[1] != "rev-2" {
		t.Fatalf("close attempts = %q, want the retry pinned to the re-read rev-2 (never a freshly-fetched rev-3)", got)
	}
	if landed, rev := d.landed(); landed {
		t.Fatalf("server closed the task at rev %q — a concurrent edit was overwritten", rev)
	}
	if !strings.Contains(res.Message, "stale") {
		t.Errorf("refusal = %q, want the server's honest stale-claim reason", res.Message)
	}
	// Still armed: the answer to "someone edited again" is another re-read, not a
	// silent fallback to the rev-less close that can only 409.
	if m.resyncClose != "c1" {
		t.Errorf("resyncClose = %q after the CAS refusal, want c1 (still recoverable by another re-read)", m.resyncClose)
	}
}

// The bypass is NARROW: a row the server never refused with
// doc_changed_since_claim closes rev-less, so the work-digest fence protects it.
// (Arming pre-emptively is exactly the regression the cmux Stop hook was fixed
// for — it made the hook the one closer the fence never covered.)
func TestOrdinaryCloseSendsNoObservedRev(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "opus-9")
	d, srv := newDriftServer(t, "rev-2")
	defer srv.Close()

	m := testModel(activeOrphans(claimedTaskRev("c1", 7, "rev-2")))
	m.client = testClient(srv.URL)
	m.now = func() time.Time { return time.Unix(10, 0) }
	m = cursorToDoc(t, m, "c1")

	// The row's Rev MATCHES the server's current rev, so a pre-emptive bypass
	// would have closed cleanly — the assertion below is not vacuous.
	m, res := pressCloseTwice(t, m)
	if res.OK {
		t.Fatal("a first close must ride the work-digest fence, and this server's fence refuses it")
	}
	if got := d.attempts(); len(got) != 1 || got[0] != "" {
		t.Fatalf("close attempts = %q, want one rev-less attempt", got)
	}
	if landed, _ := d.landed(); landed {
		t.Fatal("the fence was bypassed on a close the server never refused")
	}
}
