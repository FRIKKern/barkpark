package cli

import (
	"bytes"
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

// taskRow is one row of the fake /v1/tasks ledger.
type taskRow struct {
	DocID string `json:"doc_id"`
	Title string `json:"title"`
}

// matchManifest carries the two commands this feature spans, shaped like the
// live manifest: task.ls is paginated with limit/offset and NOTHING else (the
// route accepts no substring filter, which is why --match is client-side), and
// task.get takes one required doc_id.
func matchManifest() *manifest.Manifest {
	return &manifest.Manifest{Commands: []manifest.Command{
		{
			ID: taskLsCommandID, Noun: "task", Verb: "ls",
			HTTP:      manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks"},
			Paginated: true,
			Flags: []manifest.Flag{
				{Name: "limit", Type: "int"},
				{Name: "offset", Type: "int"},
			},
		},
		{
			ID: taskGetCommandID, Noun: "task", Verb: "get",
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/:doc_id"},
			Args: []manifest.Arg{{Name: "doc_id", Required: true, Type: "string"}},
		},
	}}
}

// ledgerServer serves rows as GET /v1/tasks honouring offset+limit, and 404s
// every GET /v1/tasks/:id with an UNANNOTATED not_found — the shape the live
// tasks controller emits (a private not_found/2 with {code, message} and no
// hint), which is precisely the case the local hint has to answer.
func ledgerServer(t *testing.T, rows []taskRow) (*httptest.Server, *int32) {
	t.Helper()
	var pages int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/v1/tasks" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no task with that id"}}`))
			return
		}
		atomic.AddInt32(&pages, 1)
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		limit, err := strconv.Atoi(r.URL.Query().Get("limit"))
		if err != nil || limit <= 0 {
			limit = len(rows)
		}
		page := []taskRow{}
		for i := offset; i < len(rows) && i < offset+limit; i++ {
			page = append(page, rows[i])
		}
		body, _ := json.Marshal(map[string]any{"ok": true, "docs": page})
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	return srv, &pages
}

// runTaskCmd dispatches with -o json (list rows are parsed off stdout).
func runTaskCmd(t *testing.T, srv *httptest.Server, m *manifest.Manifest, id string, tail ...string) (string, string, int) {
	t.Helper()
	return runTaskCmdOut(t, srv, m, id, "json", tail...)
}

// runTaskCmdHuman dispatches with -o table, the mode in which a refusal renders
// as prose on STDERR rather than as a machine envelope on stdout — which is
// where the hint under test has to be legible.
func runTaskCmdHuman(t *testing.T, srv *httptest.Server, m *manifest.Manifest, id string, tail ...string) (string, string, int) {
	t.Helper()
	return runTaskCmdOut(t, srv, m, id, "table", tail...)
}

func runTaskCmdOut(t *testing.T, srv *httptest.Server, m *manifest.Manifest, id, output string, tail ...string) (string, string, int) {
	t.Helper()
	var cmd manifest.Command
	for _, c := range m.Commands {
		if c.ID == id {
			cmd = c
		}
	}
	if cmd.ID == "" {
		t.Fatalf("fixture has no command %s", id)
	}
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: output, outputSet: true}
	out.applyGlobals(g)
	code := runCommand(out, g, manifest.Context{Server: srv.URL}, m, cmd, tail)
	return stdout.String(), stderr.String(), code
}

func matchedDocIDs(t *testing.T, stdout string) []string {
	t.Helper()
	var env struct {
		Docs []taskRow `json:"docs"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a docs envelope: %v\n%s", err, stdout)
	}
	ids := make([]string, 0, len(env.Docs))
	for _, d := range env.Docs {
		ids = append(ids, d.DocID)
	}
	return ids
}

// ---------------------------------------------------------------------------
// --match: the filter itself
// ---------------------------------------------------------------------------

