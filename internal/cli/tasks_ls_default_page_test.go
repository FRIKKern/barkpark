package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-e2f5ecca0be9a6d1 — the CLI half of "GET /v1/tasks pages by default".
//
// THE SERVER SHRANK ITS DEFAULT PAGE from 1000 (which was also the cap, so a
// bare `bp task ls` fanned the whole task corpus out of one Repo.all) to 100.
// No Go code had to change for the CLI to ANNOUNCE that truncation: run.go's
// warnIfDefaultPageMayBeTruncated already fires when a page comes back exactly
// full, and it learns "exactly full" from the manifest's declared limit default
// (defaultPageLimit). What had to change is the number the manifest declares —
// api/lib/barkpark/plugins/tasks.ex, task.ls.
//
// That makes the manifest field load-bearing in a way worth a test of its own:
// it is NEVER SENT (applyQuery adds ?limit= only when the user typed --limit),
// so a wrong value cannot truncate anything. It can only decide whether a real
// truncation is announced or silent. Left at 1000 against a server paging at
// 100, the CLI compares 100 rows to a believed limit of 1000, concludes the
// page is complete, and says nothing — the caller reads 100 of 8,525 tasks as
// the whole board. This test pins the announcement to the new default and
// proves the stale value silences it.
func TestTaskLsDefaultPageTruncationIsAnnounced(t *testing.T) {
	// The task.ls manifest entry as it now stands: paginated read, limit
	// default 100 matching tasks_controller do_index.
	taskLs := func(limitDefault int) manifest.Command {
		return manifest.Command{
			Noun:      "task",
			Verb:      "ls",
			Paginated: true,
			HTTP:      manifest.HTTP{Method: "GET"},
			Flags: []manifest.Flag{
				{Name: "limit", Type: "int", Default: limitDefault},
				{Name: "offset", Type: "int", Default: 0},
			},
		}
	}

	// THIS HELPER USED TO HARDCODE has_more:true FOR EVERY n, including the
	// pages it was used to build as "provably the last one". That made the
	// continuation flag a constant rather than a variable, so the two subtests
	// that asserted SILENCE were asserting it over a payload in which the
	// server explicitly said more rows remained — the very defect
	// task-3e9b429a93abab79 names, sitting inside the test meant to pin the
	// announcement. has_more is now a parameter, because it is the fact the
	// guard's backstop reads and a fixture cannot both state it and ignore it.
	page := func(n int, hasMore bool) []byte {
		rows := make([]json.RawMessage, n)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"doc_id":"task-%d"}`, i))
		}
		body, _ := json.Marshal(map[string]any{
			"ok":   true,
			"docs": rows,
			"page": map[string]any{"limit": n, "offset": 0, "returned": n, "has_more": hasMore},
		})
		return body
	}
	// A full page: exactly `limit` rows came back, which is precisely the
	// condition page.has_more encodes server-side.
	fullPage := func(n int) []byte { return page(n, true) }

	t.Run("declared default 100 announces a full 100-row page", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"

		warnIfDefaultPageMayBeTruncated(out, globals{}, taskLs(100), fullPage(100))

		if !strings.Contains(stderr.String(), "default limit of 100") {
			t.Fatalf("no truncation hint on stderr; got %q", stderr.String())
		}
		if !strings.Contains(stderr.String(), "--all") {
			t.Errorf("hint names no remedy; got %q", stderr.String())
		}
		if stdout.Len() != 0 {
			t.Errorf("hint must ride stderr only; stdout=%q", stdout.String())
		}
	})

	// A STALE DECLARED DEFAULT STILL DEFEATS THE ROW-COUNT HINT — that half of
	// the original finding stands, and the manifest field is still
	// load-bearing for the "default limit of N" wording. What CHANGED is that
	// it is no longer the last line of defence: the CLI compares 100 rows to a
	// believed limit of 1000, concludes the page is complete, and then reads
	// the server's own page.has_more, which says otherwise. So the specific
	// hint is lost and the TRUNCATION is still announced.
	//
	// This subtest used to assert TOTAL silence here, which pinned the bug in
	// place: it would have gone red on any fix that made a stale manifest
	// default survivable. The assertion now distinguishes the two claims
	// instead of collapsing them.
	t.Run("stale declared default 1000 loses the hint but not the truncation", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"

		warnIfDefaultPageMayBeTruncated(out, globals{}, taskLs(1000), fullPage(100))

		got := stderr.String()
		if strings.Contains(got, "default limit of") {
			t.Errorf("the row-count hint cannot fire under a stale default — it believes the limit is 1000 and only 100 rows came back; got %q", got)
		}
		if !strings.Contains(got, "has_more") {
			t.Fatalf("SILENT under a stale manifest default: 100 of 8,525 rows, server says has_more — the stale number must cost the wording, not the warning; got %q", got)
		}
		if stdout.Len() != 0 {
			t.Errorf("hint must ride stderr only; stdout=%q", stdout.String())
		}
	})

	// An under-full page is the last one ONLY WHEN THE SERVER SAYS SO. The
	// fixture must therefore carry has_more:false — built with fullPage (which
	// hardcoded true) this subtest asserted silence over a payload that
	// promised more rows, and so tested the opposite of its own name.
	t.Run("a genuinely last short page stays silent", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"

		warnIfDefaultPageMayBeTruncated(out, globals{}, taskLs(100), page(37, false))

		if stderr.Len() != 0 {
			t.Errorf("a complete short page must not warn; got %q", stderr.String())
		}
	})

	// THE COMPANION CONTROL the pair above needs: the same short page, with the
	// server promising more. Without this arm, "a short page stays silent"
	// passes just as well on a CLI that can no longer detect any truncation at
	// all — a green with no subject.
	t.Run("a short page the server says continues is announced", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"

		warnIfDefaultPageMayBeTruncated(out, globals{}, taskLs(100), page(37, true))

		if !strings.Contains(stderr.String(), "has_more") {
			t.Fatalf("SILENT: 37 rows with has_more true reads as a 37-row board; got %q", stderr.String())
		}
	})

	// --all is the remedy the hint names, so it must not also nag while it runs.
	t.Run("--all suppresses the hint", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"

		warnIfDefaultPageMayBeTruncated(out, globals{all: true}, taskLs(100), fullPage(100))

		if stderr.Len() != 0 {
			t.Errorf("--all must not warn; got %q", stderr.String())
		}
	})
}

// The other half of the contract: the escape hatch the hint names still works.
// `bp task ls --all` must walk EVERY page by offset against a server that now
// defaults to 100 — the walk sends its own explicit `?limit=101` (pageSize+1,
// the lookahead anchor from the tlv-bl-tasks-ls-offset-broken fix), so the
// server's default never applies to it and the shrink cannot shorten a --all
// result. Three pages, 250 rows, all of them returned.
func TestTaskLsAllWalksEveryPageAgainstThePagingServer(t *testing.T) {
	const total = 250

	var sawLimits []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		sawLimits = append(sawLimits, q.Get("limit"))
		offset, _ := strconv.Atoi(q.Get("offset"))
		limit, err := strconv.Atoi(q.Get("limit"))
		if err != nil || limit <= 0 {
			// The shrink's whole point: an ABSENT limit is bounded server-side.
			limit = 100
		}
		n := total - offset
		if n < 0 {
			n = 0
		}
		if n > limit {
			n = limit
		}
		rows := make([]json.RawMessage, n)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"doc_id":"task-%04d"}`, offset+i))
		}
		body, _ := json.Marshal(map[string]any{
			"ok":   true,
			"docs": rows,
			"page": map[string]any{
				"limit":    limit,
				"offset":   offset,
				"returned": n,
				"has_more": n == limit,
			},
		})
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ls", Paginated: true, HTTP: manifest.HTTP{Method: "GET"}}

	if code := runPaginatedAll(out, cmd, srv.URL+"/v1/tasks", map[string]string{}, paginatedAllOpts{}); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}

	var got map[string][]json.RawMessage
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output not JSON: %v\n%s", err, stdout.String())
	}
	if len(got["docs"]) != total {
		t.Fatalf("walked %d rows, want %d — --all dropped rows against a paging server", len(got["docs"]), total)
	}

	// Every row exactly once, in order: a walk that repeats or skips is the
	// failure mode the offset fix and the lookahead anchor exist to refuse.
	for i, row := range got["docs"] {
		want := fmt.Sprintf(`{"doc_id":"task-%04d"}`, i)
		if string(row) != want {
			t.Fatalf("row %d = %s, want %s", i, row, want)
		}
	}

	// The walk names its own limit on every request, so the server default is
	// irrelevant to it. Three pages: offsets 0, 100, 200.
	if len(sawLimits) != 3 {
		t.Fatalf("made %d requests (%v), want 3", len(sawLimits), sawLimits)
	}
	for i, l := range sawLimits {
		if l != "101" {
			t.Errorf("request %d sent limit=%q, want %q (pageSize+1 lookahead)", i, l, "101")
		}
	}

	// No unverified-boundary complaint: the server honoured the lookahead.
	if strings.Contains(stderr.String(), "unverified") {
		t.Errorf("unexpected unverified-boundary warning: %q", stderr.String())
	}
}

// The `page` block is ADDITIVE. The CLI's list-envelope reader keys on the row
// array, so a new sibling object must not become the "rows" it renders or walks.
func TestPageBlockDoesNotDisplaceTheRowArray(t *testing.T) {
	body := []byte(`{"ok":true,"docs":[{"doc_id":"a"},{"doc_id":"b"}],"page":{"limit":100,"offset":0,"returned":2,"has_more":false}}`)

	rows, key := extractListRows(body)
	if key != "docs" {
		t.Fatalf("envelope key = %q, want %q — the page block stole row detection", key, "docs")
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
}
