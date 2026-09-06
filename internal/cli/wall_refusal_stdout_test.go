package cli

// task-07a465f262bad05f — EVERY publish-wall refusal reaches STDOUT as one
// parseable envelope under -o json.
//
// THE DEFECT, as MEASURED against guerrilla on 2026-09-06 with a binary built
// from origin/main d971702c4 (not the filing's paraphrase — two of the four
// verbs named in the filing were already correct):
//
//	verb                                   exit  stdout  stderr  envelope
//	task create --publish (client wall)        2       0     429  stderr prose only
//	task create --publish (server 4xx leg)     1       0    2013  stderr prose only
//	doc publish (server unknown_tag)           5     469       0  STDOUT — already correct
//	task landed (refusal)                      4     191       0  STDOUT — already correct
//	doc patch (draft)                          0    1079     135  drafts are not walled
//
// So the hole is exactly `bp task create --publish`, whose refusal arms are CLI
// built-ins that never reach renderError: they speak through out.userErr /
// out.errf, which is stderr unconditionally. A caller doing
// `bp task create … --publish -o json > out.json` gets a 0-byte file and a
// non-zero exit — indistinguishable from "no answer" — while the refusal that
// explains it, and the guarantee that no draft was left behind, sit on a stream
// the caller redirected away.
//
// RED-WITHOUT / GREEN-WITH: revert the renderErrorEnvelopeDetailed early-return
// in renderPublishWallRefusal (tasks_publish_wall.go) and the
// renderCreatePublishRefusalEnvelope branch in runTaskCreate's publish-leg 4xx
// arm, and TestWallRefusalGoesToStdout_* fail with "stdout is EMPTY". The
// doc.publish and task.landed rows are the CONTROL: they pass before and after,
// which is what makes them a regression lock rather than decoration.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// wallEnvelope is the v1 failure envelope as a SCRIPT sees it: decoded from the
// captured stdout bytes with encoding/json, nothing else.
type wallEnvelope struct {
	OK    bool `json:"ok"`
	Error struct {
		Code      string          `json:"code"`
		Message   string          `json:"message"`
		Hint      string          `json:"hint"`
		RequestID string          `json:"request_id"`
		Details   json.RawMessage `json:"details"`
	} `json:"error"`
}

// decodeWallEnvelope is the assertion the whole row is about: the bytes on
// STDOUT parse, ok is false, and error.code is present. A test that only
// grepped the text would pass on a stream carrying prose plus JSON.
func decodeWallEnvelope(t *testing.T, verb string, stdout []byte) wallEnvelope {
	t.Helper()
	if len(bytes.TrimSpace(stdout)) == 0 {
		t.Fatalf("%s: stdout is EMPTY under -o json — a caller redirecting stdout to a file gets 0 bytes and a bare exit code", verb)
	}
	var env wallEnvelope
	if err := json.Unmarshal(stdout, &env); err != nil {
		t.Fatalf("%s: stdout does not parse as JSON (%v):\n%s", verb, err, stdout)
	}
	if env.OK {
		t.Errorf("%s: envelope says ok:true on a refusal", verb)
	}
	if env.Error.Code == "" {
		t.Errorf("%s: envelope carries no error.code — the machine-readable reason is the point:\n%s", verb, stdout)
	}
	return env
}

// ── the client-side wall (no network reaches the mutate endpoint) ────────────

