package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestRunPaginatedAll_EnvelopeKeys proves --all is envelope-key-aware: a list
// whose rows ride under a key other than "documents" (tasks under "docs", media
// search under "hits") is fetched whole and re-wrapped under its OWN key, not
// silently emptied. extractListRows previously only knew "documents", so
// `task ready --all` returned zero rows against a populated server.
func TestRunPaginatedAll_EnvelopeKeys(t *testing.T) {
	tests := []struct {
		name     string
		key      string // envelope key the fake server emits
		page1    int    // rows on offset=0
		page2    int    // rows on offset=100 (0 → single page)
		wantRows int
	}{
		{name: "docs two pages", key: "docs", page1: 100, page2: 20, wantRows: 120},
		{name: "hits single page", key: "hits", page1: 3, page2: 0, wantRows: 3},
		{name: "documents unchanged", key: "documents", page1: 100, page2: 5, wantRows: 105},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
				n := tc.page1
				if offset >= 100 {
					n = tc.page2
				}
				rows := make([]json.RawMessage, n)
				for i := range rows {
					rows[i] = json.RawMessage(fmt.Sprintf(`{"id":"%s-%d"}`, tc.key, offset+i))
				}
				body, _ := json.Marshal(map[string]any{tc.key: rows})
				w.Write(body)
			}))
			defer srv.Close()

			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = "json"
			cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}}

			if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitOK {
				t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
			}

			var got map[string][]json.RawMessage
			if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
				t.Fatalf("output not JSON: %v\n%s", err, stdout.String())
			}
			rows, ok := got[tc.key]
			if !ok {
				t.Fatalf("output re-wrapped under wrong key: got keys %v, want %q", keysOf(got), tc.key)
			}
			if len(rows) != tc.wantRows {
				t.Errorf("row count = %d, want %d", len(rows), tc.wantRows)
			}
		})
	}
}

// TestRunPaginatedAll_RefusesUnreadablePage is the PDS wave-27 reader-honesty
// lock. Every one of these bodies is served with HTTP 200 — a status code is no
// proof the payload came from Barkpark. Before the fix, all of them were
// laundered through `if key == "" { key = "documents" }` into a well-formed
// EMPTY SUCCESS envelope: rc=0, stdout {"documents":null}, stderr empty —
// BYTE-IDENTICAL (sha 373c4fc20dc823ff on both) to a genuinely empty queue, so
// a worker could not tell "nothing to do" from "the reverse proxy is down".
// Each must now refuse with the named code unreadable_list_page and a nonzero
// exit, and no partial rows may reach stdout.
func TestRunPaginatedAll_RefusesUnreadablePage(t *testing.T) {
	poisons := []struct {
		name  string
		body  string
		ctype string
	}{
		{"proxy 502 html", `<html><head><title>502 Bad Gateway</title></head><body>502</body></html>`, "text/html"},
		{"json null", `null`, "application/json"},
		{"ok false error envelope", `{"ok":false,"error":{"code":"upstream_down","message":"nope"}}`, "application/json"},
		{"unknown envelope key", `{"widgets":[{"a":1},{"b":2}]}`, "application/json"},
		{"zero bytes", ``, "application/json"},
		{"result null", `{"result":null}`, "application/json"},
		{"empty object", `{}`, "application/json"},
		{"bare array", `[{"a":1}]`, "application/json"},
		{"plaintext", `service temporarily unavailable`, "text/plain"},
	}

	for _, tc := range poisons {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", tc.ctype)
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()

			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = "json"
			cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}}

			if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitGeneric {
				t.Fatalf("exit = %d, want %d (an HTTP-200 anomaly rendered as success); stdout=%q", code, exitGeneric, stdout.String())
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
			if envelope.OK || envelope.Error.Code != "unreadable_list_page" {
				t.Fatalf("want named refusal unreadable_list_page, got: %s", stdout.String())
			}
			if !strings.Contains(envelope.Error.Message, "offset 0") {
				t.Fatalf("message must name the offset that failed: %q", envelope.Error.Message)
			}
			if bytes.Contains(stdout.Bytes(), []byte(`"documents":null`)) {
				t.Fatalf("refusal still emitted the empty-success shape: %s", stdout.String())
			}
		})
	}

	// CONTROLS — a guard that reds an honest empty queue is a regression, not a
	// fix. Both must stay at exitOK.
	controls := []struct {
		name     string
		body     string
		wantKey  string
		wantRows int
	}{
		{"genuinely empty queue", `{"docs":[],"count":0}`, "docs", 0},
		{"populated queue", `{"docs":[{"_id":"task-1"}],"count":1}`, "docs", 1},
	}
	for _, tc := range controls {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()

			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = "json"
			cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}}

			if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitOK {
				t.Fatalf("exit = %d, want %d — the refusal reddened an honest read; stdout=%q stderr=%q",
					code, exitOK, stdout.String(), stderr.String())
			}
			// Decode tolerates envelope SIBLINGS (count): a single-page --all
			// walk now passes the server's envelope through verbatim
			// (pds-w27-bl-task-next-and-all-corrupt-the-honest-shape), so the
			// honest body carries count alongside the rows. The assertions are
			// unchanged: exitOK, the right key, the right row count.
			var got map[string]json.RawMessage
			if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
				t.Fatalf("output not JSON: %v\n%s", err, stdout.String())
			}
			var rows []json.RawMessage
			if err := json.Unmarshal(got[tc.wantKey], &rows); err != nil {
				t.Fatalf("no array under %q: %v\n%s", tc.wantKey, err, stdout.String())
			}
			if len(rows) != tc.wantRows {
				t.Fatalf("rows under %q = %d, want %d: %s", tc.wantKey, len(rows), tc.wantRows, stdout.String())
			}
		})
	}
}