// A ledger that fits in ONE page. This is the case a naive filter fails
// silently: paginatedAllWalk's single-page fast path renders the server's own
// body verbatim, which is the UNFILTERED page. If the filter is not honoured on
// that path, every row prints and the test below sees the excluded row.
func TestTaskLsMatch_FiltersOnASinglePage(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{
		{DocID: "cch-w57-s5-the-dns-sweep-cannot-silently-degrade", Title: "the DNS sweep degrades in silence"},
		{DocID: "task-d89e42ea727bffb7", Title: "guerrilla returns 500s on public reads"},
		{DocID: "pds-w27-bl-something-else", Title: "an unrelated row about CCH-W57-S5 in its title"},
	})

	stdout, stderr, code := runTaskCmd(t, srv, matchManifest(), taskLsCommandID, "--match", "cch-w57-s5")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	got := matchedDocIDs(t, stdout)

	// The doc_id match and the TITLE-ONLY match are both in (the third row's
	// doc_id contains no `cch-w57-s5`; only its title does, in upper case —
	// which also proves the comparison is case-insensitive).
	want := map[string]bool{
		"cch-w57-s5-the-dns-sweep-cannot-silently-degrade": true,
		"pds-w27-bl-something-else":                        true,
	}
	if len(got) != len(want) {
		t.Fatalf("matched %v, want exactly %d rows", got, len(want))
	}
	for _, id := range got {
		if !want[id] {
			t.Fatalf("matched %v — %q does not contain the substring in doc_id or title", got, id)
		}
	}
	// The explicit exclusion, stated as its own assertion so a filter that
	// degrades to match-everything cannot pass by accident.
	for _, id := range got {
		if id == "task-d89e42ea727bffb7" {
			t.Fatalf("a non-matching row was listed: %v", got)
		}
	}
}

// --match walks EVERY page, and does so without the caller typing --all: the
// needles live on pages two and three here, where a single-page read would
// never find them. The fixture is sized off taskWalkPageSize rather than a
// literal, so a change to the page size re-shapes the test instead of quietly
// making it single-page and vacuous.
func TestTaskLsMatch_WalksEveryPageWithoutAll(t *testing.T) {
	total := taskWalkPageSize*2 + 5
	rows := make([]taskRow, 0, total)
	for i := 0; i < total; i++ {
		rows = append(rows, taskRow{
			DocID: fmt.Sprintf("filler-%05d", i),
			Title: fmt.Sprintf("filler row %d", i),
		})
	}
	rows[taskWalkPageSize+50] = taskRow{DocID: "cch-w58-bl-wire-site-url-into-the-receipt", Title: "wire site url"}
	rows[taskWalkPageSize*2+1] = taskRow{DocID: "unrelated-id", Title: "also mentions CCH-W58-BL-WIRE-SITE-URL"}

	srv, pages := ledgerServer(t, rows)
	stdout, stderr, code := runTaskCmd(t, srv, matchManifest(), taskLsCommandID, "--match", "cch-w58-bl-wire-site-url")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	got := matchedDocIDs(t, stdout)
	if len(got) != 2 {
		t.Fatalf("matched %v, want the page-two and page-three rows", got)
	}
	if got[0] != "cch-w58-bl-wire-site-url-into-the-receipt" || got[1] != "unrelated-id" {
		t.Fatalf("matched %v, want both needles in walk order", got)
	}
	if n := atomic.LoadInt32(pages); n < 3 {
		t.Fatalf("served %d pages, want at least 3 — --match must imply --all", n)
	}
}

// Zero matches is an honest empty list, not a null and not the whole ledger.
func TestTaskLsMatch_NoMatchesIsAnEmptyList(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{
		{DocID: "task-a", Title: "alpha"},
		{DocID: "task-b", Title: "beta"},
	})
	stdout, stderr, code := runTaskCmd(t, srv, matchManifest(), taskLsCommandID, "--match", "zzz-no-such-thing")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	if strings.Contains(stdout, "null") {
		t.Fatalf("empty result rendered as null: %s", stdout)
	}
	if got := matchedDocIDs(t, stdout); len(got) != 0 {
		t.Fatalf("matched %v, want none", got)
	}
}