// wallRegistryServer answers ONLY the tag-registry read, authoritatively, and
// FAILS the test if any mutation is attempted. The client wall's contract is
// "refused before writing anything", so a request to /v1/data/mutate would mean
// the guarantee in the envelope's hint is a lie.
func wallRegistryServer(t *testing.T, registered ...string) *httptest.Server {
	t.Helper()
	docs := make([]string, 0, len(registered))
	for _, name := range registered {
		docs = append(docs, `{"_id":"`+name+`"}`)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[` + strings.Join(docs, ",") + `],"hasMore":false}}`))
			return
		}
		t.Errorf("the client-side wall sent a request to %s — it must refuse BEFORE writing anything", req.URL.Path)
		rw.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func runCreateJSON(t *testing.T, server string, tail ...string) (int, string, string) {
	t.Helper()
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: server, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, tail)
	return code, so.String(), se.String()
}

// TestWallRefusalGoesToStdout_CreatePublishUnknownTag — the E3 half of the
// client wall. The refusal names an unregistered tag; under -o json that name,
// and the registry's suggestions, must be on stdout in the SERVER's own
// details shape ({unknown, suggestions}) so one parser reads both walls.
func TestWallRefusalGoesToStdout_CreatePublishUnknownTag(t *testing.T) {
	srv := wallRegistryServer(t, "cli", "tasks", "publish-wall")

	code, stdout, stderr := runCreateJSON(t, srv.URL,
		"a row whose tag is not in the registry",
		"--description", "forcing the unknown_tag arm of the client-side publish wall",
		"--set", `tags:=[{"tag":"no-such-tag-zz","strength":80,"rationale":"a deliberately unregistered tag to force the wall"}]`,
		"--publish")

	t.Logf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage (%d) — the exit code must NOT change", code, exitUsage)
	}
	env := decodeWallEnvelope(t, "task create --publish (unknown_tag)", []byte(stdout))
	if env.Error.Code != "unknown_tag" {
		t.Errorf("error.code = %q, want %q", env.Error.Code, "unknown_tag")
	}
	var d struct {
		Unknown      []string            `json:"unknown"`
		Suggestions  map[string][]string `json:"suggestions"`
		RegistrySize int                 `json:"registry_size"`
	}
	if err := json.Unmarshal(env.Error.Details, &d); err != nil {
		t.Fatalf("details does not parse: %v (%s)", err, env.Error.Details)
	}
	if len(d.Unknown) != 1 || d.Unknown[0] != "no-such-tag-zz" {
		t.Errorf("details.unknown = %v, want [no-such-tag-zz] — the refusal must NAME the tag it refused", d.Unknown)
	}
	if d.RegistrySize != 3 {
		t.Errorf("details.registry_size = %d, want 3", d.RegistrySize)
	}
	// The guarantee a retry loop acts on: nothing to clean up.
	if !strings.Contains(env.Error.Hint, "nothing was created") {
		t.Errorf("hint does not carry the no-draft-left-behind guarantee: %q", env.Error.Hint)
	}
	// Two channels, one message each: the machine envelope owns stdout and the
	// human block is NOT duplicated onto stderr under -o json.
	if strings.TrimSpace(stderr) != "" {
		t.Errorf("stderr should be silent under -o json, got:\n%s", stderr)
	}
}

// TestWallRefusalGoesToStdout_CreatePublishLabelSpine — the E1/E2 half, which is
// PURE: no registry read happens, so the envelope must appear with no server at
// all. details mirrors content/errors.ex's {field, rule, fix, index}.
func TestWallRefusalGoesToStdout_CreatePublishLabelSpine(t *testing.T) {
	srv := wallRegistryServer(t, "cli")

	code, stdout, stderr := runCreateJSON(t, srv.URL,
		"a row with a description far too short",
		"--description", "too short",
		"--set", `tags:=[{"tag":"cli","strength":80,"rationale":"a rationale long enough to clear the wall"}]`,
		"--publish")

	t.Logf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage (%d)", code, exitUsage)
	}
	env := decodeWallEnvelope(t, "task create --publish (label_spine)", []byte(stdout))
	if env.Error.Code != "label_spine" {
		t.Errorf("error.code = %q, want %q", env.Error.Code, "label_spine")
	}
	var d struct {
		Field string `json:"field"`
		Rule  string `json:"rule"`
		Fix   string `json:"fix"`
	}
	if err := json.Unmarshal(env.Error.Details, &d); err != nil {
		t.Fatalf("details does not parse: %v (%s)", err, env.Error.Details)
	}
	if d.Field != "description" {
		t.Errorf("details.field = %q, want \"description\" — the refusal must name WHICH field broke", d.Field)
	}
	if d.Rule == "" || d.Fix == "" {
		t.Errorf("details.rule/fix are empty: %s", env.Error.Details)
	}
}

// ── the server-refused publish leg of `task create --publish` ────────────────

// createPublishRefusalLedger accepts the create, refuses the PUBLISH with a real
// 4xx wall body, and records whether the follow-up discardDraft arrived. The
// discard is the load-bearing side effect: the machine path must still clean up
// the draft it created, or -o json would leave the phantom the human path does
// not.
type createPublishRefusalLedger struct {
	mu             sync.Mutex
	discarded      []string
	refuseDiscard  bool
	publishStatus  int
	publishBody    string
	createdDraftID string
}

func (l *createPublishRefusalLedger) serve(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"cli"}],"hasMore":false}}`))
			return
		}
		var body struct {
			Mutations []map[string]map[string]any `json:"mutations"`
		}
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil || len(body.Mutations) == 0 {
			rw.WriteHeader(http.StatusBadRequest)
			return
		}
		op := body.Mutations[0]
		rw.Header().Set("Content-Type", "application/json")

		if _, ok := op["create"]; ok {
			doc := map[string]any{"_id": l.createdDraftID, "_draft": true}
			_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{map[string]any{"id": l.createdDraftID, "document": doc}}})
			return
		}
		if _, ok := op["publish"]; ok {
			rw.WriteHeader(l.publishStatus)
			_, _ = rw.Write([]byte(l.publishBody))
			return
		}
		if d, ok := op["discardDraft"]; ok {
			id, _ := d["id"].(string)
			l.mu.Lock()
			l.discarded = append(l.discarded, id)
			refuse := l.refuseDiscard
			l.mu.Unlock()
			if refuse {
				rw.WriteHeader(http.StatusNotFound)
				_, _ = rw.Write([]byte(`{"error":{"code":"not_found","message":"document not found"}}`))
				return
			}
			_, _ = rw.Write([]byte(`{"results":[]}`))
			return
		}
		rw.WriteHeader(http.StatusBadRequest)
	}))
	t.Cleanup(srv.Close)
	return srv
}

