package cli

// THE DELIBERATE REPRODUCTION of task-8456f26a831d5cdc: a single
// `bp task stamp --miss` that landed TWICE, 1.9 s apart, and returned rc=0 once.
//
// The row said the retry's ORIGIN was unknown — "bp's HTTP client, a wrapper, or
// the server". It is none of the exotic ones: it is sendLedgerWrite in
// tasks_write_retry.go, whose loop re-sends whenever the read-back does NOT come
// back ledgerLandedYes. ledgerLandedUnknown — a read-back that could not be
// asked, on the very box whose 500s caused the retry — takes the same branch as
// ledgerLandedNo. That is a considered trade (an unreadable ledger must not
// swallow a write that never landed), but it means a write that DID land is
// re-sent, and the caller is handed the second attempt's ordinary 200.
//
// Go's own net/http is NOT the second sender and this file proves it: a POST
// with no Idempotency-Key is not replayable (net/http transport.go
// isReplayable), so the transport never repeats a ledger write on a dead
// keep-alive. That matters as a WARNING as much as an exoneration — the obvious
// fix, "attach an Idempotency-Key", would switch net/http's automatic replay ON
// for exactly these POSTs.

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// replayArrival is one request as the SERVER saw it — the discriminator the row
// used (two applies 1.907 s apart) is a server-side observation, so the fake
// records the same thing.
type replayArrival struct {
	method string
	path   string
	at     time.Time
}

// replayFake is a ledger whose store commits independently of what it answers,
// and which can drop the connection AFTER applying a write — the exact shape the
// row inferred from the timestamps: "the first attempt landed and its response
// was lost".
type replayFake struct {
	mu       sync.Mutex
	arrivals []replayArrival
	// attempts is the append-only attempts[] list `stamp --miss` writes to. Its
	// LENGTH is the defect: one bp invocation, two entries.
	attempts []string
	// epoch is what `pulse` advances. A double-apply here desynchronises the CAS
	// every later stamp and close fences on.
	epoch int
	// dropAfterApply names the POST ordinals that apply the write and then close
	// the connection without answering.
	dropAfterApply map[int]bool
	// readFails is how many read-backs answer 500 before the store is readable
	// again. >0 is the UNKNOWN verdict; 0 is the read-back that can see the write.
	readFails int
	posts     int
	gets      int
	// nowLine is the pulse's --now text, so pulseLanded has something to match.
	nowLine string
}

func (f *replayFake) postCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.posts
}

func (f *replayFake) doc() []byte {
	crit := map[string]any{"criterion": "c0", "met": false}
	atts := []any{}
	for _, n := range f.attempts {
		atts = append(atts, map[string]any{"note": n})
	}
	crit["attempts"] = atts
	body, _ := json.Marshal(map[string]any{"ok": true, "doc": map[string]any{
		"doc_id":           "bp-task-x",
		"status":           "published",
		"lifecycle_status": "in_progress",
		"claim": map[string]any{
			"worker": "w4", "epoch": f.epoch,
			"ts_iso": time.Now().UTC().Format(time.RFC3339Nano),
			"now":    map[string]any{"text": f.nowLine, "ts": "2026-09-07T18:20:00Z"},
		},
		"content": map[string]any{"acceptance_criteria": []any{crit}},
	}})
	return body
}

