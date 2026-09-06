package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE DEFECT this file pins.
//
// The API stamps `x-request-id` on EVERY reply — Plug.RequestId runs at the
// endpoint, before the router — so the correlation id an operator quotes to
// find the failure in the logs is always on the wire. The BODY field
// `request_id` is written per-emitter, and dozens of hand-built error envelopes
// across the API never write it.
//
// On the SAME response the two clients disagreed. The JS SDK reads the body
// field and falls back to the header, so it reported an id. `bp` read the body
// field ONLY: `-o json` emitted an envelope with no request_id and `-v` printed
// no `request_id:` line, for an id that had been sitting in the response
// headers the whole time. A `bp cloud …` 500 was therefore impossible to
// correlate against journalctl at exactly the boundary where correlation
// matters.
//
// The fix mirrors the SDK's precedence: body field first (an emitter that wrote
// it meant that exact id), response header second.

// requestIDManifestJSON declares one command on a fixed route so the refusal
// travels the REAL dispatch path (runCommand → handleResponse → classifyError →
// renderError) rather than a hand-called renderer. A hand call would prove the
// decoder reads a header it was handed; only the dispatch proves the header
// SURVIVES the three-value request helpers that discard it.
const requestIDManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "task", "summary": "Tasks."}],
  "commands": [
    {"id":"task.get","noun":"task","verb":"get","summary":"Get a task.",
     "http":{"method":"GET","path_template":"/v1/tasks/x"},
     "auth_tier":"read",
     "args":[],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

// headerOnlyEnvelope is the shape the hand-built emitters send: a canonical
// {code,message} envelope with NO request_id field. This is the body 84 API
// construction sites produce.
const headerOnlyEnvelope = `{"error":{"code":"not_found","message":"not found"}}`

// bodyAndHeaderEnvelope carries its own request_id, so the body must win.
const bodyAndHeaderEnvelope = `{"error":{"code":"not_found","message":"not found","request_id":"req-body-1"}}`

// runRequestIDCase dispatches one command against a server that answers with
// the given body plus an X-Request-Id header, and returns the combined render.
func runRequestIDCase(t *testing.T, output, body, headerID string) (string, string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		rw.Header().Set("Content-Type", "application/json")
		if headerID != "" {
			rw.Header().Set("X-Request-Id", headerID)
		}
		rw.WriteHeader(http.StatusNotFound)
		_, _ = rw.Write([]byte(body))
	}))
	defer srv.Close()

	m, err := manifest.Parse([]byte(strings.Replace(requestIDManifestJSON, "http://replaced", srv.URL, 1)))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	cmd, ok := m.Tree().Lookup("task", "get")
	if !ok {
		t.Fatalf("fixture manifest has no task get")
	}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true, output: output, outputSet: true, verbose: true}
	w.applyGlobals(g)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production", Token: "bppat_test_token"}
	if code := runCommand(w, g, ctx, m, *cmd, nil); code != exitNotFound {
		t.Fatalf("exit = %d, want exitNotFound (%d); stdout=%q stderr=%q", code, exitNotFound, so.String(), se.String())
	}
	return so.String(), se.String()
}

// TestRequestIDFallsBackToResponseHeader is the end-to-end lock in BOTH output
// shapes: a body with no request_id still renders the id the response header
// carried.
//
// RED before the fix: the -o json envelope had no request_id key at all and the
// -o text render printed no `request_id:` line, because classifyError read the
// body only.
func TestRequestIDFallsBackToResponseHeader(t *testing.T) {
	t.Run("json", func(t *testing.T) {
		stdout, stderr := runRequestIDCase(t, "json", headerOnlyEnvelope, "req-hdr-1")
		t.Logf("stdout=%q stderr=%q", stdout, stderr)
		// Non-vacuity: the premise is that the BODY carried no id. If it did,
		// this case would prove nothing about the header.
		if strings.Contains(headerOnlyEnvelope, "request_id") {
			t.Fatalf("fixture body carries a request_id — the case cannot speak to the header fallback")
		}
		var env struct {
			OK    bool `json:"ok"`
			Error struct {
				Code      string `json:"code"`
				RequestID string `json:"request_id"`
			} `json:"error"`
		}
		if err := json.Unmarshal([]byte(stdout), &env); err != nil {
			t.Fatalf("stdout is not the JSON envelope (%v):\n%s", err, stdout)
		}
		if env.Error.RequestID != "req-hdr-1" {
			t.Errorf("error.request_id = %q, want %q — the id was on the wire and bp dropped it:\n%s", env.Error.RequestID, "req-hdr-1", stdout)
		}
	})

	t.Run("text", func(t *testing.T) {
		stdout, stderr := runRequestIDCase(t, "table", headerOnlyEnvelope, "req-hdr-1")
		t.Logf("stdout=%q stderr=%q", stdout, stderr)
		if !strings.Contains(stderr, "request_id: req-hdr-1") {
			t.Errorf("verbose stderr must carry the header's id as `request_id: req-hdr-1`:\n%s", stderr)
		}
	})
}