const wallUnknownTagPublishBody = `{"error":{"code":"unknown_tag","message":"publish references unregistered tag(s): no-such-tag-zz",` +
	`"hint":"Every tags[].tag must be a registered tag.","request_id":"REQ-1",` +
	`"details":{"unknown":["no-such-tag-zz"],"suggestions":{"no-such-tag-zz":["cli"]}}}}`

// TestWallRefusalGoesToStdout_CreatePublishServerRefusal — the leg the client
// wall CANNOT pre-empt: the tags are registered as far as this client can see,
// and the server refuses the publish anyway (a rule this binary predates, a
// duplicate, a registry that moved). Measured on main this arm printed 2013
// bytes of stderr and ZERO bytes of stdout.
func TestWallRefusalGoesToStdout_CreatePublishServerRefusal(t *testing.T) {
	led := &createPublishRefusalLedger{
		createdDraftID: "drafts.task-701",
		publishStatus:  http.StatusUnprocessableEntity,
		publishBody:    wallUnknownTagPublishBody,
	}
	srv := led.serve(t)

	code, stdout, stderr := runCreateJSON(t, srv.URL,
		"a row the server refuses to publish",
		"--description", "the client wall clears this row and the server refuses it anyway",
		"--set", `tags:=[{"tag":"cli","strength":80,"rationale":"a registered tag, so the client wall lets this through"}]`,
		"--publish")

	t.Logf("exit=%d stdout=%q stderr=%q discarded=%v", code, stdout, stderr, led.discarded)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric (%d) — the exit code must NOT change", code, exitGeneric)
	}
	env := decodeWallEnvelope(t, "task create --publish (server refusal)", []byte(stdout))
	if env.Error.Code != "unknown_tag" {
		t.Errorf("error.code = %q, want the SERVER's code %q", env.Error.Code, "unknown_tag")
	}
	if env.Error.RequestID != "REQ-1" {
		t.Errorf("request_id = %q, want REQ-1 — the support handle must survive", env.Error.RequestID)
	}
	var d struct {
		DraftID   string          `json:"draft_id"`
		TaskID    string          `json:"task_id"`
		Discarded bool            `json:"draft_discarded"`
		Server    json.RawMessage `json:"server_details"`
	}
	if err := json.Unmarshal(env.Error.Details, &d); err != nil {
		t.Fatalf("details does not parse: %v (%s)", err, env.Error.Details)
	}
	if d.DraftID != "drafts.task-701" || d.TaskID != "task-701" {
		t.Errorf("details draft_id/task_id = %q/%q, want drafts.task-701/task-701", d.DraftID, d.TaskID)
	}
	if !d.Discarded {
		t.Errorf("details.draft_discarded = false, but the discard was accepted")
	}
	if !strings.Contains(string(d.Server), "no-such-tag-zz") {
		t.Errorf("details.server_details lost the server's own payload: %s", d.Server)
	}
	// The cleanup still happened — the machine shape is not a shortcut past it.
	if len(led.discarded) != 1 || led.discarded[0] != "task-701" {
		t.Errorf("discardDraft calls = %v, want exactly [task-701] — the machine path must clean up its own draft", led.discarded)
	}
	// ONE document on stdout: json.Unmarshal above reads the whole buffer, so a
	// second envelope would already have failed it. Assert the count explicitly
	// anyway, because the discard arm is where a second one would come from.
	if n := strings.Count(stdout, `"ok":false`); n != 1 {
		t.Errorf("stdout carries %d envelopes, want exactly 1 — json.load reads the first value and stops:\n%s", n, stdout)
	}
}