// TestRunPaginatedAll_RefusesUnreadablePageMidPagination pins the PER-PAGE half
// of the refusal: page 1 is a valid full page, page 2 is a proxy 502 at HTTP
// 200. Pre-fix this silently truncated the walk and returned page 1 as a
// complete answer at rc=0 — the same lie, one page in. All prior coverage
// stopped at page 1, so a page-1-only guard would have shipped green.
func TestRunPaginatedAll_RefusesUnreadablePageMidPagination(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		if offset == 0 {
			rows := make([]json.RawMessage, 100)
			for i := range rows {
				rows[i] = json.RawMessage(fmt.Sprintf(`{"_id":"task-%03d"}`, i))
			}
			body, _ := json.Marshal(map[string]any{"docs": rows})
			_, _ = w.Write(body)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<html>502 Bad Gateway</html>`))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}}

	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitGeneric {
		t.Fatalf("exit = %d, want %d (page-2 poison passed as a complete result); stdout=%q", code, exitGeneric, stdout.String())
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
	if envelope.OK || envelope.Error.Code != "unreadable_list_page" {
		t.Fatalf("want unreadable_list_page, got: %s", stdout.String())
	}
	if !strings.Contains(envelope.Error.Message, "offset 100") {
		t.Fatalf("message must name the FAILING page's offset (100): %q", envelope.Error.Message)
	}
	if bytes.Contains(stdout.Bytes(), []byte(`"task-000"`)) {
		t.Fatalf("page-1 rows leaked to stdout beside the refusal: %s", stdout.String())
	}
}

// paginatedEnvelopeKeys records, for every `paginated: true` command in the API
// manifest source, the envelope key its controller actually emits — read from
// the controller, not guessed:
//
//	task.ls / task.ready → tasks_controller.ex:83        %{ok: true, docs: …}
//	doc.ls / doc.query   → query_controller.ex:90        documents: rendered
//	media.ls             → v1/media_controller.ex:254    assets: assets
//	search.query         → search/hit_envelope.ex:71     documents: …
//	ticket.inbox         → tickets_controller.ex:93,169  tickets: rows
var paginatedEnvelopeKeys = map[string]string{
	"task.ls":      "docs",
	"task.ready":   "docs",
	"doc.ls":       "documents",
	"doc.query":    "documents",
	"media.ls":     "assets",
	"search.query": "documents",
	"ticket.inbox": "tickets",
}

// TestPaginatedCommandsUseKnownEnvelopeKeys is the companion guard to the
// unreadable_list_page refusal. That refusal can only red a caller that reaches
// runPaginatedAll (cmd.Paginated && --all && !writes), so it is safe EXACTLY
// while every paginated command's envelope key is one listEnvelopeKeys knows.
// The near-miss is real: the LEGACY media_controller.ex:46 returns `files:`,
// which is NOT in listEnvelopeKeys — it is not the route `bp media ls` uses
// (router.ex maps /v1/media/:dataset to V1.MediaController), but it is one
// rename away from turning an honest read into a refusal.
//
// The test re-COUNTS the population from the API source rather than trusting
// the map: a new `paginated: true` command fails here until its envelope key is
// recorded above, and any recorded key missing from listEnvelopeKeys fails too.
func TestPaginatedCommandsUseKnownEnvelopeKeys(t *testing.T) {
	root := filepath.Join("..", "..", "api", "lib", "barkpark", "plugins")
	if _, err := os.Stat(root); err != nil {
		t.Skipf("API source not present (%v) — guard runs in the monorepo checkout", err)
	}

	found := map[string]bool{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".ex") {
			return err
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		lines := strings.Split(string(src), "\n")
		for i, line := range lines {
			if !strings.Contains(line, "paginated: true") {
				continue
			}
			id := commandIDAbove(lines, i)
			if id == "" {
				t.Errorf("%s:%d: `paginated: true` with no command id above it — the guard cannot check its envelope key", path, i+1)
				continue
			}
			found[id] = true
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", root, err)
	}
	if len(found) == 0 {
		t.Fatalf("no `paginated: true` commands found under %s — the guard scanned nothing", root)
	}

	known := map[string]bool{}
	for _, k := range listEnvelopeKeys {
		known[k] = true
	}
	for id := range found {
		key, recorded := paginatedEnvelopeKeys[id]
		if !recorded {
			t.Errorf("paginated command %q has no recorded envelope key: add it to paginatedEnvelopeKeys (read the controller) and make sure that key is in listEnvelopeKeys, or `bp %s --all` will refuse with unreadable_list_page", id, strings.ReplaceAll(id, ".", " "))
			continue
		}
		if !known[key] {
			t.Errorf("paginated command %q emits envelope key %q, which is NOT in listEnvelopeKeys (table.go) — `bp %s --all` would refuse an honest read with unreadable_list_page", id, key, strings.ReplaceAll(id, ".", " "))
		}
	}
	for id := range paginatedEnvelopeKeys {
		if !found[id] {
			t.Errorf("paginatedEnvelopeKeys records %q, which is no longer `paginated: true` in the API source — drop the stale row so the guard keeps measuring reality", id)
		}
	}
}

// commandIDAbove finds the command id that owns the `paginated: true` at
// lines[idx] — either the map form (`id: "task.ls"`) or the core_cmd form
// (`core_cmd(` followed by the quoted id).
func commandIDAbove(lines []string, idx int) string {
	idRe := regexp.MustCompile(`^\s*id:\s*"([a-z0-9_.-]+)"`)
	coreRe := regexp.MustCompile(`^\s*"([a-z0-9_.-]+\.[a-z0-9_-]+)",\s*$`)
	for i := idx; i >= 0 && idx-i < 400; i-- {
		if m := idRe.FindStringSubmatch(lines[i]); m != nil {
			return m[1]
		}
		if strings.Contains(lines[i], "core_cmd(") && i+1 < len(lines) {
			if m := coreRe.FindStringSubmatch(lines[i+1]); m != nil {
				return m[1]
			}
		}
	}
	return ""
}

// TestExtractListRows covers the pure extraction: first-matching key wins, an
// empty array still counts as a match (so detection works on an empty first
// page), and an unknown or unparseable envelope yields the "" sentinel.
//
// That sentinel used to be laundered into the "documents" shape by
// runPaginatedAll — this comment previously recorded that fallback as intended
// behaviour, which is precisely why the suite stayed green while every HTTP-200
// transport anomaly rendered as an empty list at exit 0. It is now a REFUSAL
// signal: see TestRunPaginatedAll_RefusesUnreadablePage for what the caller
// does with it end to end.
func TestExtractListRows(t *testing.T) {
	tests := []struct {
		name    string
		payload string
		wantKey string
		wantLen int
	}{
		{"documents", `{"documents":[{"a":1},{"b":2}]}`, "documents", 2},
		{"docs", `{"docs":[{"a":1}]}`, "docs", 1},
		{"hits", `{"hits":[{"a":1},{"b":2},{"c":3}]}`, "hits", 3},
		{"empty array still matches", `{"docs":[]}`, "docs", 0},
		{"unknown envelope", `{"widgets":[{"a":1}]}`, "", 0},
		{"non-array value skipped", `{"docs":"nope","hits":[{"a":1}]}`, "hits", 1},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rows, key := extractListRows([]byte(tc.payload))
			if key != tc.wantKey {
				t.Errorf("key = %q, want %q", key, tc.wantKey)
			}
			if len(rows) != tc.wantLen {
				t.Errorf("len = %d, want %d", len(rows), tc.wantLen)
			}
		})
	}
}

func TestRunPaginatedAll_StopsOnRepeatedOrCyclicFullPage(t *testing.T) {
	tests := []struct {
		name         string
		pageForCall  []string
		wantRequests int
	}{
		{name: "immediate repeat", pageForCall: []string{"a", "a"}, wantRequests: 2},
		{name: "cycle", pageForCall: []string{"a", "b", "a"}, wantRequests: 3},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			requests := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				page := tc.pageForCall[requests]
				requests++
				rows := make([]json.RawMessage, 100)
				for i := range rows {
					rows[i] = json.RawMessage(fmt.Sprintf(`{"id":"%s-%d","shape":"same"}`, page, i))
				}
				body, _ := json.Marshal(map[string]any{"docs": rows})
				w.Write(body)
			}))
			defer srv.Close()

			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = "json"
			cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}}

			if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitGeneric {
				t.Fatalf("exit = %d, want %d", code, exitGeneric)
			}
			if requests != tc.wantRequests {
				t.Fatalf("requests = %d, want bounded %d", requests, tc.wantRequests)
			}
			var envelope struct {
				OK    bool `json:"ok"`
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := json.Unmarshal(stdout.Bytes(), &envelope); err != nil {
				t.Fatalf("error output not JSON: %v\n%s", err, stdout.String())
			}
			if envelope.OK || envelope.Error.Code != "pagination_stalled" {
				t.Fatalf("unexpected error envelope: %s", stdout.String())
			}
			if bytes.Contains(stdout.Bytes(), []byte(`"shape":"same"`)) {
				t.Fatalf("partial rows leaked to stdout: %s", stdout.String())
			}
		})
	}
}

func TestRunPaginatedAll_AllowsEqualShapedRowsWithDistinctIdentities(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		n := 100
		if offset == 200 {
			n = 1
		}
		requests++
		rows := make([]json.RawMessage, n)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"id":"row-%d","shape":"same"}`, offset+i))
		}
		body, _ := json.Marshal(map[string]any{"docs": rows})
		w.Write(body)
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}}

	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}
	var got map[string][]json.RawMessage
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output not JSON: %v\n%s", err, stdout.String())
	}
	if len(got["docs"]) != 201 || requests != 3 {
		t.Fatalf("rows=%d requests=%d, want 201/3", len(got["docs"]), requests)
	}
}

