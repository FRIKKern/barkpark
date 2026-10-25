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

// task-2b8d011b6c573467: `bp media ls --all` warned "pagination boundary at
// offset 1300 is unverified" while returning every row. A server that clamps
// the limit to the page size never sends the lookahead row, and on the LAST
// full page there is no next row to send anyway. The warning now waits for the
// next page and is printed only when that page has rows.
func TestPaginatedAllWarnsOnlyForABoundaryWithRowsPastIt(t *testing.T) {
	const pageSize = 10
	total := 3 * pageSize // the list ends exactly on a page edge
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		if limit > pageSize {
			limit = pageSize // the clamp: no lookahead row, ever
		}
		rows := []json.RawMessage{}
		for i := offset; i < offset+limit && i < total; i++ {
			rows = append(rows, json.RawMessage(fmt.Sprintf(`{"id":"m-%03d","doc_id":"m-%03d"}`, i, i)))
		}
		body, _ := json.Marshal(map[string]any{"docs": rows})
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "media", Verb: "ls", HTTP: manifest.HTTP{Method: "GET"}, Paginated: true}

	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}, paginatedAllOpts{pageSize: pageSize}); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}
	if got := len(servedDocIDs(t, stdout.Bytes())); got != total {
		t.Fatalf("rows = %d, want %d", got, total)
	}
	warned := strings.Count(stderr.String(), "is unverified")
	// Boundaries at 10 and 20 have rows past them: unverified, and said. The
	// one at 30 is the end of the list: no warning.
	if warned != 2 || strings.Contains(stderr.String(), "offset 30 is unverified") {
		t.Fatalf("want exactly the boundaries at 10 and 20 warned; stderr=%q", stderr.String())
	}
}