// TestWallRefusalGoesToStdout_CreatePublishServerRefusalDiscardFailed — the
// residue case. The draft could NOT be cleaned up, and a caller that reads only
// stdout must still learn there is a phantom to dispose of.
func TestWallRefusalGoesToStdout_CreatePublishServerRefusalDiscardFailed(t *testing.T) {
	led := &createPublishRefusalLedger{
		createdDraftID: "drafts.task-702",
		publishStatus:  http.StatusConflict,
		publishBody:    `{"error":{"code":"duplicate_of","message":"near-duplicate","details":{"duplicate_of":"task-999"}}}`,
		refuseDiscard:  true,
	}
	srv := led.serve(t)

	code, stdout, _ := runCreateJSON(t, srv.URL,
		"a row the server refuses and whose draft survives",
		"--description", "the publish is refused and the follow-up discard is refused too",
		"--set", `tags:=[{"tag":"cli","strength":80,"rationale":"a registered tag, so the client wall lets this through"}]`,
		"--publish")

	if code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric (%d)", code, exitGeneric)
	}
	env := decodeWallEnvelope(t, "task create --publish (discard failed)", []byte(stdout))
	var d struct {
		Discarded    bool   `json:"draft_discarded"`
		DiscardError string `json:"discard_error"`
		Residue      string `json:"residue"`
		DuplicateOf  string `json:"duplicate_of"`
	}
	if err := json.Unmarshal(env.Error.Details, &d); err != nil {
		t.Fatalf("details does not parse: %v (%s)", err, env.Error.Details)
	}
	if d.Discarded {
		t.Errorf("details.draft_discarded = true, but the discard was REFUSED — a caller would leave a phantom behind")
	}
	if d.DiscardError == "" {
		t.Errorf("details.discard_error is empty: %s", env.Error.Details)
	}
	if d.Residue != residueDiscardFailed {
		t.Errorf("details.residue = %q, want %q", d.Residue, residueDiscardFailed)
	}
	if d.DuplicateOf != "task-999" {
		t.Errorf("details.duplicate_of = %q, want task-999 — the incumbent id is the whole remedy", d.DuplicateOf)
	}
}

// TestWallRefusalKeepsHumanLineOnStderrUnderText is the OTHER half of the
// contract: -o text is untouched. The human block still goes to stderr, and
// stdout stays empty — a terminal user sees exactly what they saw before.
func TestWallRefusalKeepsHumanLineOnStderrUnderText(t *testing.T) {
	srv := wallRegistryServer(t, "cli")
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	ctx := manifest.Context{Server: srv.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{
		"a row whose tag is not in the registry",
		"--description", "forcing the unknown_tag arm of the client-side publish wall",
		"--set", `tags:=[{"tag":"no-such-tag-zz","strength":80,"rationale":"a deliberately unregistered tag to force the wall"}]`,
		"--publish"})

	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage (%d)", code, exitUsage)
	}
	if strings.TrimSpace(so.String()) != "" {
		t.Errorf("-o text put bytes on stdout: %q", so.String())
	}
	for _, want := range []string{"not in the registry", `unknown tag "no-such-tag-zz"`, "nothing was created"} {
		if !strings.Contains(se.String(), want) {
			t.Errorf("-o text stderr lost %q:\n%s", want, se.String())
		}
	}
}

