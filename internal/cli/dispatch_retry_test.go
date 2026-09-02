package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE DEFECT THESE LOCK (cchi-bl-bp-dispatch-has-no-transient-500-retry).
//
// guerrilla answered internal_error on roughly a third of task-route calls
// through 2026-09-01/02. `bp` had a retry — internal/apiclient/retry.go — and
// used it for exactly one request, the /v1/capabilities fetch. Every
// manifest-dispatched verb rode a bare http.Client in run.go and died on the
// first 500, so four agents wrapped every bp call in a hand-written shell retry
// loop while the binary printed "transient internal_error … retrying" one line
// earlier for the capabilities call it had just survived.
//
// The tests below drive the REAL dispatch (runCommand / runPaginatedAll), not
// the transport in isolation: a transport that retries beautifully while the
// CLI never reaches it is precisely the state main was already in.

// captureOSStderr runs fn with os.Stderr redirected to a pipe and returns what
// was written to it. The retry and give-up notices go to the PROCESS stderr
// (apiclient's notifiers), not to the writer's buffer, so a test that only
// inspects the writer sees none of them and would pass with the announcements
// deleted.
func captureOSStderr(t *testing.T, fn func()) string {
	t.Helper()
	saved := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stderr = w
	done := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(r)
		done <- string(b)
	}()
	defer func() {
		os.Stderr = saved
		_ = r.Close()
	}()
	fn()
	_ = w.Close()
	return <-done
}

// transientFault is the exact envelope the incident served: HTTP 500, error
// code internal_error, a per-request id. The id VARIES per attempt on purpose —
// it is how the give-up line is proven to name the LAST attempt rather than the
// first, which is the id a caller would otherwise quote to support.
func transientFault(w http.ResponseWriter, attempt int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusInternalServerError)
	_, _ = fmt.Fprintf(w,
		`{"ok":false,"error":{"code":"internal_error","message":"unknown error (DBConnection.ConnectionError)","request_id":"req-%d"}}`,
		attempt)
}

// ─── Criterion 1: GET dispatch retries, announces, and names the last id ────

// A GET that fails twice and then answers must reach the caller as the ANSWER,
// with one stderr line per retry. Before the fix this exited nonzero on the
// first 500 without a single retry line.
func TestGetDispatchRetriesTransientFiveHundred(t *testing.T) {
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := int(requests.Add(1))
		if n <= 2 {
			transientFault(w, n)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"docs":[{"id":"t1"}]}`))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "json", outputSet: true}
	out.applyGlobals(g)

	var code int
	procErr := captureOSStderr(t, func() {
		code = runCommand(out, g, manifest.Context{Server: srv.URL}, &manifest.Manifest{},
			nonPaginatedReadCommand(), nil)
	})

	if code != exitOK {
		t.Fatalf("exit = %d, want %d — the third attempt answered; stdout=%q writerErr=%q procErr=%q",
			code, exitOK, stdout.String(), stderr.String(), procErr)
	}
	if got := requests.Load(); got != 3 {
		t.Errorf("server saw %d requests, want 3 (two faults + the answer)", got)
	}
	if !strings.Contains(stdout.String(), "t1") {
		t.Errorf("the answer never reached stdout: %q", stdout.String())
	}
	// One line per retry, and exactly two — a retry that announces itself is
	// the only signal anyone has that the server is sick.
	if n := strings.Count(procErr, "transient internal_error"); n != 2 {
		t.Errorf("stderr carried %d retry lines, want 2:\n%s", n, procErr)
	}
	if !strings.Contains(procErr, "attempt 1 of 3") || !strings.Contains(procErr, "attempt 2 of 3") {
		t.Errorf("retry lines do not number the attempts:\n%s", procErr)
	}
	// A sequence that RECOVERED must not also claim it gave up.
	if strings.Contains(procErr, "giving up") {
		t.Errorf("a recovered sequence announced a give-up:\n%s", procErr)
	}
}

// A GET that never recovers must refuse by name and name the LAST attempt's
// request_id. The first attempt's id points at a request the server has already
// forgotten; quoting it to support explains nothing.
func TestGetDispatchRefusesByNameAfterTheCap(t *testing.T) {
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		transientFault(w, int(requests.Add(1)))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "json", outputSet: true}
	out.applyGlobals(g)

	var code int
	procErr := captureOSStderr(t, func() {
		code = runCommand(out, g, manifest.Context{Server: srv.URL}, &manifest.Manifest{},
			nonPaginatedReadCommand(), nil)
	})

	if code == exitOK {
		t.Fatalf("exit 0 on a permanently failing server; stdout=%q", stdout.String())
	}
	if got := requests.Load(); got != 3 {
		t.Errorf("server saw %d requests, want 3 (the attempt cap, not more)", got)
	}
	if !strings.Contains(procErr, "giving up") {
		t.Errorf("the exhausted sequence did not announce itself:\n%s", procErr)
	}
	if !strings.Contains(procErr, "last request_id: req-3") {
		t.Errorf("give-up line did not name the LAST attempt's request id:\n%s", procErr)
	}
	if strings.Contains(procErr, "last request_id: req-1") {
		t.Errorf("give-up line named the FIRST attempt's request id:\n%s", procErr)
	}
	// The machine envelope carries the same last id, so a scripted caller and
	// a human reading stderr quote the same request.
	var env struct {
		Error struct {
			Code      string `json:"code"`
			RequestID string `json:"request_id"`
		} `json:"error"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not the machine error envelope: %v\n%s", err, stdout.String())
	}
	if env.Error.Code != "internal_error" {
		t.Errorf("refusal code = %q, want internal_error", env.Error.Code)
	}
	if env.Error.RequestID != "req-3" {
		t.Errorf("envelope request_id = %q, want req-3 (the last attempt)", env.Error.RequestID)
	}
}

