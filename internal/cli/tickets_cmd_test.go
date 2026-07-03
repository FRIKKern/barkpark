package cli

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestTicketsManifestDispatch proves the tickets verbs fall out of the
// capabilities manifest with ZERO bespoke Go command code: parsed from the
// full-manifest fixture, each ticket / ticket-key command looks up in the tree,
// binds its :id path param, and dispatches to the right method + URL. This is
// the whole point of the manifest-first slice — no Go changes beyond the
// fixture drive the new noun.
func TestTicketsManifestDispatch(t *testing.T) {
	m, tree := loadTreeFrom(t, fullManifest)
	ctx := manifest.Context{Server: "http://localhost:4000"}

	cases := []struct {
		noun, verb string
		method     string
		path       string // flat template (pre-fill)
		args       map[string]string
		wantURL    string
	}{
		{"ticket", "inbox", "GET", "/v1/tickets/inbox", nil,
			"http://localhost:4000/v1/tickets/inbox"},
		{"ticket", "ls", "GET", "/v1/tickets", nil,
			"http://localhost:4000/v1/tickets"},
		{"ticket", "show", "GET", "/v1/tickets/inbox/:id", map[string]string{"id": "tk-7"},
			"http://localhost:4000/v1/tickets/inbox/tk-7"},
		{"ticket", "file", "POST", "/v1/tickets", nil,
			"http://localhost:4000/v1/tickets"},
		{"ticket", "reply", "POST", "/v1/tickets/:id/messages", map[string]string{"id": "tk-7"},
			"http://localhost:4000/v1/tickets/tk-7/messages"},
		{"ticket", "answer", "POST", "/v1/tickets/:id/answer", map[string]string{"id": "tk-7"},
			"http://localhost:4000/v1/tickets/tk-7/answer"},
		{"ticket", "close", "POST", "/v1/tickets/:id/close", map[string]string{"id": "tk-7"},
			"http://localhost:4000/v1/tickets/tk-7/close"},
		{"ticket-key", "mint", "POST", "/v1/plugins/tickets/keys", nil,
			"http://localhost:4000/v1/plugins/tickets/keys"},
		{"ticket-key", "ls", "GET", "/v1/plugins/tickets/keys", nil,
			"http://localhost:4000/v1/plugins/tickets/keys"},
		{"ticket-key", "rotate", "POST", "/v1/plugins/tickets/keys/:id/rotate", map[string]string{"id": "k-1"},
			"http://localhost:4000/v1/plugins/tickets/keys/k-1/rotate"},
		{"ticket-key", "pause", "POST", "/v1/plugins/tickets/keys/:id/pause", map[string]string{"id": "k-1"},
			"http://localhost:4000/v1/plugins/tickets/keys/k-1/pause"},
		{"ticket-key", "revoke", "DELETE", "/v1/plugins/tickets/keys/:id", map[string]string{"id": "k-1"},
			"http://localhost:4000/v1/plugins/tickets/keys/k-1"},
	}

	for _, tc := range cases {
		cmd, ok := tree.Lookup(tc.noun, tc.verb)
		if !ok {
			t.Errorf("%s %s missing from full-manifest fixture", tc.noun, tc.verb)
			continue
		}
		if cmd.HTTP.Method != tc.method || cmd.HTTP.PathTemplate != tc.path {
			t.Errorf("%s %s http = %s %s, want %s %s",
				tc.noun, tc.verb, cmd.HTTP.Method, cmd.HTTP.PathTemplate, tc.method, tc.path)
		}
		gotURL, err := m.BuildURL(*cmd, ctx, tc.args)
		if err != nil {
			t.Errorf("BuildURL %s %s: %v", tc.noun, tc.verb, err)
			continue
		}
		if gotURL != tc.wantURL {
			t.Errorf("%s %s url = %q, want %q", tc.noun, tc.verb, gotURL, tc.wantURL)
		}
	}
}

// TestTicketsPathParamNotInBody asserts the :id path placeholder is consumed by
// the URL and never leaks into a write body — bp ticket reply <id> <body> must
// send {"body":…}, not {"id":…,"body":…}. Same invariant the task claim/close
// tests pin, applied to the ticket noun.
func TestTicketsPathParamNotInBody(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	reply, ok := tree.Lookup("ticket", "reply")
	if !ok {
		t.Fatal("ticket reply missing from full-manifest fixture")
	}

	// bp ticket reply tk-7 "please advise"
	args, err := bindArgs(*reply, []string{"tk-7", "please advise"})
	if err != nil {
		t.Fatalf("bindArgs ticket reply: %v", err)
	}
	body, _, ct, err := buildBody(*reply, map[string][]string{}, args)
	if err != nil {
		t.Fatalf("buildBody ticket reply: %v", err)
	}
	if ct != "application/json" {
		t.Errorf("reply content-type = %q, want application/json", ct)
	}
	var obj map[string]any
	if json.Unmarshal(body, &obj) != nil {
		t.Fatalf("reply body not valid JSON: %s", body)
	}
	if obj["body"] != "please advise" {
		t.Errorf("reply body.body = %v, want \"please advise\"; body = %s", obj["body"], body)
	}
	if _, leaked := obj["id"]; leaked {
		t.Errorf("path arg id must not appear in reply body: %s", body)
	}
}

