package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-3e9b429a93abab79 — "a retrieval limit mistaken for a population". The
// clamp half of this class landed with TestOverCapLimitIsAnnounced; this file
// covers the half that survived it.
//
// THE DEFECT. warnIfDefaultPageMayBeTruncated decided completeness from ROW
// ARITHMETIC — did the page fill, was the limit clamped — and row arithmetic
// is a client-side INFERENCE about a server-side fact. `has_more` is that
// fact. It was reached in exactly one branch (an explicit --limit AND a
// readable `page.limit` clamp), so a page that came back SHORT while the
// server said more rows remained fell through in silence:
//
//	served 40, limit 100, has_more TRUE  -> stderr: <0 bytes>, exit 0
//
// That is the worst reading of the class the row names, because a short page
// is exactly what a small population looks like. The caller concludes "that is
// everything", nothing in the response contradicts them, and the count they
// compute is internally consistent and wrong.
//
// TWO FURTHER HOLES, both proved below:
//   - limit <= 0 (a paginated command declaring no --limit default, called
//     without one) returned BEFORE has_more was read at all.
//   - pageHasMore read only the nested snake_case `page.has_more`. GET
//     /v1/data/query and the search route state the same fact at the TOP level
//     in camelCase (`hasMore`) — and those are the two surfaces whose pages are
//     bounded by response BYTES rather than rows, i.e. the two that can return
//     short while more remains. The reader always answered false for them.
//
// WHAT FAILS IF THE FIX IS REVERTED: every subtest named "...is announced" —
// each asserts a NON-EMPTY stderr on a payload whose page block promises more
// rows. Restoring `if len(rows) < limit { return }` makes all of them read
// zero bytes.
//
// WHY THE FIXTURES CANNOT PASS VACUOUSLY. Each subtest's population EXCEEDS
// the limit under test (that is the whole subject — a fixture smaller than the
// limit could not distinguish a full read from a truncated one), and every
// fixture is first run through the guard's own readers. A payload that stopped
// parsing would red here rather than reporting a clean silence.
func TestShortPageWithServerPromisedMoreIsAnnounced(t *testing.T) {
	paginated := func(defaultLimit any) manifest.Command {
		flags := []manifest.Flag{{Name: "offset", Type: "int", Default: 0}}
		if defaultLimit != nil {
			flags = append(flags, manifest.Flag{Name: "limit", Type: "int", Default: defaultLimit})
		}
		return manifest.Command{
			Noun: "task", Verb: "ls", Paginated: true,
			HTTP:  manifest.HTTP{Method: "GET"},
			Flags: flags,
		}
	}

	// nestedPage is the /v1/tasks envelope: rows under `docs`, page block
	// nested and snake_case. `truePopulation` is recorded to make the subject
	// explicit — it is always larger than the page, which is what makes a
	// truncated read distinguishable from a whole one.
	nestedPage := func(served int, effectiveLimit int, hasMore bool) []byte {
		rows := make([]json.RawMessage, served)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"doc_id":"task-%d"}`, i))
		}
		var next any
		if hasMore {
			next = served
		}
		body, err := json.Marshal(map[string]any{
			"ok": true, "docs": rows,
			"page": map[string]any{
				"limit": effectiveLimit, "offset": 0,
				"returned": served, "has_more": hasMore, "next_offset": next,
			},
		})
		if err != nil {
			t.Fatalf("fixture did not marshal: %v", err)
		}
		return body
	}

	// topLevelPage is the GET /v1/data/query + search envelope: rows under
	// `documents`, and hasMore/nextOffset/count stated at the TOP level in
	// camelCase, with no nested page block at all.
	topLevelPage := func(served int, hasMore bool, total int) []byte {
		rows := make([]json.RawMessage, served)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"id":"paper-%d"}`, i))
		}
		var next any
		if hasMore {
			next = served
		}
		body, err := json.Marshal(map[string]any{
			"documents": rows, "count": total,
			"hasMore": hasMore, "nextOffset": next, "offset": 0,
		})
		if err != nil {
			t.Fatalf("fixture did not marshal: %v", err)
		}
		return body
	}

	run := func(t *testing.T, g globals, cmd manifest.Command, body []byte) string {
		t.Helper()
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "json"
		warnIfDefaultPageMayBeTruncated(out, g, cmd, body)
		if stdout.Len() != 0 {
			t.Errorf("the notice must ride stderr only so -o json stdout stays parseable; stdout=%q", stdout.String())
		}
		return stderr.String()
	}

	// THE ANTI-VACUITY GATE: prove the fixture reaches the code under test.
	mustReach := func(t *testing.T, body []byte, wantRows int, wantHasMore bool) {
		t.Helper()
		rows, key := extractListRows(unwrapResult(body))
		if len(rows) != wantRows {
			t.Fatalf("fixture unreadable: extractListRows got %d rows under %q, want %d — a subtest asserting on this payload would be measuring nothing", len(rows), key, wantRows)
		}
		if got := pageHasMore(unwrapResult(body)); got != wantHasMore {
			t.Fatalf("fixture unreadable: pageHasMore = %v, want %v — the guard would never see this fixture's continuation promise", got, wantHasMore)
		}
	}

	// ---- RED BEFORE THE FIX ------------------------------------------------

	// The measured shape. 40 rows served under a limit of 100, and the server
	// says the population continues. True population > 100 by construction.
	t.Run("a short page the server says continues is announced", func(t *testing.T) {
		body := nestedPage(40, 100, true)
		mustReach(t, body, 40, true)

		got := run(t, globals{limit: 100, limitSet: true}, paginated(100), body)
		if got == "" {
			t.Fatalf("SILENT on a short page with has_more true: 40 rows served, server promises more. A caller reads 40 as the population — this is the defect task-3e9b429a93abab79 names")
		}
		if !strings.Contains(got, "has_more") {
			t.Errorf("notice does not cite the field it is reporting; got %q", got)
		}
		if !strings.Contains(got, "--all") && !strings.Contains(got, "--offset") {
			t.Errorf("notice names no remedy; got %q", got)
		}
	})

	// The same shape with no explicit --limit: the default threshold is 100,
	// the page is short, the server promises more.
	t.Run("a short DEFAULT page the server says continues is announced", func(t *testing.T) {
		body := nestedPage(12, 100, true)
		mustReach(t, body, 12, true)

		if got := run(t, globals{}, paginated(100), body); got == "" {
			t.Fatalf("SILENT: a 12-row default page with has_more true reads as a 12-row population")
		}
	})

	// HOLE 2 — no --limit default declared, none passed: limit resolves to 0
	// and the guard used to return before reading has_more.
	t.Run("a command with no limit default still reports the server's promise", func(t *testing.T) {
		body := nestedPage(25, 25, true)
		mustReach(t, body, 25, true)

		if got := run(t, globals{}, paginated(nil), body); got == "" {
			t.Fatalf("SILENT: limit resolved to 0, so the guard returned before ever reading has_more — the one field that needs no threshold")
		}
	})

	// HOLE 3 — the top-level camelCase envelope (doc query + search), whose
	// pages are bounded by response BYTES, so a short page is routine.
	t.Run("a top-level camelCase hasMore is read, not just page.has_more", func(t *testing.T) {
		body := topLevelPage(500, true, 1050)
		mustReach(t, body, 500, true)

		got := run(t, globals{limit: 1000, limitSet: true}, paginated(100), body)
		if got == "" {
			t.Fatalf("SILENT on the doc-query/search envelope: 500 of 1050 served, hasMore true at the top level. pageHasMore read only the nested spelling and answered false for exactly the two surfaces that need it")
		}
	})

	// ---- CONTROLS: the instrument must stay QUIET when the page is whole ---

	// CONTROL 1 — the population FITS under the limit. This is the case the
	// row warns a fix must not make noisy, and the case a smaller-than-limit
	// fixture would have made indistinguishable from truncation.
	t.Run("CONTROL a page smaller than the limit with has_more false stays silent", func(t *testing.T) {
		body := nestedPage(40, 100, false)
		mustReach(t, body, 40, false)

		if got := run(t, globals{limit: 100, limitSet: true}, paginated(100), body); got != "" {
			t.Fatalf("a complete page must read complete — an instrument that cries truncation at every read reports nothing; got %q", got)
		}
	})

	// CONTROL 2 — same, on the top-level envelope, and with no limit default.
	t.Run("CONTROL a complete top-level page stays silent", func(t *testing.T) {
		body := topLevelPage(7, false, 7)
		mustReach(t, body, 7, false)

		if got := run(t, globals{}, paginated(nil), body); got != "" {
			t.Fatalf("a complete top-level page must read complete; got %q", got)
		}
	})

	// CONTROL 3 — an envelope with NO continuation field at all must not be
	// read as a promise. Absence adds nothing.
	t.Run("CONTROL an envelope with no page block stays silent", func(t *testing.T) {
		body := []byte(`{"docs":[{"doc_id":"task-0"},{"doc_id":"task-1"}]}`)
		if pageHasMore(unwrapResult(body)) {
			t.Fatalf("a missing continuation field must read false — an absent promise is not a promise")
		}
		if got := run(t, globals{}, paginated(100), body); got != "" {
			t.Fatalf("no page block must mean no claim; got %q", got)
		}
	})

	// CONTROL 4 — --all walks every page, so the per-page notice must stay off.
	t.Run("CONTROL --all suppresses the notice", func(t *testing.T) {
		body := nestedPage(40, 100, true)
		mustReach(t, body, 40, true)

		if got := run(t, globals{all: true}, paginated(100), body); got != "" {
			t.Fatalf("--all already exhausts the pages; got %q", got)
		}
	})
}