// ─── The write side: single-shot here, and NOT double-wrapped ──────────────
//
// This PR's write half was DROPPED. It classified writes with a static
// per-verb allowlist ("task.close is epoch-fenced, so a repeat is safe") and
// retried the ones on it. #15002 landed something strictly stronger on main —
// internal/cli/tasks_write_retry.go — which retries every task LEDGER write
// (claim/next/close/stamp/pulse/release) and RE-READS the store before every
// retry, so it never re-sends a write that already landed instead of reasoning
// about whether a re-send would be survivable. The two tests below hold the
// boundary that re-scoping leaves behind.

// nonLedgerWriteCommand is a POST that neither policy covers: not GET/HEAD, so
// the transport retry declines it, and not a ledger verb, so no ledgerWrite is
// attached. It must reach the server exactly once, as it always did.
func nonLedgerWriteCommand() manifest.Command {
	return manifest.Command{
		ID:            "doc.create",
		Noun:          "doc",
		Verb:          "create",
		HTTP:          manifest.HTTP{Method: http.MethodPost, PathTemplate: "/docs"},
		Writes:        true,
		DefaultOutput: "minimal",
	}
}

// A write the ledger policy does not own must stay single-shot. A 500 tells the
// client nothing about whether a create landed — this is the incident's own
// `bp doc publish`, which returned 500 with the publish already committed — so
// a repeat here files a duplicate row.
func TestNonLedgerWriteIsNotRetried(t *testing.T) {
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		transientFault(w, int(requests.Add(1)))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "json", outputSet: true, yes: true}
	out.applyGlobals(g)

	var code int
	procErr := captureOSStderr(t, func() {
		code = runCommand(out, g, manifest.Context{Server: srv.URL}, &manifest.Manifest{},
			nonLedgerWriteCommand(), nil)
	})

	if code == exitOK {
		t.Fatalf("exit 0 on a 500; stdout=%q", stdout.String())
	}
	if got := requests.Load(); got != 1 {
		t.Fatalf("doc.create was sent %d times, want 1 — a repeated create files a duplicate row", got)
	}
	if strings.Contains(procErr, "transient internal_error") {
		t.Errorf("an unfenced write was retried:\n%s", procErr)
	}
}

// NO DOUBLE-WRAP. sendLedgerWrite sends through doRequestFull, and its safety
// comes from re-reading the store between attempts. If doRequestFull also rode
// the retry transport, a single ledger attempt would silently become three
// unvetted ones underneath the policy that thinks it is counting — so
// doRequestFull is single-shot even for a GET, which is the one method the
// transport WOULD have retried. That asymmetry with doRequestCT is the test.
func TestLedgerWriteSendIsSingleShot(t *testing.T) {
	var full, ct atomic.Int32
	fullSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		transientFault(w, int(full.Add(1)))
	}))
	defer fullSrv.Close()
	ctSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		transientFault(w, int(ct.Add(1)))
	}))
	defer ctSrv.Close()

	captureOSStderr(t, func() {
		if _, _, _, _, err := doRequestFull(http.MethodGet, fullSrv.URL, nil, nil); err != nil {
			t.Errorf("doRequestFull: %v", err)
		}
		if _, _, _, err := doRequestCT(http.MethodGet, ctSrv.URL, nil, nil); err != nil {
			t.Errorf("doRequestCT: %v", err)
		}
	})

	if got := full.Load(); got != 1 {
		t.Errorf("doRequestFull sent %d requests, want 1 — the ledger write path must not stack a second retry policy", got)
	}
	// The control: the same fault on the same shape of GET IS retried on the
	// dispatch path, so a 1 above means "single-shot", not "the fixture never
	// faulted".
	if got := ct.Load(); got != 3 {
		t.Errorf("doRequestCT sent %d requests, want 3 — the control proves the fault is retryable", got)
	}
}

