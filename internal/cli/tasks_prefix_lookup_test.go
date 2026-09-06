package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE SERVER-SIDE PREFIX LOOKUP (cchi-bl-task-get-needs-a-server-side-prefix-lookup).
//
// `bp task get <truncated-id>` used to answer its "did you mean" by WALKING
// GET /v1/tasks — nine pages at the route's 1000-row clamp on the live ledger,
// four requests in flight, ~3.5s. `GET /v1/tasks?id_prefix=<id>` answers the
// same question in ONE request from an indexed lookup, and these tests pin the
// three things that can go wrong with preferring it: that it is used at all,
// that its answer is treated as COMPLETE, and that a server without it still
// gets the old walk instead of silence.

// prefixLookupServer answers `?id_prefix=` with the lean lookup envelope and
// counts the two request kinds separately.
//
// Its WALK arm deliberately serves a full, never-short page of filler: the walk
// can therefore never settle a uniqueness claim here, so a suggestion that
// comes back at all can ONLY have come from the lookup. Without that, a test
// that merely asserted the suggestion would stay green if the lookup were
// deleted and the walk answered instead.
func prefixLookupServer(t *testing.T, matches []taskRow) (*httptest.Server, *int32, *int32) {
	t.Helper()
	var lookups, walks int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/v1/tasks" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no task with that id"}}`))
			return
		}
		if prefix := r.URL.Query().Get("id_prefix"); prefix != "" {
			atomic.AddInt32(&lookups, 1)
			hits := []taskRow{}
			for _, m := range matches {
				if strings.HasPrefix(m.DocID, prefix) {
					hits = append(hits, m)
				}
			}
			body, _ := json.Marshal(map[string]any{
				"ok":        true,
				"id_prefix": prefix,
				"matches":   hits,
				"count":     len(hits),
				"truncated": false,
			})
			_, _ = w.Write(body)
			return
		}
		atomic.AddInt32(&walks, 1)
		rows := make([]taskRow, taskSuggestPageSize)
		for i := range rows {
			rows[i] = taskRow{DocID: fmt.Sprintf("filler-%d-%s", i, r.URL.Query().Get("offset"))}
		}
		body, _ := json.Marshal(map[string]any{"ok": true, "docs": rows})
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	return srv, &lookups, &walks
}

// GREEN-WITH: one lookup request, no walk pages, and the sole extension named.
// RED-WITHOUT: delete the lookup arm and the walk answers instead — it can
// never see a short page here, so the hint degrades to "no close-id scan was
// made" and walks is nine, not zero.
func TestTaskGetNotFound_UsesTheServerLookupInOneRequest(t *testing.T) {
	srv, lookups, walks := prefixLookupServer(t, []taskRow{
		{DocID: "cch-w57-s5-the-only-one", Title: "the only extension"},
	})

	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, "did you mean `cch-w57-s5-the-only-one`") {
		t.Fatalf("the server lookup's sole candidate was not named:\n%s", stderr)
	}
	if n := atomic.LoadInt32(lookups); n != 1 {
		t.Fatalf("id_prefix lookups = %d, want exactly 1", n)
	}
	if n := atomic.LoadInt32(walks); n != 0 {
		t.Fatalf("the client-side scan ran %d page(s) despite a server that answers the lookup", n)
	}
}

// The lookup's answer is COMPLETE: zero hits is a real absence claim, so the
// hint must not carry the "no close-id scan was made" caveat. That caveat is
// the whole reason (suggestion, complete) is a pair, and a lookup wired to
// return complete=false would keep every other test here green.
func TestTaskGetNotFound_ServerLookupZeroHitsIsNotCaveated(t *testing.T) {
	srv, lookups, walks := prefixLookupServer(t, []taskRow{
		{DocID: "nothing-alike", Title: "x"},
	})

	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if strings.Contains(stderr, "no close-id scan was made") {
		t.Fatalf("a completed server lookup reported itself as abandoned:\n%s", stderr)
	}
	if strings.Contains(stderr, "did you mean") {
		t.Fatalf("a zero-hit lookup still suggested:\n%s", stderr)
	}
	if got, want := atomic.LoadInt32(lookups), int32(1); got != want {
		t.Fatalf("id_prefix lookups = %d, want %d", got, want)
	}
	if n := atomic.LoadInt32(walks); n != 0 {
		t.Fatalf("the client-side scan ran %d page(s) after a complete server answer", n)
	}
}

// Two hits settle "not exactly one" — a complete answer, not silence, and never
// a guess dressed as an answer.
func TestTaskPrefixSuggestion_ServerLookupTwoHitsSettlesWithoutSuggesting(t *testing.T) {
	srv, _, walks := prefixLookupServer(t, []taskRow{
		{DocID: "cch-w57-s5-one", Title: "a"},
		{DocID: "cch-w57-s5-two", Title: "b"},
	})

	got, complete := taskPrefixSuggestion(nil, matchManifest(), manifest.Context{Server: srv.URL}, "cch-w57-s5")
	if got != "" {
		t.Fatalf("suggestion = %q over two candidates, want none", got)
	}
	if !complete {
		t.Fatal("two candidates is a SETTLED answer; the lookup reported it as abandoned")
	}
	if n := atomic.LoadInt32(walks); n != 0 {
		t.Fatalf("the client-side scan ran %d page(s) after a settled server answer", n)
	}
}

// THE OLD-SERVER FALLBACK. The CLI is manifest-driven and talks to instances it
// did not ship with. `GET /v1/tasks` fail-closes on an unknown top-level param,
// so a server without this filter answers 400 naming `id_prefix` — and the walk
// must then still run and still suggest. Deleting the walk would turn a slow
// suggestion into no suggestion at all on every older box.
func TestTaskGetNotFound_FallsBackToTheWalkWhenTheServerRefusesTheParam(t *testing.T) {
	rows := []taskRow{{DocID: "cch-w57-s5-the-only-one", Title: "x"}}
	var walks int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/v1/tasks" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no task with that id"}}`))
			return
		}
		if r.URL.Query().Get("id_prefix") != "" {
			// Verbatim shape of Params.reject_unknown_flat_params/2's refusal.
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"code":"invalid_filter","message":"unknown query param id_prefix on GET /v1/tasks"}}`))
			return
		}
		atomic.AddInt32(&walks, 1)
		body, _ := json.Marshal(map[string]any{"ok": true, "docs": rows})
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, "did you mean `cch-w57-s5-the-only-one`") {
		t.Fatalf("a 400 on the new param cost the suggestion entirely:\n%s", stderr)
	}
	if n := atomic.LoadInt32(&walks); n == 0 {
		t.Fatal("the walk never ran, so the fallback is not wired")
	}
}

// A server that ACCEPTED `id_prefix` and IGNORED it would hand back the
// ordinary task page. Its rows are arbitrary tasks, and one of them can carry
// the typed id as a prefix by luck — so treating that page as the lookup's
// answer would be a suggestion computed over the wrong set. The `id_prefix`
// echo is what tells the two apart, and this test is the only thing that keeps
// the echo check from being deleted as redundant.
func TestTaskPrefixLookupServer_AnIgnoredParamIsNotAServedAnswer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		// The ordinary index envelope: no `id_prefix`, no `matches`.
		_, _ = w.Write([]byte(`{"ok":true,"docs":[{"doc_id":"cch-w57-s5-by-luck","title":"x"}]}`))
	}))
	defer srv.Close()

	m := matchManifest()
	var lsCmd manifest.Command
	for _, c := range m.Commands {
		if c.ID == taskLsCommandID {
			lsCmd = c
		}
	}
	ctx := manifest.Context{Server: srv.URL}
	baseURL, err := m.BuildURL(lsCmd, ctx, map[string]string{})
	if err != nil {
		t.Fatalf("BuildURL: %v", err)
	}

	got, served := taskPrefixLookupServer(lsCmd, ctx, baseURL, authHeaders(lsCmd, ctx), "cch-w57-s5")
	if served {
		t.Fatalf("an ignored param was read as a served answer (suggestion %q)", got)
	}
}
