package cli

// tasks_create_warnings_test.go — `bp task create` must SURFACE the authoring
// advisories the mutate success envelope carries.
//
// The one that matters is `merge_gate_unflagged`: a criterion that OPENS with
// the MERGE-GATED marker but carries no `"merge_gate": true`. The server has
// raised it on the response since the authoring-wall wave — pinned end to end
// in api/test/barkpark_web/controllers/mutate_controller_test.exs ("an
// unflagged MERGE-GATED criterion puts a warning ON THE RESPONSE, not just the
// journal") — and `Barkpark.Plugins.Tasks` documents that "the bp CLI prints
// [it] to stderr (emitWarnings)". On the manifest dispatch path it does. But
// `bp task create` is a BUILT-IN that composes /v1/data/mutate itself, and it
// went from the response straight to the receipt without ever looking at
// `warnings` — so on the ONE path that files acceptance criteria, the warning
// reached nobody. Four rows were filed that way on 2026-09-02, and the
// criterion they named could then be stamped by no builder (the stamp's prose
// guard refuses it) and autostamped by no lead (the close-time autostamp keys
// on the FLAG) — closable by nobody.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// The advisory as the server really sends it (shape and wording copied from the
// mutate controller test above), so this test cannot pass against a shape the
// server does not emit.
const mergeGateUnflaggedWarning = `{"code":"merge_gate_unflagged","severity":"warning",` +
	`"message":"acceptance_criteria [1] open with the MERGE-GATED marker but carry no ` +
	"`merge_gate: true`" + ` - the close-time autostamp keys on the FLAG, not the wording, ` +
	`so a lead merge will not flip them. Add \"merge_gate\": true to each gate entry ` +
	`(soft warning, save proceeds)"}`

func taskCreateWarningServer(t *testing.T) *httptest.Server {
	t.Helper()
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		io.WriteString(rw, `{"results":[{"id":"drafts.task-9","document":`+
			`{"_id":"drafts.task-9","_draft":true,"lifecycle_status":"open"}}],`+
			`"warnings":[`+mergeGateUnflaggedWarning+`]}`)
	}))
	t.Cleanup(ts.Close)
	return ts
}

// HUMAN SHAPE: the advisory reaches stderr, carrying its code and the index of
// the offending criterion — everything the author needs to fix the row before
// anyone claims it.
func TestRunTaskCreateSurfacesMergeGateAdvisory(t *testing.T) {
	ts := taskCreateWarningServer(t)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	if code := runTaskCreate(w, globals{yes: true}, ctx, []string{"a task"}); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	got := se.String()
	if !strings.Contains(got, "warning[merge_gate_unflagged]:") {
		t.Fatalf("the create receipt dropped the server's authoring advisory; stderr:\n%s", got)
	}
	if !strings.Contains(got, "acceptance_criteria [1]") {
		t.Errorf("the advisory reached stderr without the criterion index it names; stderr:\n%s", got)
	}
}

// MACHINE SHAPE: the advisory is a FIELD of the receipt, not only stderr chatter.
// The caller this defect actually bit was a scripted filer reading -o json, and
// a warning it can only see by reading a stream it does not parse is a warning
// it does not get. The stdout document must still be exactly one parseable JSON
// object.
func TestRunTaskCreateJSONReceiptCarriesTheAdvisory(t *testing.T) {
	ts := taskCreateWarningServer(t)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	if code := runTaskCreate(w, globals{yes: true}, ctx, []string{"a task"}); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	var receipt struct {
		ID       string `json:"id"`
		Warnings []struct {
			Code     string `json:"code"`
			Severity string `json:"severity"`
			Message  string `json:"message"`
		} `json:"warnings"`
	}
	if err := json.Unmarshal(so.Bytes(), &receipt); err != nil {
		t.Fatalf("stdout is not one parseable JSON document: %v\ngot: %s", err, so.String())
	}
	if len(receipt.Warnings) != 1 {
		t.Fatalf("machine receipt carried %d warnings, want 1; got: %s", len(receipt.Warnings), so.String())
	}
	if receipt.Warnings[0].Code != "merge_gate_unflagged" || receipt.Warnings[0].Severity != "warning" {
		t.Errorf("advisory lost its code/severity: %+v", receipt.Warnings[0])
	}
	if !strings.Contains(receipt.Warnings[0].Message, "merge_gate") {
		t.Errorf("advisory message did not survive: %q", receipt.Warnings[0].Message)
	}
}

// A create the server had nothing to warn about must not grow a `warnings` key
// — an empty advisory list in every receipt trains a reader to ignore the field.
func TestRunTaskCreateReceiptOmitsWarningsWhenThereAreNone(t *testing.T) {
	ts := taskCreateStubMutate(t, "drafts.task-4")
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	if code := runTaskCreate(w, globals{yes: true}, ctx, []string{"a task"}); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	var receipt map[string]any
	if err := json.Unmarshal(so.Bytes(), &receipt); err != nil {
		t.Fatalf("stdout is not JSON: %v\n%s", err, so.String())
	}
	if _, present := receipt["warnings"]; present {
		t.Errorf("receipt carries a warnings key with nothing to say: %s", so.String())
	}
	if se.Len() != 0 && strings.Contains(se.String(), "warning") {
		t.Errorf("stderr invented a warning: %s", se.String())
	}
}

// Both wire shapes decode: the authoring wall's {code,severity,message} objects
// and the bare strings older emitters send on the same field. A message-less
// entry is dropped rather than rendered as an empty advisory.
func TestMutateWarningsToleratesBothWireShapes(t *testing.T) {
	got := mutateWarnings([]byte(`{"warnings":["plain advisory",` +
		`{"code":"c","severity":"warning","message":"m"},{"code":"x"},{},"" ]}`))
	if len(got) != 2 {
		t.Fatalf("decoded %d warnings, want 2 (the two with a message): %+v", len(got), got)
	}
	if got[0].Message != "plain advisory" || got[0].Code != "" {
		t.Errorf("bare-string warning decoded wrong: %+v", got[0])
	}
	if got[1].Code != "c" || got[1].Message != "m" || got[1].Severity != "warning" {
		t.Errorf("object warning decoded wrong: %+v", got[1])
	}
	if got := mutateWarnings([]byte("not json")); got != nil {
		t.Errorf("an undecodable body must yield nothing, got %+v", got)
	}
}

// A `--publish` create runs the same before_save gate twice, so the same
// advisory arrives on both responses; printing it twice reads as two problems.
func TestDedupeMutateWarningsKeepsOnePerCodeAndMessage(t *testing.T) {
	in := []mutateWarning{
		{Code: "a", Message: "m1"},
		{Code: "a", Message: "m1"},
		{Code: "a", Message: "m2"},
		{Message: "m1"},
	}
	got := dedupeMutateWarnings(in)
	if len(got) != 3 {
		t.Fatalf("dedupe kept %d, want 3 (a/m1, a/m2, ''/m1): %+v", len(got), got)
	}
}
