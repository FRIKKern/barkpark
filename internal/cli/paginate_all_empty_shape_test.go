package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// pds-w27-bl-task-next-and-all-corrupt-the-honest-shape, part (b): `--all` must
// preserve the HONEST empty shape. The server answers an empty queue with
// {"count":0,"documents":[]}; the non---all path renders that envelope as sent,
// but the --all re-wrap marshalled a nil []json.RawMessage — Go renders nil
// slices as JSON null — AND dropped `count`, so `jq '.documents[]'` and any
// strict consumer broke on exactly the emptiest, most common page.
//
// The fix: a walk that never advanced past page one renders the server's OWN
// envelope verbatim — byte-compatible with the non---all path by construction,
// `count` and sibling fields included. Multi-page walks keep the re-wrap (a
// stitched walk has no single server body to pass through).

// runAllVsSingle drives the same fake list server through runPaginatedAll
// (--all) and through the plain single-page handleResponse, returning both
// stdouts under -o json.
func runAllVsSingle(t *testing.T, body string) (allOut, singleOut string, allCode int) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}, Paginated: true}

	var allStdout, allStderr bytes.Buffer
	out := newWriter(&allStdout, &allStderr)
	out.output = "json"
	allCode = runPaginatedAll(out, cmd, srv.URL, map[string]string{})

	var singleStdout, singleStderr bytes.Buffer
	sout := newWriter(&singleStdout, &singleStderr)
	sout.output = "json"
	if code := handleResponse(sout, nil, cmd, 200, []byte(body)); code != exitOK {
		t.Fatalf("single-page exit = %d, want %d; stderr=%q", code, exitOK, singleStderr.String())
	}
	return allStdout.String(), singleStdout.String(), allCode
}

func TestRunPaginatedAll_EmptyPageKeepsHonestShape(t *testing.T) {
	body := `{"count":0,"documents":[]}`
	allOut, singleOut, code := runAllVsSingle(t, body)
	if code != exitOK {
		t.Fatalf("--all exit = %d, want %d", code, exitOK)
	}
	// documents is [], never null.
	var env struct {
		Count     *int              `json:"count"`
		Documents []json.RawMessage `json:"documents"`
	}
	if err := json.Unmarshal([]byte(allOut), &env); err != nil {
		t.Fatalf("--all output not JSON: %v\n%s", err, allOut)
	}
	if env.Documents == nil {
		t.Fatalf("--all rendered documents as null on an honest empty page:\n%s", allOut)
	}
	// count survives the walk.
	if env.Count == nil || *env.Count != 0 {
		t.Fatalf("--all dropped or corrupted count:\n%s", allOut)
	}
	// Byte-compatible with the non---all rendering of the same page.
	if allOut != singleOut {
		t.Fatalf("--all diverged from the single-page rendering of the same envelope:\n--all:  %q\nsingle: %q", allOut, singleOut)
	}
}

// A single NON-full page keeps its sibling fields (count included) too: the
// verbatim pass-through is shape-preserving for every walk that fits one page.
func TestRunPaginatedAll_SinglePagePreservesEnvelopeSiblings(t *testing.T) {
	body := `{"count":2,"documents":[{"id":"a"},{"id":"b"}]}`
	allOut, singleOut, code := runAllVsSingle(t, body)
	if code != exitOK {
		t.Fatalf("--all exit = %d, want %d", code, exitOK)
	}
	if allOut != singleOut {
		t.Fatalf("--all diverged from the single-page rendering:\n--all:  %q\nsingle: %q", allOut, singleOut)
	}
}

// The multi-page re-wrap is UNCHANGED (its own tests pin it); this pins only
// that a multi-page walk still renders a real array under the envelope key.
func TestRunPaginatedAll_MultiPageStillRendersArray(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		n := 100
		if offset >= 100 {
			n = 1
		}
		rows := make([]json.RawMessage, n)
		for i := range rows {
			rows[i] = json.RawMessage(`{"id":"x"}`)
		}
		// Distinct identities so the stall detector stays quiet.
		for i := range rows {
			rows[i] = json.RawMessage(`{"id":"x-` + strconv.Itoa(offset+i) + `"}`)
		}
		body, _ := json.Marshal(map[string]any{"documents": rows})
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ready", HTTP: manifest.HTTP{Method: "GET"}, Paginated: true}
	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}); code != exitOK {
		t.Fatalf("exit = %d; stderr=%q", code, stderr.String())
	}
	var got map[string][]json.RawMessage
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output not JSON: %v\n%s", err, stdout.String())
	}
	if len(got["documents"]) != 101 {
		t.Fatalf("row count = %d, want 101", len(got["documents"]))
	}
}
