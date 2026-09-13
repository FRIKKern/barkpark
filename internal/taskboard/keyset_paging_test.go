package taskboard

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// keyset_paging_test.go — task-6c59bff7cb6b36ee.
//
// THE DEFECT. internal/taskboard issued ONE `GET /v1/tasks?limit=1000` and
// took the answer as the whole world. Over a corpus bigger than the clamp the
// window is desc:updated_at truncated, so a quiet open/ready/blocked row
// rotates out — and from the client side that is indistinguishable from a
// close. main's merge.go does NOT call it a close (it keeps the non-terminal
// row and counts it as aged-out), so this is not a live wrong verdict: it is a
// MISSING CAPABILITY. The board could not tell "rotated out" from "closed"; it
// could only guess conservatively, and pay for the guess with a stale row on
// screen behind an "N aged out of the window" notice nobody can act on.
//
// The api half shipped the cure in PR #16052 (bl-api-tasks-stable-cursor):
// `?cursor=` opts into a `page.next_cursor` keyset token that walks PAST the
// 1000-row cap, declared in the manifest as the task.ls `cursor` arg. These
// tests drive a fake server that holds MORE than the 1000-row clamp and
// require the board to reach the tail.

// pagingServer is a fake /v1/tasks that behaves like the real route: it holds
// `total` rows, answers at most `limit` per page, and mints a `next_cursor`
// token ONLY when the caller spelled `?cursor=`. When `cursorCapable` is false
// it is a PRE-CURSOR server: it ignores the param entirely and its `page` block
// has no `next_cursor` key at all — exactly the envelope an older Barkpark
// answers, and the case the absence heuristic still has to cover.
type pagingServer struct {
	total         int
	limit         int
	cursorCapable bool
	// tailDocIDs are the doc_ids only reachable past the first window — the
	// rows a single-window fetch can never see.
	mu       sync.Mutex
	requests []string
}

func (p *pagingServer) docIDAt(i int) string { return fmt.Sprintf("task-%04d", i) }

func (p *pagingServer) handler(t *testing.T) http.Handler {
	t.Helper()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/tasks":
			p.mu.Lock()
			p.requests = append(p.requests, r.URL.RequestURI())
			p.mu.Unlock()
			p.serveList(t, w, r)
		case "/v1/tasks/prime":
			// Counts report the TRUE corpus total — which is exactly how a
			// single-window fetch used to learn it was truncated.
			_, _ = fmt.Fprintf(w, `{"ok":true,"counts":{"open":%d},"ready":[],"events":[]}`, p.total)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	})
}

func (p *pagingServer) serveList(t *testing.T, w http.ResponseWriter, r *http.Request) {
	t.Helper()
	q := r.URL.Query()

	// The lifecycle-filtered in-flight leg: this fixture holds no in_progress
	// rows, so answer the honest empty page.
	if q.Get("lifecycle_status") != "" {
		_, _ = w.Write([]byte(`{"ok":true,"docs":[],"page":{"next_cursor":null}}`))
		return
	}

	start := 0
	if _, asked := q["cursor"]; asked && p.cursorCapable {
		if tok := q.Get("cursor"); tok != "" {
			if _, err := fmt.Sscanf(tok, "after-%d", &start); err != nil {
				t.Errorf("server got an uninterpretable cursor %q", tok)
				w.WriteHeader(http.StatusBadRequest)
				return
			}
		}
	}

	end := start + p.limit
	if end > p.total {
		end = p.total
	}
	docs := make([]json.RawMessage, 0, end-start)
	for i := start; i < end; i++ {
		docs = append(docs, json.RawMessage(fmt.Sprintf(
			`{"doc_id":%q,"title":"row %d","lifecycle_status":"open","updated_at":"2026-09-12T10:00:00Z"}`,
			p.docIDAt(i), i)))
	}

	page := map[string]any{"limit": p.limit}
	if _, asked := q["cursor"]; asked && p.cursorCapable {
		// Presence, not truthiness — a null token on the last page is the
		// server saying "the walk is finished", not "I cannot page".
		if end < p.total {
			page["next_cursor"] = fmt.Sprintf("after-%d", end)
		} else {
			page["next_cursor"] = nil
		}
	}

	body, err := json.Marshal(map[string]any{"ok": true, "docs": docs, "page": page})
	if err != nil {
		t.Fatalf("marshal page: %v", err)
	}
	_, _ = w.Write(body)
}

