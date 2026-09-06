package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE BUG THIS PINS, in one sentence: the suggestion walk paid its page latency
// SERIALLY, so on the real ledger it ran out of deadline before it ran out of
// pages, and `bp task get <a-real-prefix>` and `bp task get <a-bogus-id>`
// printed the SAME "no close-id scan was made" line — the one distinction the
// caller needed was the one the walk could not make.
//
// MEASURED 2026-09-05 against guerrilla.barkpark.cloud: 8,565 task rows, nine
// pages at limit=1000&view=brief, 1.01s / 1.54s / 0.86s per page. Nine of those
// end to end is ~9-13s against a 6s deadline — not a risk of abandoning, a
// certainty of it.
//
// The fixture reproduces exactly that shape and nothing else: nine pages, each
// page deliberately slow, and a deadline that a serial walk CANNOT meet but
// three concurrent waves can. It is a real timing claim, so it is built with
// margin on both sides — serial needs 9*perPage, the deadline allows barely
// more than 4*perPage, and the concurrent walk needs 3*perPage.
//
// RED WITHOUT the change: the serial walk trips the deadline on page ~4 and
// returns ("", false) — no suggestion, and the not_found hint says no scan was
// made. GREEN WITH it: the walk reads all nine pages inside the bound and names
// the single extending id.
func TestTaskPrefixSuggestion_FinishesALedgerTooBigToWalkOnePageAtATime(t *testing.T) {
	const (
		pages     = 9
		perPage   = 120 * time.Millisecond
		lastRows  = 565 // the live ledger's own short final page
		theNeedle = "cchi-w67-bl-the-only-id-that-extends-the-typed-prefix"
		typed     = "cchi-w67-bl-the-only"
	)

	// The deadline is the whole point of the test, so it is chosen against the
	// two walks it must discriminate, not by taste:
	//   serial:     9 pages * 120ms = 1080ms  -> must NOT fit
	//   concurrent: 3 waves * 120ms =  360ms  -> must fit
	// 600ms sits between them with ~1.7x headroom either way.
	restore := taskSuggestDeadline
	taskSuggestDeadline = 600 * time.Millisecond
	t.Cleanup(func() { taskSuggestDeadline = restore })

	var inFlight, peak int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// This fixture models a server WITHOUT `?id_prefix=` (the pre-filter
		// box the walk exists for). Such a server fail-closes on the unknown
		// param with an instant 400 — it never pages for it — so the probe
		// costs no perPage here, exactly as it costs none in production.
		if r.URL.Query().Get(taskIDPrefixParam) != "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"code":"invalid_filter","message":"unknown query param id_prefix on GET /v1/tasks"}}`))
			return
		}
		cur := atomic.AddInt64(&inFlight, 1)
		for {
			old := atomic.LoadInt64(&peak)
			if cur <= old || atomic.CompareAndSwapInt64(&peak, old, cur) {
				break
			}
		}
		time.Sleep(perPage)
		atomic.AddInt64(&inFlight, -1)

		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		page := offset / taskSuggestPageSize
		n := taskSuggestPageSize
		switch {
		case page == pages-1:
			n = lastRows // short page: this is what proves the walk saw the end
		case page >= pages:
			n = 0
		}
		rows := make([]map[string]string, 0, n)
		for i := 0; i < n; i++ {
			id := fmt.Sprintf("filler-%02d-%05d", page, i)
			// The needle lives on the LAST page, so a walk that gives up early
			// cannot stumble onto the right answer for the wrong reason.
			if page == pages-1 && i == 400 {
				id = theNeedle
			}
			rows = append(rows, map[string]string{"doc_id": id, "title": "t"})
		}
		w.Header().Set("Content-Type", "application/json")
		body, _ := json.Marshal(map[string]any{"ok": true, "docs": rows})
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	start := time.Now()
	got, complete := taskPrefixSuggestion(nil, matchManifest(), manifest.Context{Server: srv.URL}, typed)
	elapsed := time.Since(start)

	if !complete {
		t.Fatalf("the walk abandoned after %s — a %d-page ledger at %s per page does not fit a %s deadline one page at a time, which is the whole defect",
			elapsed, pages, perPage, taskSuggestDeadline)
	}
	if got != theNeedle {
		t.Fatalf("suggestion = %q, want %q", got, theNeedle)
	}
	if elapsed > taskSuggestDeadline {
		t.Fatalf("the walk took %s, past its own %s bound", elapsed, taskSuggestDeadline)
	}
	// Not just "fast enough" — actually overlapped. A future change that made
	// the pages merely cheaper would satisfy the timing assertions above while
	// quietly restoring the serial shape this exists to prevent.
	if p := atomic.LoadInt64(&peak); p < 2 {
		t.Fatalf("peak concurrent pages = %d, want at least 2 — the walk is still serial", p)
	}
}

// The two sides of c2, asserted TOGETHER on one ledger, because the defect was
// never in either message alone — it was that a real prefix and a bogus id
// produced the SAME line, so the reader could not tell "you truncated an id"
// from "that row does not exist".
func TestTaskGetNotFoundHint_TellsAPrefixApartFromAnAbsence(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{
		{DocID: "cchi-w67-bl-bp-task-ls-has-no-status-filter", Title: "the real row"},
		{DocID: "unrelated-row-one", Title: "x"},
		{DocID: "unrelated-row-two", Title: "y"},
	})

	prefixHint := taskGetNotFoundHint(nil, matchManifest(), manifest.Context{Server: srv.URL}, "cchi-w67-bl-bp-task-ls")
	absentHint := taskGetNotFoundHint(nil, matchManifest(), manifest.Context{Server: srv.URL}, "zzz-no-such-row-anywhere-12345")

	if prefixHint == absentHint {
		t.Fatalf("a truncated id and a bogus id produced the SAME hint, so neither is an answer:\n%s", prefixHint)
	}
	if !strings.Contains(prefixHint, "cchi-w67-bl-bp-task-ls-has-no-status-filter") {
		t.Fatalf("the prefix hint does not name the id it is a prefix OF:\n%s", prefixHint)
	}
	if !strings.Contains(prefixHint, "did you mean") {
		t.Fatalf("the prefix hint does not read as a suggestion:\n%s", prefixHint)
	}
	// The absence side must NOT claim a scan was skipped: this ledger is one
	// page, the walk completed, and "no such row" is a claim it has earned.
	if strings.Contains(absentHint, "no close-id scan was made") {
		t.Fatalf("the walk completed but the hint still reports an abandoned scan:\n%s", absentHint)
	}
	if strings.Contains(absentHint, "did you mean") {
		t.Fatalf("the absent-id hint invented a suggestion:\n%s", absentHint)
	}
}