func TestRunPaginatedAll_AllowsDistinctFullPagesWithSharedGenericFields(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		n := 100
		if offset == 200 {
			n = 1
		}
		requests++
		rows := make([]json.RawMessage, n)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(
				`{"name":"generic","scope":"shared","payload":"page-%d-row-%d"}`,
				offset/100,
				i,
			))
		}
		body, _ := json.Marshal(map[string]any{"docs": rows})
		w.Write(body)
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}}

	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}
	var got map[string][]json.RawMessage
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output not JSON: %v\n%s", err, stdout.String())
	}
	if len(got["docs"]) != 201 || requests != 3 {
		t.Fatalf("rows=%d requests=%d, want 201/3", len(got["docs"]), requests)
	}
}

// TestRunPaginatedAll_WalksLargeCorpusPastOffset100InOrder is the #5588
// regression lock ("/v1/tasks honors offset + total index order — page 2 is
// actually page 2", be7c80e7c). #5588 was a server-side fix; this test pins the
// CLI half of the contract: given a server that correctly honors offset over a
// >100-row corpus, runPaginatedAll must walk EVERY full page past offset 100
// (offsets 0,100,200,300 for 350 rows), never raise a false pagination_stalled,
// and concatenate the pages in GLOBAL ORDER — the exact invariant #5588 restored.
//
// The pre-#5588 failure (server ignoring offset so page 2 == page 1) surfaces at
// the CLI as either the stall guard tripping or rows arriving out of / duplicated
// order; both are asserted against here. This walks deeper than the existing
// two-full-page tests (EnvelopeKeys tops out at offset 100), covering the
// many-consecutive-full-pages path a real `task ls --all` takes.
func TestRunPaginatedAll_WalksLargeCorpusPastOffset100InOrder(t *testing.T) {
	const total = 350 // 3 full pages (0,100,200) + a 50-row tail at offset 300
	var gotOffsets []int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		gotOffsets = append(gotOffsets, offset)
		// A server that HONORS offset: serve the real slice [offset, offset+limit).
		rows := []json.RawMessage{}
		for i := offset; i < offset+limit && i < total; i++ {
			rows = append(rows, json.RawMessage(fmt.Sprintf(`{"id":"row-%03d","seq":%d}`, i, i)))
		}
		body, _ := json.Marshal(map[string]any{"docs": rows})
		w.Write(body)
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ls", HTTP: manifest.HTTP{Method: "GET"}}

	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitOK {
		t.Fatalf("exit = %d, want %d (false pagination_stalled on a correctly-paged server?); stdout=%q stderr=%q",
			code, exitOK, stdout.String(), stderr.String())
	}

	// The loop must have requested every full page past offset 100, then the tail.
	wantOffsets := []int{0, 100, 200, 300}
	if fmt.Sprint(gotOffsets) != fmt.Sprint(wantOffsets) {
		t.Fatalf("requested offsets = %v, want %v (loop did not walk past offset 100 in order)", gotOffsets, wantOffsets)
	}

	var got struct {
		Docs []struct {
			ID  string `json:"id"`
			Seq int    `json:"seq"`
		} `json:"docs"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output not JSON: %v\n%s", err, stdout.String())
	}
	if len(got.Docs) != total {
		t.Fatalf("row count = %d, want %d (dropped or duplicated a page)", len(got.Docs), total)
	}
	// Global order: doc i must be exactly seq i. This is what #5588 restored — a
	// stalling/repeating or offset-shuffling server would break this even if the
	// count happened to match.
	for i, d := range got.Docs {
		if d.Seq != i {
			t.Fatalf("row %d has seq %d (out of global order); id=%q — pages not concatenated as 0,100,200,300", i, d.Seq, d.ID)
		}
	}
}

func keysOf(m map[string][]json.RawMessage) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}

// TestBodyPreviewTruncatesOnRuneBoundary pins that the excerpt carried in an
// unreadable_list_page message stays valid UTF-8. A proxy interstitial is
// frequently non-ASCII (a localised error page), and cutting the byte slice at
// a fixed offset would splice a multi-byte sequence — turning the one piece of
// evidence the refusal carries into U+FFFD noise.
func TestBodyPreviewTruncatesOnRuneBoundary(t *testing.T) {
	// One ASCII byte then 2-byte runes, so the 120-byte cut lands INSIDE a
	// rune — a naive s[:120] splices it.
	body := []byte("x" + strings.Repeat("æ", 200))
	got := bodyPreview(body)
	if !utf8.ValidString(got) {
		t.Fatalf("preview is not valid UTF-8: %q", got)
	}
	if strings.ContainsRune(got, utf8.RuneError) {
		t.Fatalf("preview spliced a rune: %q", got)
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("preview of a 400-byte body was not truncated: %q", got)
	}
	if bodyPreview([]byte{}) != "<empty body>" {
		t.Fatalf("empty body must be named, not rendered as an empty string")
	}
}

// unreadableDefaultPagePoisons is wave 27's poison table, RE-POINTED at the
// DEFAULT single-page read. Every body arrives at HTTP 200 — a status code has
// never been proof the payload came from Barkpark.
var unreadableDefaultPagePoisons = []struct{ name, body string }{
	{"proxy_502_html", `<html><head><title>502 Bad Gateway</title></head><body>502</body></html>`},
	{"json_null", `null`},
	{"ok_false_error_envelope", `{"ok":false,"error":{"code":"upstream_down","message":"nope"}}`},
	{"unknown_envelope_key", `{"widgets":[{"a":1},{"b":2}]}`},
	{"zero_bytes", ``},
	{"result_null", `{"result":null}`},
	{"empty_object", `{}`},
	{"bare_array", `[{"a":1}]`},
	{"plaintext", `service temporarily unavailable`},
}

// TestRunCommandRefusesUnreadableDefaultPage is the PDS wave-28 lock, and it
// closes a strictly BIGGER hole than the wave-27 one above it: that refusal is
// reachable only behind `cmd.Paginated && g.all && !cmd.Writes`, and `--all` is
// the RARE invocation. This is the DEFAULT read — what `bp task ready` and
// `bp doc ls` actually run.
//
// MEASURED ON origin/main BEFORE THE FIX: all nine poisons across the three
// output shapes = 27 runs, exit 0 in 27 of 27, and 24 of the 27 said NOTHING on
// any channel. `-o minimal` — the agent shape — printed the literal word "ok"
// over `null`, an unknown envelope, `{"result":null}` and `{}`, and "not ok" at
// rc=0 over an error envelope; `-o json` printed that error envelope as a
// successful body; `-o table` printed the empty string at rc=0 for `{}`.
func TestRunCommandRefusesUnreadableDefaultPage(t *testing.T) {
	for _, tc := range unreadableDefaultPagePoisons {
		for _, shape := range []string{"json", "table", "minimal"} {
			t.Run(tc.name+"/"+shape, func(t *testing.T) {
				stdout, stderr, code := runPageResponse(t, shape, globals{}, paginatedReadCommand(100), tc.body)
				if code != exitGeneric {
					t.Fatalf("exit = %d, want %d — an HTTP-200 anomaly reported as success; stdout=%q stderr=%q",
						code, exitGeneric, stdout, stderr)
				}
				if strings.Contains(stdout, `"ok":true`) || strings.TrimSpace(stdout) == "ok" {
					t.Fatalf("refusal still rendered a success receipt: stdout=%q", stdout)
				}
				// json/yaml carry the MACHINE-READABLE named code on stdout;
				// table/minimal get the same wording on stderr (renderErrorEnvelope
				// declines the human shapes) — the wave-27 contract, unchanged.
				if shape == "json" {
					var envelope struct {
						OK    bool `json:"ok"`
						Error struct {
							Code    string `json:"code"`
							Message string `json:"message"`
							Hint    string `json:"hint"`
						} `json:"error"`
					}
					if err := json.Unmarshal([]byte(stdout), &envelope); err != nil {
						t.Fatalf("error output not JSON: %v\n%s", err, stdout)
					}
					if envelope.OK || envelope.Error.Code != "unreadable_list_page" {
						t.Fatalf("want named refusal unreadable_list_page, got: %s", stdout)
					}
					if !strings.Contains(envelope.Error.Hint, "the transport, not the query") {
						t.Fatalf("refusal must point at the transport: %q", envelope.Error.Hint)
					}
					if !strings.Contains(envelope.Error.Message, "HTTP 200") {
						t.Fatalf("message must name the status that lied: %q", envelope.Error.Message)
					}
				} else if !strings.Contains(stderr, "unreadable list page") {
					t.Fatalf("%s shape said nothing readable on stderr: %q", shape, stderr)
				}
			})
		}
	}

	// CONTROLS — a fence that reds an honest read is a regression, not a fix.
	// Both stay rc=0 with the SAME stdout the unfenced reader produced (these
	// literals were captured from the before-run).
	controls := []struct{ name, body, shape, wantStdout string }{
		{"genuinely_empty_queue", `{"docs":[],"count":0}`, "json", `{"count":0,"docs":[]}`},
		{"genuinely_empty_queue", `{"docs":[],"count":0}`, "table", "(no rows)\n\ncount: 0"},
		{"genuinely_empty_queue", `{"docs":[],"count":0}`, "minimal", "ok"},
		{"populated_queue", `{"docs":[{"_id":"task-1"}],"count":1}`, "json", `{"count":1,"docs":[{"_id":"task-1"}]}`},
		{"populated_queue", `{"docs":[{"_id":"task-1"}],"count":1}`, "table", "_id\n------\ntask-1\n\ncount: 1"},
		{"populated_queue", `{"docs":[{"_id":"task-1"}],"count":1}`, "minimal", "id: task-1"},
	}
	for _, tc := range controls {
		t.Run("control/"+tc.name+"/"+tc.shape, func(t *testing.T) {
			stdout, stderr, code := runPageResponse(t, tc.shape, globals{}, paginatedReadCommand(100), tc.body)
			if code != exitOK {
				t.Fatalf("exit = %d, want %d — the fence reddened an honest read; stderr=%q", code, exitOK, stderr)
			}
			if strings.TrimSpace(stdout) != tc.wantStdout {
				t.Fatalf("stdout drifted from the pre-fence bytes:\n got %q\nwant %q", strings.TrimSpace(stdout), tc.wantStdout)
			}
		})
	}
}

// TestRunCommandUnreadableDefaultPagePreviewIsRuneSafe carries the
// bodyPreview rune-boundary guarantee THROUGH the default-read fence. A
// localised proxy interstitial (Norwegian, Japanese, …) is exactly the body
// this message exists to identify, and it is long and non-ASCII — a byte cut
// would hand the operator U+FFFD noise as the one piece of evidence the
// refusal carries.
func TestRunCommandUnreadableDefaultPagePreviewIsRuneSafe(t *testing.T) {
	body := `<html><head><title>502 Feil gateway</title></head><body>` +
		strings.Repeat("Tjenesten er midlertidig utilgjengelig. Prøv igjen senere. ", 4) +
		`</body></html>`

	stdout, _, code := runPageResponse(t, "json", globals{}, paginatedReadCommand(100), body)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d; stdout=%q", code, exitGeneric, stdout)
	}
	var envelope struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stdout), &envelope); err != nil {
		t.Fatalf("error output not JSON: %v\n%s", err, stdout)
	}
	if envelope.Error.Code != "unreadable_list_page" {
		t.Fatalf("want unreadable_list_page, got %q", envelope.Error.Code)
	}
	if !utf8.ValidString(envelope.Error.Message) || strings.ContainsRune(envelope.Error.Message, utf8.RuneError) {
		t.Fatalf("preview spliced a rune: %q", envelope.Error.Message)
	}
	if !strings.Contains(envelope.Error.Message, "502 Feil gateway") {
		t.Fatalf("preview dropped the identifying head of the page: %q", envelope.Error.Message)
	}
	if !strings.HasSuffix(envelope.Error.Message, "…") {
		t.Fatalf("a 300-byte body must be truncated, not dumped whole: %q", envelope.Error.Message)
	}
}

// TestRunCommandUnreadableDefaultPageIgnoresLimitFlag pins that the fence does
// NOT inherit warnIfDefaultPageMayBeTruncated's `g.limitSet` skip. That skip is
// right for a truncation NOTICE (the caller chose the page size, so a full page
// is no surprise) and catastrophic for a refusal: `bp task ready --limit 5`
// against a proxy 502 would go silent again — the same lie, one flag away.
func TestRunCommandUnreadableDefaultPageIgnoresLimitFlag(t *testing.T) {
	for _, g := range []globals{{}, {limit: 5, limitSet: true}, {limit: 0, limitSet: true}} {
		stdout, stderr, code := runPageResponse(t, "json", g, paginatedReadCommand(100),
			`<html><head><title>502 Bad Gateway</title></head><body>502</body></html>`)
		if code != exitGeneric {
			t.Fatalf("limitSet=%v: exit = %d, want %d; stdout=%q stderr=%q", g.limitSet, code, exitGeneric, stdout, stderr)
		}
		if !strings.Contains(stdout, "unreadable_list_page") {
			t.Fatalf("limitSet=%v: want the named refusal, got %q", g.limitSet, stdout)
		}
	}
}

// TestRunCommandUnreadableFenceIsPaginatedReadsOnly pins the two gates the
// fence carries. A NON-paginated read (`bp doc get`) legitimately returns a
// single document with no list envelope, and a paginated WRITE receipt is not a
// list at all — fencing either would red honest traffic.
func TestRunCommandUnreadableFenceIsPaginatedReadsOnly(t *testing.T) {
	body := `{"_id":"doc-1","title":"a document"}`

	if _, stderr, code := runPageResponse(t, "json", globals{}, nonPaginatedReadCommand(), body); code != exitOK {
		t.Fatalf("non-paginated read reddened: exit = %d, stderr=%q", code, stderr)
	}
	if _, stderr, code := runPageResponse(t, "json", globals{yes: true}, paginatedWriteCommand(100), `{"rev":"abc123","id":"doc-1"}`); code != exitOK {
		t.Fatalf("write receipt reddened: exit = %d, stderr=%q", code, stderr)
	}
}

// TestExtractListRowsBlindToWriteReceipts is the MEASUREMENT behind the
// placement decision (PDS-D396): the fence must not live in renderMinimal.
// extractListRows returns the "" sentinel — the exact signal the fence refuses
// on — for five REAL write receipts, so a fence in the minimal renderer would
// red every write verb in the CLI. Each receipt must still render.
func TestExtractListRowsBlindToWriteReceipts(t *testing.T) {
	receipts := []struct{ name, body string }{
		{"mutate transaction receipt", `{"transactionId":"txn-1","results":[{"id":"doc-1","operation":"update"}]}`},
		{"claim {ok,doc} receipt", `{"ok":true,"doc":{"doc_id":"task-1","claim":{"epoch":3}}}`},
		{"empty-queue {ok:false,reason}", `{"ok":false,"reason":"no_ready"}`},
		{"workspace-create slug receipt", `{"workspace":{"slug":"acme","name":"Acme"}}`},
		{"publish {rev,id} receipt", `{"rev":"abc123","id":"doc-1"}`},
	}
	for _, tc := range receipts {
		t.Run(tc.name, func(t *testing.T) {
			if rows, key := extractListRows(unwrapResult([]byte(tc.body))); key != "" {
				t.Fatalf("extractListRows read a list envelope %q (%d rows) out of a write receipt — the premise of the placement decision has changed; re-audit whether renderMinimal is now a safe fence site", key, len(rows))
			}
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = "minimal"
			renderMinimal(out, unwrapResult([]byte(tc.body)))
			if strings.TrimSpace(stdout.String()) == "" {
				t.Fatalf("write receipt rendered nothing under -o minimal: stderr=%q", stderr.String())
			}
		})
	}
}