func (p *pagingServer) listRequests() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, 0, len(p.requests))
	for _, r := range p.requests {
		if !strings.Contains(r, "lifecycle_status=") {
			out = append(out, r)
		}
	}
	return out
}

// TestSnapshotWalksCursorPagesPastTheThousandRowClamp is the headline arm: a
// corpus of 2,300 rows served 1,000 at a time must arrive COMPLETE, including
// the rows that only exist past the clamp.
func TestSnapshotWalksCursorPagesPastTheThousandRowClamp(t *testing.T) {
	ps := &pagingServer{total: 2300, limit: taskListLimit, cursorCapable: true}
	srv := httptest.NewServer(ps.handler(t))
	defer srv.Close()

	snap, details, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshotFull: %v", err)
	}
	if len(snap.Tasks) != ps.total {
		t.Fatalf("walked %d rows of %d — the fetch stopped inside the corpus", len(snap.Tasks), ps.total)
	}
	if !snap.Exhaustive {
		t.Errorf("a completed cursor walk reported Exhaustive=false; mergeForward will keep guessing")
	}
	// The rows that PROVE the walk crossed the clamp: neither is in the first
	// 1000-row window.
	for _, id := range []string{ps.docIDAt(1000), ps.docIDAt(2299)} {
		if !hasDocID(snap.Tasks, id) {
			t.Errorf("row %s (past the %d-row clamp) is absent from the snapshot", id, taskListLimit)
		}
		if _, ok := details[id]; !ok {
			t.Errorf("row %s is missing from the DetailIndex — pages merged their tasks but not their details", id)
		}
	}
	// Three pages: 1000 + 1000 + 300, each spelling ?cursor=.
	reqs := ps.listRequests()
	if len(reqs) != 3 {
		t.Errorf("list requests = %d (%v), want 3 cursor pages", len(reqs), reqs)
	}
	for _, r := range reqs {
		if !strings.Contains(r, "cursor=") {
			t.Errorf("page request %q did not spell ?cursor= — the server never mints a token for it", r)
		}
	}
}

// TestRotatedOutRowKeepsItsTrueStatusOnACursorServer is the criterion's own
// sentence: a row that a single 1000-row window would have missed must keep its
// true status, and must NOT arrive through the aged-out heuristic (which is a
// guess). Over an exhaustive corpus the row is simply THERE.
func TestRotatedOutRowKeepsItsTrueStatusOnACursorServer(t *testing.T) {
	ps := &pagingServer{total: 1400, limit: taskListLimit, cursorCapable: true}
	srv := httptest.NewServer(ps.handler(t))
	defer srv.Close()

	snap, _, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshotFull: %v", err)
	}
	rotated := ps.docIDAt(1200)

	var got Task
	for _, task := range snap.Tasks {
		if task.DocID == rotated {
			got = task
		}
	}
	if got.DocID == "" {
		t.Fatalf("%s never reached the board", rotated)
	}
	if got.Lifecycle != "open" {
		t.Errorf("%s arrived as %q, want open", rotated, got.Lifecycle)
	}

	// An exhaustive corpus is AUTHORITATIVE about an absence, so mergeForward
	// runs in drop mode: prev-only rows are real closes, not rotation.
	if snapshotTruncated(snap) {
		t.Fatalf("an exhaustive snapshot was still judged truncated — the heuristic stayed armed")
	}
	prev := []Task{{DocID: "task-gone", Lifecycle: "open", UpdatedAt: time.Now()}}
	merged, agedOut := mergeForward(prev, snap.Tasks, snapshotTruncated(snap))
	if agedOut != 0 {
		t.Errorf("agedOut = %d on an exhaustive corpus, want 0", agedOut)
	}
	if hasDocID(merged, "task-gone") {
		t.Errorf("a row absent from a COMPLETE corpus was kept — the board holds closed work on screen")
	}
}