func TestExtractTaskMatchFlag(t *testing.T) {
	tests := []struct {
		name     string
		tail     []string
		want     string
		wantTail []string
		wantErr  bool
	}{
		{name: "absent", tail: []string{"--limit", "5"}, want: "", wantTail: []string{"--limit", "5"}},
		{name: "spaced", tail: []string{"--match", "abc", "--limit", "5"}, want: "abc", wantTail: []string{"--limit", "5"}},
		{name: "inline", tail: []string{"--match=abc"}, want: "abc", wantTail: []string{}},
		{name: "last wins", tail: []string{"--match", "a", "--match=b"}, want: "b", wantTail: []string{}},
		{name: "no value", tail: []string{"--match"}, wantErr: true},
		{name: "empty value", tail: []string{"--match", ""}, wantErr: true},
		{name: "inline empty value", tail: []string{"--match="}, wantErr: true},
		{name: "whitespace value", tail: []string{"--match", "   "}, wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, tail, err := extractTaskMatchFlag(tc.tail)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("extractTaskMatchFlag(%v) = %q, want an error", tc.tail, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Errorf("match = %q, want %q", got, tc.want)
			}
			if strings.Join(tail, " ") != strings.Join(tc.wantTail, " ") {
				t.Errorf("tail = %v, want %v", tail, tc.wantTail)
			}
		})
	}
}

// An empty --match must REFUSE, not list the whole ledger: the silent
// whole-ledger dump is the defect this flag exists to remove, and it would be
// invisible to a caller who believed the read was filtered.
func TestTaskLsMatch_EmptyValueRefuses(t *testing.T) {
	srv, pages := ledgerServer(t, []taskRow{{DocID: "task-a", Title: "alpha"}})
	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskLsCommandID, "--match", "")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage); stderr=%q", code, exitUsage, stderr)
	}
	if n := atomic.LoadInt32(pages); n != 0 {
		t.Fatalf("a refused invocation still read %d pages", n)
	}
}

// --match belongs to task.ls alone; any other verb must still see splitArgs'
// ordinary unknown-flag refusal.
func TestTaskMatchIsScopedToTaskLs(t *testing.T) {
	srv, _ := ledgerServer(t, nil)
	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "some-id", "--match", "abc")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage); stderr=%q", code, exitUsage, stderr)
	}
	if !strings.Contains(stderr, "unknown flag") {
		t.Fatalf("stderr = %q, want the unknown-flag refusal", stderr)
	}
}

// ---------------------------------------------------------------------------
// task get: the not_found hint and the prefix suggestion
// ---------------------------------------------------------------------------

// The hint names the searchable command WITH the id the caller typed. Naming
// bare `bp task ls` (the old text) is the defect: that verb has no filter, so
// following it costs the whole ledger.
func TestTaskGetNotFound_HintNamesMatchWithTheTypedID(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{
		{DocID: "unrelated-one", Title: "nothing to do with it"},
		{DocID: "unrelated-two", Title: "nor this"},
	})
	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "bp task ls --match cch-w57-s5") {
		t.Fatalf("hint did not name the searchable remedy with the typed id:\n%s", stderr)
	}
	// The old hint, which sent the reader at the unfiltered listing.
	if strings.Contains(stderr, "run `bp task ls` to see what exists") {
		t.Fatalf("hint still points at the unsearchable listing:\n%s", stderr)
	}
	if !strings.Contains(stderr, "not dataset-scoped") {
		t.Fatalf("hint dropped the dataset clause, sending the reader down a second dead end:\n%s", stderr)
	}
	// No candidate, so no suggestion may be invented.
	if strings.Contains(stderr, "did you mean") {
		t.Fatalf("a suggestion was offered with no candidate:\n%s", stderr)
	}
}