// ─── Criterion 3: --all retries a PAGE in place, or refuses by name ─────────

// pagedFaultServer serves a two-page collection with the lookahead row the
// --all walk anchors on, and injects transient faults on the page at
// offset=100: `faults` of them, then the honest page.
func pagedFaultServer(t *testing.T, faults int, requests *atomic.Int32) *httptest.Server {
	t.Helper()
	var pageTwoCalls atomic.Int32
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		if offset >= 100 {
			if n := int(pageTwoCalls.Add(1)); n <= faults {
				transientFault(w, n)
				return
			}
		}
		n := limit // page 1 fills the window (100 rows + the lookahead row)
		if offset >= 100 {
			n = 20
		}
		rows := make([]json.RawMessage, n)
		for i := range rows {
			// Ids are keyed on the GLOBAL index so page two opens with exactly
			// the row page one saw one place past its window — the anchor the
			// walk checks.
			rows[i] = json.RawMessage(fmt.Sprintf(`{"id":"r-%d"}`, offset+i))
		}
		body, _ := json.Marshal(map[string]any{"docs": rows})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
}

// A page that faults once is retried IN PLACE and the walk completes whole.
// Before the fix a single transient 500 on page two killed the whole `bp task
// ls --all`.
func TestPaginatedAllRetriesAFailedPage(t *testing.T) {
	var requests atomic.Int32
	srv := pagedFaultServer(t, 1, &requests)
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"

	var code int
	procErr := captureOSStderr(t, func() {
		code = runPaginatedAll(out, paginatedReadCommand(100), srv.URL, map[string]string{}, paginatedAllOpts{})
	})

	if code != exitOK {
		t.Fatalf("exit = %d, want %d; writerErr=%q procErr=%q", code, exitOK, stderr.String(), procErr)
	}
	var got map[string][]json.RawMessage
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output not JSON: %v\n%s", err, stdout.String())
	}
	if n := len(got["docs"]); n != 120 {
		t.Errorf("walk returned %d rows, want 120 — a retried page must rejoin the walk whole", n)
	}
	if !strings.Contains(procErr, "transient internal_error") {
		t.Errorf("the page retry was silent:\n%s", procErr)
	}
	// The retry must be scoped to the FAILING page, not a restart of the walk.
	if n := requests.Load(); n != 3 {
		t.Errorf("server saw %d requests, want 3 (page 1, page 2's fault, page 2's retry)", n)
	}
}

// A page that never recovers must refuse BY NAME, printing no rows at all.
// A short list at exit 0 is the failure this whole walk was hardened against:
// it is well-formed, correctly ordered, and wrong in the direction that looks
// safe.
func TestPaginatedAllRefusesAPageItCouldNotFetch(t *testing.T) {
	var requests atomic.Int32
	srv := pagedFaultServer(t, 99, &requests) // page two never answers
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"

	var code int
	procErr := captureOSStderr(t, func() {
		code = runPaginatedAll(out, paginatedReadCommand(100), srv.URL, map[string]string{}, paginatedAllOpts{})
	})

	if code == exitOK {
		t.Fatalf("a walk that lost a page exited 0; stdout=%q", stdout.String())
	}
	both := stdout.String() + stderr.String()
	if !strings.Contains(both, "internal_error") {
		t.Errorf("the refusal did not name the fault: %q", both)
	}
	// Not one row of page one may be printed as though the list were complete.
	if strings.Contains(stdout.String(), `"r-0"`) {
		t.Errorf("a partial list reached stdout: %q", stdout.String())
	}
	if !strings.Contains(procErr, "giving up") {
		t.Errorf("the exhausted page did not announce itself:\n%s", procErr)
	}
	if !strings.Contains(procErr, "last request_id: req-3") {
		t.Errorf("the page refusal did not name the LAST attempt's request id:\n%s", procErr)
	}
}