// TestPreCursorServerKeepsTheAbsenceHeuristic is the other half of criterion 2:
// the heuristic survives, and survives for exactly the server that needs it. A
// pre-cursor server ignores ?cursor= and its page block has no next_cursor key,
// so the walk stops at one window and reports Exhaustive=false — which keeps a
// non-terminal prev-only row on screen instead of deleting live work.
func TestPreCursorServerKeepsTheAbsenceHeuristic(t *testing.T) {
	ps := &pagingServer{total: 2300, limit: taskListLimit, cursorCapable: false}
	srv := httptest.NewServer(ps.handler(t))
	defer srv.Close()

	snap, _, err := FetchSnapshotFull(newClient(srv.URL))
	if err != nil {
		t.Fatalf("FetchSnapshotFull: %v", err)
	}
	if len(snap.Tasks) != taskListLimit {
		t.Fatalf("a pre-cursor server answered %d rows, want the one %d-row window", len(snap.Tasks), taskListLimit)
	}
	if snap.Exhaustive {
		t.Fatalf("a one-window fetch claimed Exhaustive — the board would start dropping rotated-out rows as closed")
	}
	if !snapshotTruncated(snap) {
		t.Fatalf("a truncated one-window fetch was not judged truncated; the heuristic is disarmed")
	}
	if len(ps.listRequests()) != 1 {
		t.Errorf("list requests = %d, want 1 — a server that mints no token must not be walked in a loop", len(ps.listRequests()))
	}

	prev := []Task{{DocID: "task-rotated-out", Lifecycle: "open", UpdatedAt: time.Now()}}
	merged, agedOut := mergeForward(prev, snap.Tasks, snapshotTruncated(snap))
	if agedOut != 1 || !hasDocID(merged, "task-rotated-out") {
		t.Errorf("agedOut=%d, kept=%v — the fallback must KEEP a non-terminal row absent from a truncated window",
			agedOut, hasDocID(merged, "task-rotated-out"))
	}
}

// TestNextCursorPresenceIsTheCapabilitySignal pins the detection rule the walk
// turns on, because it is the one place a plausible-looking simplification
// silently breaks paging: the SIGNAL is whether `page.next_cursor` was spelled,
// NOT whether it holds a token. A cursor-capable server sends null on the last
// page; reading that as "not capable" would be harmless here but would make a
// single-page corpus indistinguishable from a pre-cursor server.
func TestNextCursorPresenceIsTheCapabilitySignal(t *testing.T) {
	cases := []struct {
		name        string
		body        string
		wantToken   string
		wantCapable bool
	}{
		{"a token", `{"docs":[],"page":{"next_cursor":"abc"}}`, "abc", true},
		{"null on the last page", `{"docs":[],"page":{"next_cursor":null}}`, "", true},
		{"pre-cursor page block", `{"docs":[],"page":{"limit":1000,"has_more":true}}`, "", false},
		{"no page block at all", `{"docs":[]}`, "", false},
		{"not json", `<html>`, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tok, capable := decodeNextCursor([]byte(tc.body))
			if tok != tc.wantToken || capable != tc.wantCapable {
				t.Errorf("decodeNextCursor = (%q, %v), want (%q, %v)", tok, capable, tc.wantToken, tc.wantCapable)
			}
		})
	}
}

// TestCursorWalkStopsAtThePageCap proves the bound is honest: a server that
// never stops minting tokens is cut off at maxTaskPages AND reported
// Exhaustive=false, so the corpus is never presented as complete when it is not.
func TestCursorWalkStopsAtThePageCap(t *testing.T) {
	var pages int
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		pages++
		n := pages
		mu.Unlock()
		_, _ = fmt.Fprintf(w,
			`{"ok":true,"docs":[{"doc_id":"task-%d","lifecycle_status":"open"}],"page":{"next_cursor":"always-%d"}}`,
			n, n)
	}))
	defer srv.Close()

	tasks, _, exhaustive, err := fetchTaskPages(t.Context(), newClient(srv.URL), listFetchPath)
	if err != nil {
		t.Fatalf("fetchTaskPages: %v", err)
	}
	if exhaustive {
		t.Errorf("a walk cut off at the page cap reported Exhaustive=true")
	}
	if len(tasks) != maxTaskPages {
		t.Errorf("walked %d pages, want the %d-page cap", len(tasks), maxTaskPages)
	}
}

func hasDocID(tasks []Task, id string) bool {
	for _, t := range tasks {
		if t.DocID == id {
			return true
		}
	}
	return false
}