// EXACTLY ONE strict-prefix candidate: name it.
func TestTaskGetNotFound_SuggestsTheSoleStrictPrefixMatch(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{
		{DocID: "cch-w57-s4-a-different-row", Title: "not it"},
		{DocID: "cch-w57-s5-the-dns-sweep-cannot-silently-degrade", Title: "the DNS sweep"},
		{DocID: "cch-w58-s2-another", Title: "also not it"},
	})
	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "did you mean `cch-w57-s5-the-dns-sweep-cannot-silently-degrade`") {
		t.Fatalf("the sole prefix candidate was not named:\n%s", stderr)
	}
	// A suggestion, never a redirect: the refusal stands and the exit code is
	// still not_found.
	if strings.Contains(stderr, "the DNS sweep\n") {
		t.Fatalf("the CLI appears to have fetched the suggested row:\n%s", stderr)
	}
	if !strings.Contains(stderr, "bp task ls --match cch-w57-s5") {
		t.Fatalf("the suggestion displaced the searchable remedy:\n%s", stderr)
	}
}

// TWO strict-prefix candidates: say NOTHING. Naming either would be a guess
// wearing an answer's clothes.
func TestTaskGetNotFound_TwoCandidatesSuggestNothing(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{
		{DocID: "cch-w57-s5-the-dns-sweep-cannot-silently-degrade", Title: "one"},
		{DocID: "cch-w57-s5-a-second-row-with-the-same-prefix", Title: "two"},
	})
	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitNotFound, stderr)
	}
	if strings.Contains(stderr, "did you mean") {
		t.Fatalf("two candidates produced a suggestion:\n%s", stderr)
	}
	if !strings.Contains(stderr, "bp task ls --match cch-w57-s5") {
		t.Fatalf("the plain remedy is missing:\n%s", stderr)
	}
}

// The suggestion is a STRICT prefix: an id that merely CONTAINS the typed
// string is not a candidate (that is what --match is for), and neither is the
// typed id itself.
func TestTaskPrefixSuggestion_IsStrictAndPrefixOnly(t *testing.T) {
	m := matchManifest()
	tests := []struct {
		name  string
		rows  []taskRow
		typed string
		want  string
	}{
		{
			name:  "substring in the middle is not a prefix",
			rows:  []taskRow{{DocID: "prefix-cch-w57-s5-suffix"}},
			typed: "cch-w57-s5",
			want:  "",
		},
		{
			name:  "an exact id is not a STRICT prefix of itself",
			rows:  []taskRow{{DocID: "cch-w57-s5"}},
			typed: "cch-w57-s5",
			want:  "",
		},
		{
			name:  "a strict extension is",
			rows:  []taskRow{{DocID: "cch-w57-s5-extended"}},
			typed: "cch-w57-s5",
			want:  "cch-w57-s5-extended",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, _ := ledgerServer(t, tc.rows)
			got, _ := taskPrefixSuggestion(nil, m, manifest.Context{Server: srv.URL}, tc.typed)
			if got != tc.want {
				t.Fatalf("taskPrefixSuggestion = %q, want %q", got, tc.want)
			}
		})
	}
}

// A ledger deeper than one suggestion page still yields the candidate — the
// walk pages until a short page proves it saw the end.
func TestTaskPrefixSuggestion_WalksPastOnePage(t *testing.T) {
	rows := make([]taskRow, 0, taskSuggestPageSize+5)
	for i := 0; i < taskSuggestPageSize+5; i++ {
		rows = append(rows, taskRow{DocID: fmt.Sprintf("filler-%05d", i)})
	}
	rows[taskSuggestPageSize+2] = taskRow{DocID: "cch-w59-s3-deep-in-the-ledger"}

	srv, pages := ledgerServer(t, rows)
	got, _ := taskPrefixSuggestion(nil, matchManifest(), manifest.Context{Server: srv.URL}, "cch-w59-s3")
	if got != "cch-w59-s3-deep-in-the-ledger" {
		t.Fatalf("taskPrefixSuggestion = %q, want the page-two candidate", got)
	}
	if n := atomic.LoadInt32(pages); n < 2 {
		t.Fatalf("served %d pages, want at least 2", n)
	}
}

