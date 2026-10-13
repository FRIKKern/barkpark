package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// docQueryCommand is doc.query as the live manifest declares it: a paginated
// public read with a default limit of 100 and the `--count` flag that asks the
// server for `total`.
func docQueryCommand() manifest.Command {
	return manifest.Command{
		ID: "doc.query", Noun: "doc", Verb: "query",
		AuthTier:  "none",
		HTTP:      manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/query/:dataset/:type"},
		Paginated: true,
		Args:      []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "limit", Type: "int", Default: 100},
			{Name: "offset", Type: "int", Default: 0},
			{Name: "count", Type: "bool", Default: false},
		},
	}
}

// docQueryPage builds the query envelope the server sends: `count` is the rows
// on this page, `total` (only with ?count=true) is every match.
func docQueryPage(rows int, total int, withTotal bool) []byte {
	docs := make([]json.RawMessage, rows)
	for i := range docs {
		docs[i] = json.RawMessage(fmt.Sprintf(`{"_id":"post-%d","_type":"post","title":"t%d"}`, i, i))
	}
	result := map[string]any{
		"count": rows, "offset": 0, "limit": rows, "perspective": "published",
		"hasMore": total > rows, "documents": docs,
	}
	if withTotal {
		result["total"] = total
	}
	body, _ := json.Marshal(map[string]any{"result": result})
	return body
}

func runDocQueryJSON(t *testing.T, body []byte, g globals, tail []string) (map[string]any, string, string) {
	t.Helper()
	var seenQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)

	cmd := docQueryCommand()
	m := &manifest.Manifest{Commands: []manifest.Command{cmd}}
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g.output, g.outputSet = "json", true
	out.applyGlobals(g)
	code := runCommand(out, g, manifest.Context{Server: srv.URL, Dataset: "production"}, m, cmd, tail)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not one parseable JSON document (%v)\nstdout=%q", err, stdout.String())
	}
	return env, stderr.String(), seenQuery
}

// TestDocQueryCountKeepsTotalAndNamesReturnedRows: with --count the output
// carries `total` (every match) unchanged, keeps `count` as the HTTP contract
// defines it (rows on this page), and adds `returned`, a name that cannot be
// read as the total.
func TestDocQueryCountKeepsTotalAndNamesReturnedRows(t *testing.T) {
	env, _, query := runDocQueryJSON(t, docQueryPage(3, 5000, true),
		globals{limit: 3, limitSet: true}, []string{"post", "--count"})

	if !strings.Contains(query, "count=true") {
		t.Fatalf("--count did not reach the server; query=%q", query)
	}
	if got := env["total"]; got != float64(5000) {
		t.Errorf("total = %v, want 5000 (the full match count)", got)
	}
	if got := env["count"]; got != float64(3) {
		t.Errorf("count = %v, want 3 (rows on this page, as docs/api-v1.md §4 defines it)", got)
	}
	if got := env["returned"]; got != float64(3) {
		t.Errorf("returned = %v, want 3 (rows in this output)", got)
	}
}

// TestDocQueryReturnedNeverOverwritesAServerField: a server that one day sends
// its own `returned` keeps it. The CLI only adds the field when it is absent.
func TestDocQueryReturnedNeverOverwritesAServerField(t *testing.T) {
	cmd := docQueryCommand()
	in := []byte(`{"count":2,"returned":7,"documents":[{"_id":"a"},{"_id":"b"}]}`)
	var env map[string]any
	if err := json.Unmarshal(enrichDocListingRows(cmd, in), &env); err != nil {
		t.Fatal(err)
	}
	if env["returned"] != float64(7) {
		t.Fatalf("returned = %v, want the server's 7", env["returned"])
	}
}

// TestDocQueryJSONKeepsPageWarningsOnStderr pins the stdout contract for the
// page warnings the twin import reported: in `-o json` mode a filled page
// (explicit --limit or the manifest default) must leave stdout as exactly one
// JSON document and put the warning on stderr.
func TestDocQueryJSONKeepsPageWarningsOnStderr(t *testing.T) {
	cases := []struct {
		name string
		g    globals
		rows int
		want string
	}{
		{"explicit limit filled", globals{limit: 5, limitSet: true}, 5, "filled your --limit of 5"},
		{"default limit filled", globals{}, 100, "default limit of 100"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env, stderr, _ := runDocQueryJSON(t, docQueryPage(tc.rows, 10000, false), tc.g, []string{"post"})
			if _, ok := env["documents"]; !ok {
				t.Fatalf("stdout parsed but is not the query envelope: %v", env)
			}
			if !strings.Contains(stderr, tc.want) {
				t.Fatalf("warning %q missing from stderr; stderr=%q", tc.want, stderr)
			}
		})
	}
}
