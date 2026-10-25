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

// task-7a470da4ca568e74: `bp doc query --all` walked 18,020 products in
// 100-row pages (181 round-trips, 42 s) where an --offset loop at limit 1000
// took 8.4 s. The query route takes 1000 rows a page, so its walk asks for
// that, and every other route keeps the old window.
func TestWalkPageSizeForQueryRoute(t *testing.T) {
	for id, want := range map[string]int{
		"doc.ls":     queryRouteMaxLimit - 1,
		"doc.query":  queryRouteMaxLimit - 1,
		"task.ls":    defaultWalkPageSize,
		"task.ready": defaultWalkPageSize,
		"media.ls":   defaultWalkPageSize,
	} {
		if got := walkPageSizeFor(manifest.Command{ID: id}); got != want {
			t.Errorf("walkPageSizeFor(%q) = %d, want %d", id, got, want)
		}
	}
}

// A query-route walk over 2,500 rows against a server that clamps limit at
// 1000: three requests, each landing on the clamp, every row once and in order,
// and every boundary anchored (no "unverified" warning).
func TestQueryAllWalksInClampSizedPages(t *testing.T) {
	const total = 2500

	var sawLimits []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		sawLimits = append(sawLimits, q.Get("limit"))
		offset, _ := strconv.Atoi(q.Get("offset"))
		limit, _ := strconv.Atoi(q.Get("limit"))
		limit = min(max(limit, 1), queryRouteMaxLimit)
		n := min(max(total-offset, 0), limit)
		rows := make([]json.RawMessage, n)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"_id":"p-%05d"}`, offset+i))
		}
		body, _ := json.Marshal(map[string]any{"documents": rows, "count": n, "offset": offset})
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{ID: "doc.query", Noun: "doc", Verb: "query", Paginated: true,
		HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/query/:dataset/:type"}}

	opts := paginatedAllOpts{pageSize: walkPageSizeFor(cmd)}
	if code := runPaginatedAll(out, cmd, srv.URL+"/v1/data/query/production/product", map[string]string{}, opts); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}

	var got struct {
		Documents []struct {
			ID string `json:"_id"`
		} `json:"documents"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output not JSON: %v", err)
	}
	if len(got.Documents) != total {
		t.Fatalf("walked %d rows, want %d", len(got.Documents), total)
	}
	for i, row := range got.Documents {
		if want := fmt.Sprintf("p-%05d", i); row.ID != want {
			t.Fatalf("row %d = %s, want %s", i, row.ID, want)
		}
	}
	if len(sawLimits) != 3 {
		t.Fatalf("made %d requests (%v), want 3", len(sawLimits), sawLimits)
	}
	for i, l := range sawLimits {
		if l != "1000" {
			t.Errorf("request %d sent limit=%q, want 1000 (999 + the lookahead row)", i, l)
		}
	}
	if strings.Contains(stderr.String(), "unverified") {
		t.Errorf("unexpected unverified-boundary warning: %q", stderr.String())
	}
}