// TestRequestIDBodyFieldWinsOverHeader pins the PRECEDENCE, mirroring the JS
// SDK's `pickRequestId(envelope) ?? requestIdHeader`. An emitter that wrote the
// field meant that exact id; the header is the fallback, never the override.
func TestRequestIDBodyFieldWinsOverHeader(t *testing.T) {
	t.Run("json", func(t *testing.T) {
		stdout, _ := runRequestIDCase(t, "json", bodyAndHeaderEnvelope, "req-hdr-2")
		var env struct {
			Error struct {
				RequestID string `json:"request_id"`
			} `json:"error"`
		}
		if err := json.Unmarshal([]byte(stdout), &env); err != nil {
			t.Fatalf("stdout is not the JSON envelope (%v):\n%s", err, stdout)
		}
		if env.Error.RequestID != "req-body-1" {
			t.Errorf("error.request_id = %q, want the BODY's %q (header was %q):\n%s", env.Error.RequestID, "req-body-1", "req-hdr-2", stdout)
		}
	})

	t.Run("text", func(t *testing.T) {
		_, stderr := runRequestIDCase(t, "table", bodyAndHeaderEnvelope, "req-hdr-2")
		if !strings.Contains(stderr, "request_id: req-body-1") {
			t.Errorf("verbose stderr must carry the BODY's id:\n%s", stderr)
		}
		if strings.Contains(stderr, "req-hdr-2") {
			t.Errorf("the header overrode the body's request_id:\n%s", stderr)
		}
	})
}

// TestRequestIDHeaderFallbackIsNotInvented guards the other direction: a
// response with NEITHER a body field nor a header must still render no
// request_id — the fallback must not resurrect a stale id from an earlier
// response, and must not print an empty `request_id:` line.
func TestRequestIDHeaderFallbackIsNotInvented(t *testing.T) {
	// Prime the recorded header with a real id first, so a stale read would be
	// visible rather than merely absent.
	runRequestIDCase(t, "table", headerOnlyEnvelope, "req-stale-9")

	_, stderr := runRequestIDCase(t, "table", headerOnlyEnvelope, "")
	if strings.Contains(stderr, "request_id:") {
		t.Errorf("a response with no id on either channel printed a request_id line:\n%s", stderr)
	}
	if strings.Contains(stderr, "req-stale-9") {
		t.Errorf("the id from an EARLIER response leaked into this refusal:\n%s", stderr)
	}
}

// TestClassifyErrorWithHeaderPrecedence is the unit-level statement of the same
// rule, on the seam callers that hold their own headers use.
func TestClassifyErrorWithHeaderPrecedence(t *testing.T) {
	hdr := http.Header{}
	hdr.Set("X-Request-Id", "req-hdr-3")

	if got := classifyErrorWithHeader(404, []byte(headerOnlyEnvelope), hdr).requestID; got != "req-hdr-3" {
		t.Errorf("body without request_id: requestID = %q, want %q", got, "req-hdr-3")
	}
	if got := classifyErrorWithHeader(404, []byte(bodyAndHeaderEnvelope), hdr).requestID; got != "req-body-1" {
		t.Errorf("body with request_id: requestID = %q, want the body's %q", got, "req-body-1")
	}
	if got := classifyErrorWithHeader(404, []byte(headerOnlyEnvelope), nil).requestID; got != "" {
		t.Errorf("no header at all: requestID = %q, want empty", got)
	}
}