// ── the two verbs that were ALREADY correct: a regression lock ───────────────

// wallManifestJSON declares doc.publish, doc.patch and task.landed with the
// routes the live manifest uses, so the refusal travels the REAL dispatch path
// (runCommand → handleResponse → renderError) rather than a hand-called
// renderer.
const wallManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "doc", "summary": "Documents."}, {"name": "task", "summary": "Tasks."}],
  "commands": [
    {"id":"doc.publish","noun":"doc","verb":"publish","summary":"Publish a draft.",
     "http":{"method":"POST","path_template":"/v1/data/publish/{type}/{id}"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"summary":"Type."},{"name":"id","required":true,"summary":"Id."}],
     "flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":true,"default_output":"table"},
    {"id":"doc.patch","noun":"doc","verb":"patch","summary":"Patch a document.",
     "http":{"method":"PATCH","path_template":"/v1/data/doc/{type}/{id}"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"summary":"Type."},{"name":"id","required":true,"summary":"Id."}],
     "flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":true,"default_output":"table"},
    {"id":"task.landed","noun":"task","verb":"landed","summary":"Record a landing.",
     "http":{"method":"POST","path_template":"/v1/tasks/{doc_id}/landed"},
     "auth_tier":"write",
     "args":[{"name":"doc_id","required":true,"summary":"Task id."}],
     "flags":[{"name":"note","type":"string","summary":"The landing sentence."}],
     "writes":true,"batch":false,"paginated":false,"dry_run":true,"default_output":"table"}
  ]
}`

// TestWallRefusalStaysOnStdoutForManifestVerbs locks the three manifest-dispatched
// write verbs the measurement found ALREADY correct. They are the control for
// the two built-in rows above: if a future edit routes built-in refusals through
// a shape that also moves these, this table reds.
func TestWallRefusalStaysOnStdoutForManifestVerbs(t *testing.T) {
	cases := []struct {
		name   string
		noun   string
		verb   string
		tail   []string
		status int
		body   string
		code   string
	}{
		{
			name: "doc publish / unknown_tag", noun: "doc", verb: "publish",
			tail: []string{"task", "task-1"}, status: http.StatusUnprocessableEntity,
			body: wallUnknownTagPublishBody, code: "unknown_tag",
		},
		{
			name: "doc patch / label_spine", noun: "doc", verb: "patch",
			tail: []string{"task", "task-1"}, status: http.StatusUnprocessableEntity,
			body: `{"error":{"code":"label_spine","message":"the label spine is broken","details":{"field":"tags","rule":"strengths must be distinct","fix":"give one a different value","index":1}}}`,
			code: "label_spine",
		},
		{
			name: "task landed / not_found", noun: "task", verb: "landed",
			tail: []string{"task-nope"}, status: http.StatusNotFound,
			body: `{"error":{"code":"not_found","message":"not found: task not found"}}`,
			code: "not_found",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
				rw.Header().Set("Content-Type", "application/json")
				rw.WriteHeader(tc.status)
				_, _ = rw.Write([]byte(tc.body))
			}))
			defer srv.Close()

			m, err := manifest.Parse([]byte(strings.Replace(wallManifestJSON, "http://replaced", srv.URL, 1)))
			if err != nil {
				t.Fatalf("parse fixture manifest: %v", err)
			}
			cmd, ok := m.Tree().Lookup(tc.noun, tc.verb)
			if !ok {
				t.Fatalf("fixture manifest has no %s %s", tc.noun, tc.verb)
			}
			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			g := globals{yes: true, output: "json"}
			w.applyGlobals(g)
			ctx := manifest.Context{Server: srv.URL, Dataset: "production", Token: "tok"}
			code := runCommand(w, g, ctx, m, *cmd, tc.tail)

			t.Logf("exit=%d stdout=%q stderr=%q", code, so.String(), se.String())
			if code == 0 {
				t.Fatalf("a refusal exited 0")
			}
			env := decodeWallEnvelope(t, tc.name, so.Bytes())
			if env.Error.Code != tc.code {
				t.Errorf("error.code = %q, want %q", env.Error.Code, tc.code)
			}
		})
	}
}