// TestTicketFileBody asserts the 2-minute first-ticket path: bp ticket file
// <subject> <body> seeds BOTH body args (neither is a path placeholder).
func TestTicketFileBody(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	file, ok := tree.Lookup("ticket", "file")
	if !ok {
		t.Fatal("ticket file missing from full-manifest fixture")
	}
	args, err := bindArgs(*file, []string{"Broken export", "The ONIX file 500s."})
	if err != nil {
		t.Fatalf("bindArgs ticket file: %v", err)
	}
	body, _, _, err := buildBody(*file, map[string][]string{}, args)
	if err != nil {
		t.Fatalf("buildBody ticket file: %v", err)
	}
	var obj map[string]any
	if json.Unmarshal(body, &obj) != nil {
		t.Fatalf("file body not valid JSON: %s", body)
	}
	if obj["subject"] != "Broken export" || obj["body"] != "The ONIX file 500s." {
		t.Errorf("file body = %s, want subject+body", body)
	}
}

// TestTicketAnswerCloseFlag asserts the --close bool flag on ticket answer rides
// as a query param (?close=true) the way applyQuery sends set bool flags — the
// manifest carries it, no Go command code declares it.
func TestTicketAnswerCloseFlag(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	answer, ok := tree.Lookup("ticket", "answer")
	if !ok {
		t.Fatal("ticket answer missing from full-manifest fixture")
	}
	if _, ok := splitFlagLookup(*answer, "close"); !ok {
		t.Fatal("ticket answer must declare the --close flag in the manifest fixture")
	}
	got := applyQuery("http://localhost:4000/v1/tickets/tk-7/answer",
		globals{}, *answer, map[string][]string{"close": {"true"}}, map[string]string{"id": "tk-7"})
	if got != "http://localhost:4000/v1/tickets/tk-7/answer?close=true" {
		t.Errorf("answer --close query = %q, want ...?close=true", got)
	}
}

// TestTicketKeyMintDefaultsToTable pins that mint (and rotate) default to the
// `table` output so the quickstart handoff card renders as the primary human
// output — NOT `minimal`, which would hide the raw key the operator forwards.
func TestTicketKeyMintDefaultsToTable(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)
	for _, verb := range []string{"mint", "rotate"} {
		cmd, ok := tree.Lookup("ticket-key", verb)
		if !ok {
			t.Fatalf("ticket-key %s missing from full-manifest fixture", verb)
		}
		if cmd.DefaultOutput != "table" {
			t.Errorf("ticket-key %s default_output = %q, want table", verb, cmd.DefaultOutput)
		}
	}
}

// TestQuickstartCardRendersVerbatim proves the small renderer touch: a 2xx
// response carrying a string "quickstart" field prints that block verbatim as
// the primary human output under the `table` default (the mint handoff card),
// and NOT under `minimal` (the terse agent receipt keeps the key id line).
func TestQuickstartCardRendersVerbatim(t *testing.T) {
	card := "bptk_live_abc123\n\ncurl -H 'Authorization: Bearer bptk_live_abc123' http://localhost:4000/v1/tickets"
	resp := []byte(`{"result":{"id":"k-1","quickstart":` + mustJSONString(card) + `}}`)

	// table default: the card is printed verbatim.
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	cmd := manifest.Command{DefaultOutput: "table"}
	renderSuccess(w, cmd, resp)
	if got := stdout.String(); got != card+"\n" {
		t.Errorf("table render = %q, want the verbatim card %q", got, card+"\n")
	}

	// minimal: the card is NOT the output — the terse receipt surfaces the id.
	var mStdout, mStderr bytes.Buffer
	wm := newWriter(&mStdout, &mStderr)
	wm.output = "minimal"
	renderSuccess(wm, cmd, resp)
	if got := mStdout.String(); got == card+"\n" {
		t.Errorf("minimal render leaked the full card: %q", got)
	}
	if !bytes.Contains(mStdout.Bytes(), []byte("k-1")) {
		t.Errorf("minimal render should surface the key id; got %q", mStdout.String())
	}
}

// mustJSONString encodes s as a JSON string literal (with surrounding quotes) so
// it can be spliced into a hand-built response body.
func mustJSONString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