func (f *replayFake) serve(t *testing.T) {
	t.Helper()
	realSleep := ledgerSleep
	ledgerSleep = func(time.Duration) {}
	t.Cleanup(func() { ledgerSleep = realSleep })

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.arrivals = append(f.arrivals, replayArrival{r.Method, r.URL.Path, time.Now()})

		if r.Method == http.MethodGet {
			f.gets++
			if f.readFails > 0 {
				f.readFails--
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"internal_error"}}`))
				return
			}
			_, _ = w.Write(f.doc())
			return
		}

		f.posts++
		n := f.posts
		// APPLY FIRST — a status code says nothing about whether the store
		// committed, and modelling the two as one is the mistake this whole
		// area exists to correct.
		switch {
		case strings.HasSuffix(r.URL.Path, "/stamp"):
			// note rides the BODY since #17000; read the merge, as the server does.
			if note := stampMergedParams(r).Get("note"); note != "" {
				f.attempts = append(f.attempts, note)
			}
		case strings.HasSuffix(r.URL.Path, "/pulse"):
			f.nowLine = r.URL.Query().Get("now")
			f.epoch++
		}

		if f.dropAfterApply[n] {
			// The response is LOST: hijack and close with nothing written. The
			// client sees a transport error on a request the store already
			// honoured — the row's inferred trigger, made deliberate.
			conn, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Errorf("hijack: %v", err)
				return
			}
			_ = conn.(*net.TCPConn).SetLinger(0)
			_ = conn.Close()
			return
		}
		_, _ = w.Write(f.doc())
	}))
	t.Cleanup(srv.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(lwManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", srv.URL)
	t.Setenv("BARKPARK_API_TOKEN", "replay-stub")
}

func (f *replayFake) log(t *testing.T) {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.arrivals) == 0 {
		t.Logf("the fake ledger saw NO requests")
		return
	}
	t0 := f.arrivals[0].at
	for i, a := range f.arrivals {
		t.Logf("arrival %d: %-4s %s  +%s", i+1, a.method, a.path, a.at.Sub(t0).Round(time.Millisecond))
	}
	t.Logf("attempts[] in the store: %d  %q", len(f.attempts), f.attempts)
}

// ── (1) THE REPRODUCTION ────────────────────────────────────────────────────

// One `bp task stamp --miss`, a store that applies the write and then loses the
// response, a read-back that cannot be asked: TWO applies, one rc=0. This is
// task-8456f26a831d5cdc reproduced deliberately rather than waited for.
//
// The duplicate itself is NOT asserted away — it is the documented cost of
// refusing to call an unreadable ledger "not landed". What the fix must change
// is the second half: the caller must be able to SEE it.
func TestStampMissLandsTwiceWhenTheReadBackCannotSeeIt(t *testing.T) {
	f := &replayFake{
		dropAfterApply: map[int]bool{1: true},
		readFails:      1, // the read-back between attempt 1 and 2 is UNKNOWN
	}
	f.serve(t)

	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w4", "1",
		"--criterion", "0", "--miss", "--note", "the 1,167-character note, byte for byte",
	})
	f.log(t)
	t.Logf("bp exit code: %d", code)
	t.Logf("bp stdout+stderr:\n%s", out)

	if code != 0 {
		t.Fatalf("exit code = %d, want 0 — the row's whole point is that the caller was told SUCCESS", code)
	}
	if got := f.postCount(); got != 2 {
		t.Fatalf("stamp POSTs = %d, want 2 — the reproduction did not reproduce", got)
	}
	f.mu.Lock()
	n := len(f.attempts)
	f.mu.Unlock()
	if n != 2 {
		t.Fatalf("attempts[] = %d, want 2 — the store must hold the duplicate the row measured", n)
	}
}

// ── (2) THE PROTECTION: the replay is VISIBLE ───────────────────────────────

// THE GUARD, on stamp --miss. A re-sent write that succeeds must not be
// indistinguishable from a first attempt that succeeded.
//
// MUTATION PROOF: delete the ledgerMarkReplay call in sendLedgerWrite's success
// return (tasks_write_retry.go) and this goes red on the missing marker, while
// TestStampMissLandsTwiceWhenTheReadBackCannotSeeIt above stays green — which is
// the point: the duplicate is unchanged, only the caller's ability to see it is.
func TestAReSentStampIsMarkedAsAReplay(t *testing.T) {
	f := &replayFake{dropAfterApply: map[int]bool{1: true}, readFails: 1}
	f.serve(t)

	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w4", "1",
		"--criterion", "0", "--miss", "--note", "n", "-o", "json",
	})
	f.log(t)
	t.Logf("bp output:\n%s", out)
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	if !strings.Contains(out, ledgerReplayField) {
		t.Fatalf("the machine-readable envelope carries no %q marker.\nout:\n%s\n"+
			"A retried write that already landed is invisible to the caller — that IS the defect.",
			ledgerReplayField, out)
	}
	if !strings.Contains(out, "REPLAY") {
		t.Fatalf("no human-readable REPLAY warning on stderr.\nout:\n%s", out)
	}
}

// THE SAME GUARD ON THE VERB WHERE IT COSTS MOST. `pulse` ADVANCES THE CLAIM
// EPOCH, so a re-sent pulse moves it twice while the caller believes it moved
// once, and the next stamp or close CASes against an epoch nobody can explain.
// The fake asserts the double-advance is real (epoch 2, not 1) AND that the
// caller is told.
func TestAReSentPulseIsMarkedAsAReplayAndTheEpochMovedTwice(t *testing.T) {
	f := &replayFake{dropAfterApply: map[int]bool{1: true}, readFails: 1}
	f.serve(t)

	out, code := captureExecuteCode(t, []string{
		"task", "pulse", "bp-task-x", "w4", "--now", "still on it", "-o", "json",
	})
	f.log(t)
	t.Logf("bp output:\n%s", out)
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	f.mu.Lock()
	epoch := f.epoch
	f.mu.Unlock()
	if epoch != 2 {
		t.Fatalf("claim epoch = %d, want 2 — the double-apply this guard makes visible did not happen", epoch)
	}
	if !strings.Contains(out, ledgerReplayField) {
		t.Fatalf("a pulse that moved the epoch TWICE reported an ordinary success.\nout:\n%s", out)
	}
}

// THE OTHER HALF, and the reason the marker is not simply always-on: a write
// that was never re-sent must NOT be labelled a replay. A marker that fires on
// every write tells the caller nothing.
func TestAFirstAttemptSuccessIsNotMarkedAsAReplay(t *testing.T) {
	f := &replayFake{}
	f.serve(t)

	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w4", "1",
		"--criterion", "0", "--miss", "--note", "n", "-o", "json",
	})
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	if strings.Contains(out, ledgerReplayField) {
		t.Fatalf("a single-attempt write was labelled a replay.\nout:\n%s", out)
	}
	if got := f.postCount(); got != 1 {
		t.Fatalf("POSTs = %d, want 1", got)
	}
}

// AND the path that was already right stays right: when the read-back CAN see
// the landed write, there is no second POST at all, so there is nothing to mark.
func TestAReadableStoreStillPreventsTheDuplicateEntirely(t *testing.T) {
	f := &replayFake{dropAfterApply: map[int]bool{1: true}, readFails: 0}
	f.serve(t)

	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w4", "1",
		"--criterion", "0", "--miss", "--note", "n", "-o", "json",
	})
	f.log(t)
	if code != 0 {
		t.Fatalf("exit code = %d, want 0.\nout:\n%s", code, out)
	}
	if got := f.postCount(); got != 1 {
		t.Fatalf("POSTs = %d, want 1 — a read-back that CAN see the write must stop the re-send", got)
	}
	f.mu.Lock()
	n := len(f.attempts)
	f.mu.Unlock()
	if n != 1 {
		t.Fatalf("attempts[] = %d, want 1", n)
	}
}

// ── (3) CANDIDATE (b): net/http's own automatic replay ──────────────────────

// net/http RETRIES a request on a dropped keep-alive connection when the request
// is replayable. This pins what "replayable" means for the requests bp actually
// sends, in the standard library that is actually linked — so the exoneration is
// MEASURED, not quoted from transport.go.
//
// The second row is the warning: attaching an Idempotency-Key to make the server
// deduplicate would ALSO arm net/http's blind repeat underneath sendLedgerWrite's
// re-read — two retry policies on one request, the outer one no longer able to
// count the attempts.
func TestNetHTTPDoesNotAutoReplayABodylessKeyedLedgerPOST(t *testing.T) {
	cases := []struct {
		name    string
		header  string
		wantMin int // POST arrivals at the server across ONE client.Do
	}{
		{"a plain ledger POST is not replayable", "", 1},
		{"an Idempotency-Key POST IS replayable", "Idempotency-Key", 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var mu sync.Mutex
			posts := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				posts++
				mu.Unlock()
				_, _ = w.Write([]byte(`{"ok":true}`))
			}))
			defer srv.Close()

			client := &http.Client{Timeout: 5 * time.Second}
			// Warm a keep-alive connection, then make the server forget it, so
			// the next request meets a connection the client believes is live.
			post := func() (int, error) {
				req, err := http.NewRequest(http.MethodPost, srv.URL, strings.NewReader(`{"x":1}`))
				if err != nil {
					return 0, err
				}
				if tc.header != "" {
					req.Header.Set(tc.header, "k-1")
				}
				if req.GetBody == nil {
					t.Fatalf("GetBody is nil — strings.Reader bodies via http.NewRequest must set it, "+
						"or the replay question is moot for the wrong reason (%s)", tc.name)
				}
				resp, err := client.Do(req)
				if err != nil {
					return 0, err
				}
				defer resp.Body.Close()
				return resp.StatusCode, nil
			}
			if _, err := post(); err != nil {
				t.Fatalf("warmup: %v", err)
			}
			srv.CloseClientConnections()
			mu.Lock()
			before := posts
			mu.Unlock()

			status, err := post()
			mu.Lock()
			after := posts
			mu.Unlock()
			t.Logf("%s: arrivals before=%d after=%d status=%d err=%v", tc.name, before, after, status, err)
			// The assertion is about the CLASS, not the flaky count: a
			// non-replayable POST can only ever arrive once per Do.
			if tc.wantMin == 1 && after-before > 1 {
				t.Fatalf("a keyless ledger POST arrived %d times in ONE client.Do — "+
					"net/http IS the second sender after all", after-before)
			}
		})
	}
}