// A page the walk cannot read cannot support an "exactly one" claim — that is
// an ABSENCE statement about every row it did not see. It must return no
// suggestion rather than one computed over a partial read.
func TestTaskPrefixSuggestion_UnreadablePageYieldsNoSuggestion(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte("<html><body>502 Bad Gateway</body></html>"))
	}))
	defer srv.Close()
	if got, _ := taskPrefixSuggestion(nil, matchManifest(), manifest.Context{Server: srv.URL}, "cch-w57-s5"); got != "" {
		t.Fatalf("taskPrefixSuggestion = %q over an unreadable page, want \"\"", got)
	}
}

// A manifest with no task.ls cannot be walked, so the suggestion is silently
// unavailable — the hint still stands on its plain half.
func TestTaskPrefixSuggestion_NoListVerbInManifest(t *testing.T) {
	srv, pages := ledgerServer(t, []taskRow{{DocID: "cch-w57-s5-x"}})
	m := &manifest.Manifest{Commands: []manifest.Command{
		{ID: taskGetCommandID, Noun: "task", Verb: "get", HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/:doc_id"}},
	}}
	if got, _ := taskPrefixSuggestion(nil, m, manifest.Context{Server: srv.URL}, "cch-w57-s5"); got != "" {
		t.Fatalf("taskPrefixSuggestion = %q with no list verb, want \"\"", got)
	}
	if n := atomic.LoadInt32(pages); n != 0 {
		t.Fatalf("walked %d pages with no list verb to walk", n)
	}
}

// A server hint still outranks the local one, and — the point of the closure —
// a refusal the server DID annotate pays no page walk at all.
func TestTaskGetNotFound_ServerHintWinsAndCostsNoWalk(t *testing.T) {
	var lsPages int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/v1/tasks" {
			atomic.AddInt32(&lsPages, 1)
			_, _ = w.Write([]byte(`{"ok":true,"docs":[{"doc_id":"cch-w57-s5-extended","title":"x"}]}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"nope","hint":"the server's own words"}}`))
	}))
	defer srv.Close()

	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "the server's own words") {
		t.Fatalf("server hint was displaced:\n%s", stderr)
	}
	if strings.Contains(stderr, "--match") {
		t.Fatalf("local hint displaced the server's:\n%s", stderr)
	}
	if n := atomic.LoadInt32(&lsPages); n != 0 {
		t.Fatalf("an annotated refusal still paid %d listing pages", n)
	}
}

// A flag the manifest cannot declare is a flag `-h` cannot show — unless usage
// names it explicitly. The reader who most needs `--match` arrives here from a
// not_found hint, so the two surfaces have to agree.
func TestTaskLsUsageNamesMatch(t *testing.T) {
	m := matchManifest()
	var lsCmd, getCmd manifest.Command
	for _, c := range m.Commands {
		if c.ID == taskLsCommandID {
			lsCmd = c
		}
		if c.ID == taskGetCommandID {
			getCmd = c
		}
	}

	var so, se bytes.Buffer
	usageCommand(newWriter(&so, &se), lsCmd)
	if !strings.Contains(se.String(), "--match <substring>") {
		t.Fatalf("`bp task ls` usage does not name --match:\n%s", se.String())
	}

	var so2, se2 bytes.Buffer
	usageCommand(newWriter(&so2, &se2), getCmd)
	if strings.Contains(se2.String(), "--match") {
		t.Fatalf("`bp task get` usage advertises a flag its parser refuses:\n%s", se2.String())
	}
}

