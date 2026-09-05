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

// cchi-w67-bl-bp-task-ls-has-no-status-filter, criterion 2 — `bp search query
// -o json` must be PARSEABLE at the page cap.
//
// THE REPORTED DEFECT was that the "result page reached the default limit"
// notice was written to STDOUT, ahead of the JSON body, so `json.load` died at
// char 0 — and a JSONDecodeError at char 0 is indistinguishable from a
// transport failure, which is how a filled page (the one case where you most
// need to keep reading) came to look like a broken server.
//
// MEASURED on main before this test existed (bp 3f0139ab6, live against
// guerrilla, 2026-09-05): the notice is already on stderr and the pipe parses.
// So this is a REGRESSION PIN, not a fix — the notice's destination is a
// contract, and nothing was asserting it for `search query`. The warning is
// emitted by warnIfDefaultPageMayBeTruncated via writer.userErr, one shared
// seam for every paginated read; a change there is a change to every
// machine-readable listing at once, and this test is the tripwire.
//
// RED-WITHOUT: flipping userErr to stdout (or moving the emit into
// renderSuccess) fails the json.Unmarshal below, which is the exact failure the
// filing describes.
func TestSearchQueryAtThePageCapStaysParseable(t *testing.T) {
	// search.query as the live manifest declares it: a paginated read whose
	// limit DEFAULT is 50 — the cap the filing names.
	const cap = 50
	searchQuery := manifest.Command{
		ID: "search.query", Noun: "search", Verb: "query",
		HTTP:      manifest.HTTP{Method: "GET", PathTemplate: "/v1/search"},
		Paginated: true,
		Args:      []manifest.Arg{{Name: "q", Required: true, Type: "string", In: "query"}},
		Flags: []manifest.Flag{
			{Name: "limit", Type: "int", Default: cap},
			{Name: "offset", Type: "int", Default: 0},
		},
	}
	m := &manifest.Manifest{Commands: []manifest.Command{searchQuery}}

	// A response that FILLS the page exactly — the only condition that trips
	// the notice, and the condition a real high-hit query produces (`count`
	// dwarfs the page, as measured live: count 9026 over a 50-row page).
	docs := make([]json.RawMessage, cap)
	for i := range docs {
		docs[i] = json.RawMessage(fmt.Sprintf(`{"_id":"doc-%d","title":"hit %d"}`, i, i))
	}
	body, _ := json.Marshal(map[string]any{
		"count": 9026, "hasMore": true, "documents": docs, "query": "task",
	})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "json", outputSet: true}
	out.applyGlobals(g)
	code := runCommand(out, g, manifest.Context{Server: srv.URL}, m, searchQuery, []string{"task"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}

	// THE CRITERION, spelled as the shell pipe spells it: stdout alone, whole,
	// into a JSON parser.
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not one parseable JSON document (%v)\nstdout=%q", err, stdout.String())
	}
	if _, ok := env["documents"]; !ok {
		t.Fatalf("parsed, but the payload is not the search envelope: %v", env)
	}

	// The notice still HAPPENS — a silent truncation would be the other half of
	// the same defect, and a test that only checked parseability would pass on
	// a build that simply deleted the warning.
	if !strings.Contains(stderr.String(), fmt.Sprintf("default limit of %d", cap)) {
		t.Fatalf("the cap notice vanished; stderr=%q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "--all") {
		t.Errorf("the notice names no remedy; stderr=%q", stderr.String())
	}
	// And it is not ALSO on stdout — a duplicate would parse fine on the
	// unmarshal above only because Go stops at the first document, while
	// python's json.load (which reads to EOF) would raise "Extra data".
	if strings.Contains(stdout.String(), "default limit") {
		t.Fatalf("the notice leaked onto stdout; stdout=%q", stdout.String())
	}
}
