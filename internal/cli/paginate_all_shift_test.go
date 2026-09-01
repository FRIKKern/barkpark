package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-406343e4f378cbdf — "bp task ready --all intermittently omits a row it
// must return". Measured 2026-07-31: a convergence pass joined `ready --all`
// against the paged corpus and read claimable-and-closed = 0 while a row that
// was open, claimable and present in BOTH corpora sat in the ledger; an
// identical run over the same unchanged data returned 1.
//
// The mechanism is not truncation and not a timeout. `/v1/tasks/ready` applies
// limit/offset to an ordinary ordered SELECT that the server re-evaluates on
// every request (api/lib/barkpark/tasks/queue.ex — order_by priority,
// inserted_at, id; no snapshot, no cursor), and membership is decided by
// mutable columns (content.lifecycle_status, content.claim.worker). So a row
// leaving the set BEFORE the boundary between two pages shifts every later row
// back one place, and the row that was AT the boundary is served by no page at
// all. The envelope carries no total to check the walk against, and the stall
// guard only catches a page that REPEATS — a shift produces no repeat. The
// short list therefore arrived ordered, well-formed and exit 0.
//
// These fakes model exactly that: an ordered list the handler re-slices per
// request, whose membership changes between requests.

// readyCorpus is a ready queue as the server serves it — an ordered list that
// can lose a row between two requests, the way one `bp task next` by another
// agent removes a row from the claimable set mid-walk.
type readyCorpus struct {
	mu      sync.Mutex
	ids     []string
	walks   int   // incremented whenever a walk asks for offset 0
	offsets []int // every offset requested, in order
	limits  []int // every limit requested, in order
}

func newReadyCorpus(n int) *readyCorpus {
	c := &readyCorpus{ids: make([]string, 0, n)}
	for i := 0; i < n; i++ {
		c.ids = append(c.ids, fmt.Sprintf("task-%03d", i))
	}
	return c
}

func (c *readyCorpus) holds(id string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, have := range c.ids {
		if have == id {
			return true
		}
	}
	return false
}

func (c *readyCorpus) size() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.ids)
}

// serve builds the httptest handler. claimBeforePage is called with the offset
// about to be served and the current walk number, and may mutate c.ids under
// the lock — that IS the concurrent claim.
func (c *readyCorpus) serve(claimBeforePage func(c *readyCorpus, offset, walk int)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		c.mu.Lock()
		defer c.mu.Unlock()
		if offset == 0 {
			c.walks++
		}
		c.offsets = append(c.offsets, offset)
		c.limits = append(c.limits, limit)
		if claimBeforePage != nil {
			claimBeforePage(c, offset, c.walks)
		}
		rows := []json.RawMessage{}
		for i := offset; i < offset+limit && i < len(c.ids); i++ {
			rows = append(rows, json.RawMessage(fmt.Sprintf(
				`{"id":"uuid-%s","doc_id":%q,"lifecycle_status":"open"}`, c.ids[i], c.ids[i])))
		}
		body, _ := json.Marshal(map[string]any{"docs": rows})
		_, _ = w.Write(body)
	}
}

// dropAt removes one id from the middle of the set. Caller holds the lock.
func (c *readyCorpus) dropAt(i int) {
	if i < 0 || i >= len(c.ids) {
		return
	}
	c.ids = append(append([]string{}, c.ids[:i]...), c.ids[i+1:]...)
}

func servedDocIDs(t *testing.T, stdout []byte) []string {
	t.Helper()
	var got struct {
		Docs []struct {
			DocID string `json:"doc_id"`
		} `json:"docs"`
	}
	if err := json.Unmarshal(stdout, &got); err != nil {
		return nil
	}
	ids := make([]string, 0, len(got.Docs))
	for _, d := range got.Docs {
		ids = append(ids, d.DocID)
	}
	return ids
}

