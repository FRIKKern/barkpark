package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Pensum's `bp doc query pensumTestRecord --fields kind,payload --all` failed
// on 2026-11-04 with "response exceeds 67108864 bytes". The query route walk
// asked for 1000 rows a page, and 1000 session records with their payloads are
// about 150 MB. These tests lower responseByteCap so a few kilobytes play the
// part of 64 MB.

// lowerResponseCap sets responseByteCap for one test and restores it after.
func lowerResponseCap(t *testing.T, n int64) {
	t.Helper()
	prev := responseByteCap
	responseByteCap = n
	t.Cleanup(func() { responseByteCap = prev })
}

// bigRowServer serves an ordered list of rows, each padded to rowBytes, and
// clamps limit at the query route's 1000. It records every limit it was asked
// for and every body size it sent. mutate, when set, runs before each request
// with the request's offset and may change the list.
type bigRowServer struct {
	mu       sync.Mutex
	ids      []string
	rowBytes int
	limits   []int
	sizes    []int
	mutate   func(offset int, ids []string) []string
}

func (s *bigRowServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	q := r.URL.Query()
	offset, _ := strconv.Atoi(q.Get("offset"))
	if s.mutate != nil {
		s.ids = s.mutate(offset, s.ids)
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	limit = min(max(limit, 1), queryRouteMaxLimit)
	s.limits = append(s.limits, limit)
	end := min(offset+limit, len(s.ids))
	rows := []json.RawMessage{}
	for i := offset; i < end; i++ {
		pad := strings.Repeat("x", s.rowBytes)
		rows = append(rows, json.RawMessage(fmt.Sprintf(`{"_id":%q,"payload":%q}`, s.ids[i], pad)))
	}
	body, _ := json.Marshal(map[string]any{"documents": rows, "count": len(rows), "offset": offset})
	s.sizes = append(s.sizes, len(body))
	_, _ = w.Write(body)
}

func makeIDs(n int) []string {
	ids := make([]string, n)
	for i := range ids {
		ids[i] = fmt.Sprintf("rec-%05d", i)
	}
	return ids
}

func walkQueryAll(t *testing.T, srv *httptest.Server, verbose bool) ([]string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	out.verbose = verbose
	cmd := manifest.Command{ID: "doc.query", Noun: "doc", Verb: "query", Paginated: true,
		HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/query/:dataset/:type"}}
	opts := paginatedAllOpts{pageSize: walkPageSizeFor(cmd)}
	code := runPaginatedAll(out, cmd, srv.URL+"/v1/data/query/test/record", map[string]string{}, opts)
	if code != exitOK {
		return nil, stdout.String() + stderr.String(), code
	}
	var got struct {
		Documents []struct {
			ID string `json:"_id"`
		} `json:"documents"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output is not one JSON document: %v\n%s", err, stdout.String())
	}
	ids := make([]string, len(got.Documents))
	for i, d := range got.Documents {
		ids[i] = d.ID
	}
	return ids, stderr.String(), code
}

// The walk meets an over-cap first page, shrinks the window, and still prints
// every row once and in order as one JSON document. The total is many times one
// page, and every page that was accepted stays under the cap.
func TestQueryAllShrinksPagesThatExceedTheByteCap(t *testing.T) {
	const capBytes = 64 << 10
	lowerResponseCap(t, capBytes)
	const total = 700
	// About 170 bytes a row, so the first 1000-row page is about 2.6 times
	// the cap, the same ratio as Pensum's 150 MB page against 64 MB.
	s := &bigRowServer{ids: makeIDs(total), rowBytes: 140}
	srv := httptest.NewServer(s)
	defer srv.Close()

	ids, stderr, code := walkQueryAll(t, srv, true)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	want := makeIDs(total)
	if len(ids) != total {
		t.Fatalf("walked %d rows, want %d", len(ids), total)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("row %d = %s, want %s", i, ids[i], want[i])
		}
	}
	if s.limits[0] != queryRouteMaxLimit || s.sizes[0] <= capBytes {
		t.Fatalf("first request asked for %d rows and sent %d bytes, want %d rows over the %d cap", s.limits[0], s.sizes[0], queryRouteMaxLimit, capBytes)
	}
	accepted := 0
	for i, n := range s.sizes {
		if n > capBytes {
			continue
		}
		accepted++
		if n > capBytes/2 {
			t.Errorf("request %d sent %d bytes, want well under the %d cap", i, n, capBytes)
		}
	}
	if accepted < 4 {
		t.Fatalf("walk used %d accepted pages for %d rows, want it to span several pages; limits=%v", accepted, total, s.limits)
	}
	if !strings.Contains(stderr, fmt.Sprintf("--all fetched %d pages, %d rows", accepted, total)) {
		t.Fatalf("verbose summary missing or wrong; stderr=%q", stderr)
	}
	if strings.Contains(stderr, "unverified") {
		t.Fatalf("a resized page left a boundary unanchored; stderr=%q", stderr)
	}
}

// A row inserted at the front while the walk runs shifts every later row. The
// walk must notice at the next boundary and walk again, so the output holds
// every row exactly once, with no repeat and no gap.
func TestQueryAllWithResizedPagesRetriesWhenRowsShift(t *testing.T) {
	lowerResponseCap(t, 64<<10)
	const total = 400
	inserted := false
	s := &bigRowServer{ids: makeIDs(total), rowBytes: 1000}
	s.mutate = func(offset int, ids []string) []string {
		// Insert before the first request past page one, so the second page
		// opens one row late.
		if offset > 0 && !inserted {
			inserted = true
			return append([]string{"rec-new"}, ids...)
		}
		return ids
	}
	srv := httptest.NewServer(s)
	defer srv.Close()

	ids, stderr, code := walkQueryAll(t, srv, false)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	if !inserted {
		t.Fatal("test never inserted the row")
	}
	if len(ids) != total+1 {
		t.Fatalf("walked %d rows, want %d", len(ids), total+1)
	}
	seen := map[string]bool{}
	for _, id := range ids {
		if seen[id] {
			t.Fatalf("row %s printed twice", id)
		}
		seen[id] = true
	}
	if ids[0] != "rec-new" {
		t.Fatalf("first row = %s, want rec-new", ids[0])
	}
}

// A single row larger than the cap cannot be paged around. The walk shrinks to
// one row and then reports the cap error instead of looping.
func TestQueryAllReportsARowLargerThanTheCap(t *testing.T) {
	lowerResponseCap(t, 4<<10)
	s := &bigRowServer{ids: makeIDs(10), rowBytes: 8 << 10}
	srv := httptest.NewServer(s)
	defer srv.Close()

	_, stderr, code := walkQueryAll(t, srv, false)
	if code == exitOK {
		t.Fatal("walk succeeded over a row larger than the cap")
	}
	if !strings.Contains(stderr, "refusing to parse a truncated body") {
		t.Fatalf("the error does not name the cap; output=%q", stderr)
	}
	if last := s.limits[len(s.limits)-1]; last != 2 {
		t.Fatalf("last request asked for %d rows, want 2 (one row plus the lookahead)", last)
	}
}

func TestNextWalkPageSize(t *testing.T) {
	lowerResponseCap(t, 64<<20)
	target := int(walkPageByteTarget())
	for _, tc := range []struct {
		name                   string
		pageSize, bytes, maxPS int
		want                   int
	}{
		{"on target keeps the size", 99, target, 999, 100},
		{"twice the target halves", 99, 2 * target, 999, 50},
		{"small body grows at most twice", 99, target / 100, 999, 198},
		{"never past the caller's size", 800, target / 100, 999, 999},
		{"never below one row", 5, 100 * target, 999, 1},
		{"no body keeps the size", 50, 0, 999, 50},
	} {
		if got := nextWalkPageSize(tc.pageSize, tc.bytes, tc.maxPS); got != tc.want {
			t.Errorf("%s: nextWalkPageSize(%d, %d, %d) = %d, want %d", tc.name, tc.pageSize, tc.bytes, tc.maxPS, got, tc.want)
		}
	}
	if got := shrinkWalkPageSize(999); got != 62 {
		t.Errorf("shrinkWalkPageSize(999) = %d, want 62", got)
	}
	if got := shrinkWalkPageSize(2); got != 1 {
		t.Errorf("shrinkWalkPageSize(2) = %d, want 1", got)
	}
}

// The server can fail a heavy page outright before it reaches the client's
// cap. The walk retries that offset with fewer rows and still prints every row
// once and in order.
func TestQueryAllShrinksPagesTheServerFailsWith503(t *testing.T) {
	lowerResponseCap(t, 64<<10)
	const total = 300
	inner := &bigRowServer{ids: makeIDs(total), rowBytes: 100}
	var failed []int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		if limit > 100 {
			failed = append(failed, limit)
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":{"code":"storage_unavailable","message":"the database connection dropped mid-read"}}`))
			return
		}
		inner.ServeHTTP(w, r)
	}))
	defer srv.Close()

	ids, stderr, code := walkQueryAll(t, srv, false)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; output=%q", code, exitOK, stderr)
	}
	if len(failed) == 0 {
		t.Fatal("the server never failed a page, so the test proves nothing")
	}
	want := makeIDs(total)
	if len(ids) != total {
		t.Fatalf("walked %d rows, want %d", len(ids), total)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("row %d = %s, want %s", i, ids[i], want[i])
		}
	}
}

// A server that fails every page is still reported once the window is one
// row, with the server's own error.
func TestQueryAllReportsAServerThatFailsEveryPage(t *testing.T) {
	var limits []int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		limits = append(limits, limit)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"code":"storage_unavailable","message":"the database is down"}}`))
	}))
	defer srv.Close()

	_, output, code := walkQueryAll(t, srv, false)
	if code == exitOK {
		t.Fatal("walk succeeded against a failing server")
	}
	if !strings.Contains(output, "storage_unavailable") {
		t.Fatalf("output does not carry the server's error; output=%q", output)
	}
	if last := limits[len(limits)-1]; last != 2 {
		t.Fatalf("last request asked for %d rows, want 2", last)
	}
}
