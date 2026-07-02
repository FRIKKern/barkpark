package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

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

// TestExtractListRows covers the pure extraction: first-matching key wins, an
// empty array still counts as a match (so detection works on an empty first
// page), and an unknown envelope yields the "" sentinel that runPaginatedAll
// falls back to "documents" on.
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

func keysOf(m map[string][]json.RawMessage) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}