// The whole premise of --match is that resolving a truncated id must be CHEAP.
// GET /v1/tasks clamps limit at 1000, so a walk that asks for the default 100
// pays ~9x the round-trips — 82 requests for the live ledger where 9 would do,
// which is 9x the latency and 9x the exposure to any per-request failure. This
// pins the window both task walks ask for.
func TestTaskWalksRequestTheRoutesMaxPageSize(t *testing.T) {
	if taskWalkPageSize <= defaultWalkPageSize {
		t.Fatalf("taskWalkPageSize = %d, want more than the generic walk's %d", taskWalkPageSize, defaultWalkPageSize)
	}

	var limits []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limits = append(limits, r.URL.Query().Get("limit"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"docs":[]}`))
	}))
	defer srv.Close()

	if _, _, code := runTaskCmd(t, srv, matchManifest(), taskLsCommandID, "--match", "anything"); code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	if len(limits) == 0 {
		t.Fatal("the walk sent no request")
	}
	// The --all walk asks for pageSize+1: the extra row is the lookahead anchor.
	want := strconv.Itoa(taskWalkPageSize + 1)
	if limits[0] != want {
		t.Fatalf("--match asked for limit=%s, want %s (the route's own clamp plus the lookahead row)", limits[0], want)
	}

	limits = nil
	_, _ = taskPrefixSuggestion(nil, matchManifest(), manifest.Context{Server: srv.URL}, "cch-w57-s5")
	if len(limits) == 0 {
		t.Fatal("the suggestion walk sent no request")
	}
	if limits[0] != strconv.Itoa(taskSuggestPageSize) {
		t.Fatalf("the suggestion walk asked for limit=%s, want %d", limits[0], taskSuggestPageSize)
	}
}

// A walk that asks for MORE than the route's clamp gets the clamp back, which
// means it gets no lookahead row — and paginatedAllWalk then reports every
// boundary as unverified, trading away the shift detection that is the whole
// point of the anchor. Measured live before this was fixed: eight
// "pagination boundary … is unverified" lines in one `--match` run.
//
// The fake server here CLAMPS exactly as /v1/tasks does.
func TestTaskLsMatch_StaysUnderTheRouteClampSoBoundariesStayVerified(t *testing.T) {
	total := taskWalkPageSize*2 + 5
	rows := make([]taskRow, 0, total)
	for i := 0; i < total; i++ {
		rows = append(rows, taskRow{DocID: fmt.Sprintf("filler-%05d", i)})
	}
	rows[10] = taskRow{DocID: "cch-w59-s1-the-needle"}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		if limit <= 0 || limit > taskRouteMaxLimit {
			limit = taskRouteMaxLimit // the server's clamp, verbatim
		}
		page := []taskRow{}
		for i := offset; i < len(rows) && i < offset+limit; i++ {
			page = append(page, rows[i])
		}
		body, _ := json.Marshal(map[string]any{"ok": true, "docs": page})
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	stdout, stderr, code := runTaskCmd(t, srv, matchManifest(), taskLsCommandID, "--match", "cch-w59-s1")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	if strings.Contains(stderr, "unverified") {
		t.Fatalf("the walk asked past the route clamp and lost its lookahead anchor:\n%s", stderr)
	}
	if got := matchedDocIDs(t, stdout); len(got) != 1 || got[0] != "cch-w59-s1-the-needle" {
		t.Fatalf("matched %v, want the single needle", got)
	}
}

// The suggestion walk reads nothing but doc_id, so it must ask for the cheapest
// projection the route serves. Measured live: a full-row page of 1000 tasks is
// 10.2 MB / ~4s, the same page under view=brief is 337 KB / ~1.2s. The first
// cut of this walk asked for full rows under a 4s cap and therefore NEVER
// finished on the live ledger — it suggested nothing, ever, while looking
// perfectly correct in every unit test. This pins the projection so that
// regression cannot come back silently.
func TestTaskPrefixSuggestion_AsksForTheCheapProjection(t *testing.T) {
	var views []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		views = append(views, r.URL.Query().Get("view"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"docs":[]}`))
	}))
	defer srv.Close()

	_, _ = taskPrefixSuggestion(nil, matchManifest(), manifest.Context{Server: srv.URL}, "cch-w57-s5")
	if len(views) == 0 {
		t.Fatal("the suggestion walk sent no request")
	}
	if views[0] != taskSuggestView {
		t.Fatalf("suggestion walk asked for view=%q, want %q — a full-row scan is ~30x the bytes and cannot finish inside the deadline", views[0], taskSuggestView)
	}
}