// TestRunPaginatedAll_RefusesACollectionThatShiftsUnderTheWalk is the
// reproduction AND the fix's lock. A row (task-005) is claimed away the moment
// the walk crosses the first page boundary, on every attempt — a ledger with a
// hundred agents on it. task-100 never leaves the set, yet the disjoint walk
// serves originals 0..99 on page one and originals 101.. on page two, so
// task-100 is returned by no page.
//
// RED before the fix: exit 0 with 249 of 249 rows "complete" and task-100
// missing — the failure message prints that transcript. GREEN after: the
// lookahead anchor breaks, the walk retries, and the last attempt refuses with
// the named code instead of printing a short list as a whole one.
func TestRunPaginatedAll_RefusesACollectionThatShiftsUnderTheWalk(t *testing.T) {
	corpus := newReadyCorpus(250)
	const victim = "task-100"

	srv := httptest.NewServer(corpus.serve(func(c *readyCorpus, offset, walk int) {
		// One `bp task next` lands as the walk crosses the boundary. It takes a
		// row from BEFORE the boundary, which is what shifts the later rows.
		if offset == 100 && len(c.ids) > 10 {
			c.dropAt(5)
		}
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}, Paginated: true}

	code := runPaginatedAll(out, cmd, srv.URL, map[string]string{})
	if code != exitGeneric {
		served := servedDocIDs(t, stdout.Bytes())
		inResult := false
		for _, id := range served {
			if id == victim {
				inResult = true
			}
		}
		t.Fatalf(""+
			"exit = %d, want %d — the walk printed a short list as if it were complete.\n"+
			"  rows returned by --all: %d\n"+
			"  rows the store still holds: %d\n"+
			"  %q still in the store after the walk: %v\n"+
			"  %q present in the --all result:      %v\n"+
			"  a row that never left the ready set was served by no page, and the reader still exited 0.\n"+
			"  stderr=%q",
			code, exitGeneric, len(served), corpus.size(), victim, corpus.holds(victim), victim, inResult, stderr.String())
	}

	var envelope struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &envelope); err != nil {
		t.Fatalf("error output not JSON: %v\n%s", err, stdout.String())
	}
	if envelope.OK || envelope.Error.Code != "pagination_shifted" {
		t.Fatalf("want the named refusal pagination_shifted, got: %s", stdout.String())
	}
	if !bytes.Contains(stdout.Bytes(), []byte("offset 100")) {
		t.Fatalf("message must name the boundary that moved: %q", envelope.Error.Message)
	}
	// A refusal must not also leak the partial rows it refused to vouch for.
	if bytes.Contains(stdout.Bytes(), []byte(`"doc_id"`)) {
		t.Fatalf("partial rows leaked to stdout beside the refusal: %s", stdout.String())
	}
	// The retry must be BOUNDED. Written as a literal, not as
	// paginationWalkAttempts: this test has to compile — and fail on the
	// assertion, not on an undefined symbol — against the tree that still has
	// the bug.
	if corpus.walks != 3 {
		t.Fatalf("walks = %d, want exactly 3 (the retry must be bounded)", corpus.walks)
	}
}

// TestRunPaginatedAll_RetriesAShiftThatSettles is the OTHER half of "return the
// complete set or fail loudly": a single claim landing mid-walk must not turn
// into a refusal when the next attempt walks a quiet ledger. The result is then
// genuinely complete — every row still in the set, exactly once.
func TestRunPaginatedAll_RetriesAShiftThatSettles(t *testing.T) {
	corpus := newReadyCorpus(250)

	srv := httptest.NewServer(corpus.serve(func(c *readyCorpus, offset, walk int) {
		if walk == 1 && offset == 100 && len(c.ids) > 10 {
			c.dropAt(5)
		}
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}, Paginated: true}

	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitOK {
		t.Fatalf("exit = %d, want %d — a shift that settles must be retried, not refused; stdout=%q stderr=%q",
			code, exitOK, stdout.String(), stderr.String())
	}
	served := servedDocIDs(t, stdout.Bytes())
	if len(served) != corpus.size() {
		t.Fatalf("returned %d rows, want %d (the whole set the store holds)", len(served), corpus.size())
	}
	seen := map[string]int{}
	for _, id := range served {
		seen[id]++
	}
	for id, n := range seen {
		if n != 1 {
			t.Fatalf("row %q served %d times — the walk duplicated a row", id, n)
		}
	}
	// task-100 is the row the un-retried walk dropped. It must be here.
	if seen["task-100"] != 1 {
		t.Fatalf("task-100 missing from a settled walk: %d rows returned, store holds %d", len(served), corpus.size())
	}
	if corpus.walks != 2 {
		t.Fatalf("walks = %d, want 2 (one shift, one clean retry)", corpus.walks)
	}
}

// TestRunPaginatedAll_StableCollectionWalksCleanWithALookahead is the
// non-vacuity guard on the anchor: over a collection that does NOT move, the
// check must never fire, the rows must arrive complete and in global order, and
// the requested OFFSETS must stay 0,100,200 — the #5588 order lock reads those.
// The one wire change is the limit: pageSize+1, because the extra row IS the
// anchor. Without that assertion the guard could go blind and this suite would
// still be green.
func TestRunPaginatedAll_StableCollectionWalksCleanWithALookahead(t *testing.T) {
	corpus := newReadyCorpus(250)
	srv := httptest.NewServer(corpus.serve(nil))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}, Paginated: true}

	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitOK {
		t.Fatalf("exit = %d, want %d (false pagination_shifted on a still collection); stdout=%q stderr=%q",
			code, exitOK, stdout.String(), stderr.String())
	}
	served := servedDocIDs(t, stdout.Bytes())
	if len(served) != 250 {
		t.Fatalf("returned %d rows, want 250", len(served))
	}
	for i, id := range served {
		if want := fmt.Sprintf("task-%03d", i); id != want {
			t.Fatalf("row %d is %q, want %q — pages not concatenated in global order", i, id, want)
		}
	}
	if fmt.Sprint(corpus.offsets) != fmt.Sprint([]int{0, 100, 200}) {
		t.Fatalf("requested offsets = %v, want [0 100 200] (the page schedule must not change)", corpus.offsets)
	}
	for i, limit := range corpus.limits {
		if limit != 101 {
			t.Fatalf("request %d asked for limit %d, want 101 — --all must fetch one row past each page as the anchor, or the shift check is blind", i, limit)
		}
	}
	if stderr.Len() != 0 {
		t.Fatalf("a clean walk must be quiet on stderr, got %q", stderr.String())
	}
}
