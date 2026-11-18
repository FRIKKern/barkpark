package cli

// The check command an ambiguous create hands the person must be able to find
// the row that may have landed (task-e897b05667403f28). An ambiguous create
// leaves at most a DRAFT (drafts.task-N; the publish never ran), and
// /v1/data/search reads the published perspective unless told otherwise, so a
// bare `bp search query "<title>"` answers "not found" for exactly that row, and
// the person files a duplicate.

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func TestTaskCreateAmbiguousHintFindsADraftOnlyRow(t *testing.T) {
	title := "A create whose answer was a server fault"
	code, stdout, _, _ := runScriptedCreate(t, title, [2]string{"500", fault500})
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous", code)
	}
	var env struct {
		Error struct {
			Details struct {
				CheckCommand string `json:"check_command"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not one envelope: %v\n%s", err, stdout)
	}
	check := env.Error.Details.CheckCommand

	// The command, parsed by a shell: bp search query '<title>' flags…
	rest, ok := strings.CutPrefix(check, "bp search query ")
	if !ok {
		t.Fatalf("check command %q is not a bp search query", check)
	}
	tail := shellWords(t, rest)

	// A search door holding only the DRAFT of that row: the published
	// perspective (the default) does not see it.
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		rw.Header().Set("Content-Type", "application/json")
		switch req.URL.Query().Get("perspective") {
		case "drafts", "raw":
			_, _ = rw.Write([]byte(`{"documents":[{"id":"drafts.task-960","title":` + strconv.Quote(title) + `}]}`))
		default:
			_, _ = rw.Write([]byte(`{"documents":[]}`))
		}
	}))
	defer ts.Close()

	m, _ := loadFixtureTree(t)
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	req, derr := buildManifestRequest(globals{}, ctx, m, searchQueryLiveShape(), tail, false)
	if derr != nil {
		t.Fatalf("the check command %q does not build: %v", check, derr)
	}
	httpReq, _ := http.NewRequest(req.method, req.url, nil)
	for k, v := range req.headers {
		httpReq.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if !strings.Contains(string(body), "drafts.task-960") {
		t.Fatalf("the check command %q does not find the draft-only row (request %s); got %s",
			check, req.url, body)
	}
}