// A walk that can take seconds must say so: it hangs off a refusal, the one
// place a caller expects an instant answer, and a silent multi-second pause
// reads as a hung CLI.
func TestTaskGetNotFound_AnnouncesTheScan(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{{DocID: "cch-w57-s5-the-only-one", Title: "x"}})
	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, "scanning the ledger") {
		t.Fatalf("the scan was silent:\n%s", stderr)
	}
	if !strings.Contains(stderr, "did you mean `cch-w57-s5-the-only-one`") {
		t.Fatalf("the sole candidate was not named:\n%s", stderr)
	}
}

// SILENCE IS NOT ABSENCE. When the scan gives up, the hint must SAY it gave up
// — otherwise a reader infers "no close id exists" from a check that never ran.
// This is the distinction the (suggestion, complete) pair exists to carry.
func TestTaskGetNotFound_AbandonedScanSaysSo(t *testing.T) {
	// A server that never serves a short page: the walk can never see the end
	// of the ledger, so it cannot claim uniqueness and must abandon.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/v1/tasks" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no task with that id"}}`))
			return
		}
		rows := make([]taskRow, taskSuggestPageSize)
		for i := range rows {
			rows[i] = taskRow{DocID: fmt.Sprintf("filler-%d-%s", i, r.URL.Query().Get("offset"))}
		}
		body, _ := json.Marshal(map[string]any{"ok": true, "docs": rows})
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, "no close-id scan was made") {
		t.Fatalf("an abandoned scan passed itself off as a completed one:\n%s", stderr)
	}
	if !strings.Contains(stderr, "bp task ls --match cch-w57-s5") {
		t.Fatalf("the searchable remedy is missing:\n%s", stderr)
	}
}

// The mirror arm: a COMPLETED scan that found nothing is a real absence claim,
// and must NOT carry the "no scan was made" caveat.
func TestTaskGetNotFound_CompletedEmptyScanIsNotCaveated(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{{DocID: "nothing-alike", Title: "x"}})
	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if strings.Contains(stderr, "no close-id scan was made") {
		t.Fatalf("a completed scan reported itself as abandoned:\n%s", stderr)
	}
	if strings.Contains(stderr, "did you mean") {
		t.Fatalf("a suggestion was invented:\n%s", stderr)
	}
}

// Two candidates SETTLES the question — "not exactly one" is a complete answer,
// not an abandoned scan, so it must not be caveated either.
func TestTaskGetNotFound_TwoCandidatesIsACompleteAnswer(t *testing.T) {
	srv, _ := ledgerServer(t, []taskRow{
		{DocID: "cch-w57-s5-one", Title: "a"},
		{DocID: "cch-w57-s5-two", Title: "b"},
	})
	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if strings.Contains(stderr, "no close-id scan was made") {
		t.Fatalf("a settled 'not exactly one' reported itself as abandoned:\n%s", stderr)
	}
}

// The DEADLINE arm, distinct from the page-ceiling arm above: a scan cut short
// by time must also report itself as abandoned. Both exits return the same
// pair, and this is what proves it — a mutation that flips only the deadline
// arm to `true` leaves the ceiling test green.
func TestTaskGetNotFound_DeadlineArmAlsoSaysItGaveUp(t *testing.T) {
	restore := taskSuggestDeadline
	taskSuggestDeadline = time.Nanosecond
	t.Cleanup(func() { taskSuggestDeadline = restore })

	// A single-page ledger holding exactly ONE candidate: with a live deadline
	// this scan completes and suggests. It must not, because time is already up
	// before the first request.
	srv, pages := ledgerServer(t, []taskRow{{DocID: "cch-w57-s5-the-only-one", Title: "x"}})

	_, stderr, code := runTaskCmdHuman(t, srv, matchManifest(), taskGetCommandID, "cch-w57-s5")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, "no close-id scan was made") {
		t.Fatalf("a scan cut short by the deadline did not report giving up:\n%s", stderr)
	}
	if strings.Contains(stderr, "did you mean") {
		t.Fatalf("an expired scan still suggested:\n%s", stderr)
	}
	if n := atomic.LoadInt32(pages); n != 0 {
		t.Fatalf("the deadline was checked after %d request(s), not before the first", n)
	}
}
