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

	// A full page: exactly `limit` rows came back, which is precisely the
	// condition page.has_more encodes server-side.
	fullPage := func(n int) []byte {
		rows := make([]json.RawMessage, n)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"doc_id":"task-%d"}`, i))
		}
		body, _ := json.Marshal(map[string]any{
			"ok":   true,
			"docs": rows,
			"page": map[string]any{"limit": n, "offset": 0, "returned": n, "has_more": true},
		})
		return body
	}

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

	// RED WITHOUT the manifest change. Same server response, same truncated
	// page — the only difference is the stale declared default, and the CLI
	// goes completely quiet.
	t.Run("stale declared default 1000 silences the hint", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"

		warnIfDefaultPageMayBeTruncated(out, globals{}, taskLs(1000), fullPage(100))

		if stderr.Len() != 0 {
			t.Fatalf("expected the stale default to say nothing (that is the bug this documents); got %q", stderr.String())
		}
	})

	// An under-full page is provably the last one — no hint, at either
	// declared default.
	t.Run("a short page stays silent", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"

		warnIfDefaultPageMayBeTruncated(out, globals{}, taskLs(100), fullPage(37))

		if stderr.Len() != 0 {
			t.Errorf("short page must not warn; got %q", stderr.String())
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
