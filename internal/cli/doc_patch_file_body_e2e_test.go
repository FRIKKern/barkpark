package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ---------------------------------------------------------------------------
// scaffy-backlog-doc-patch-file-flag — THE END-TO-END ARM THE ROW STILL OWED.
//
// The row's criterion 2 asks for "a dry-run and disposable-document smoke [that]
// apply a nested multi-kilobyte JSON patch from a file". Two rounds recorded it
// as impossible: the api manifest declares `[set]` only for doc.patch, so
// splitArgs exits 2 on --file before any request is built, and the only proof
// available was PR #18616's TestSetKeyFileBody* — which drive buildBody with
// SYNTHETIC manifest.Command structs. A hand-built struct cannot show that a
// manifest the SERVER sends, parsed by manifest.Parse and dispatched by
// runCommand, produces the right bytes on the wire.
//
// "Impossible" was true only of the PROD manifest. This package has served its
// own capabilities JSON since claimed_draft_patch_guard_test.go, so the smoke is
// reachable today: serve the doc.patch slice as it will read the day the api
// lane adds its one line, run the real command, and read the body the fake
// instance actually received.
//
// WHAT THIS PINS is PR #18616's routing in run.go (~line 2310 and ~line 2357):
// a --file object on a command declaring set_key becomes the SET PAYLOAD rather
// than the body base. Revert either hunk and TestDocPatchFileBodyNestsUnderSet
// reds with the fields sitting as siblings of an empty "set" — the exact
// malformed body cli-r20-w35 measured on 2026-09-16 and which made this row's
// originally prescribed remedy wrong.
//
// FENCE: internal/cli/ only. The remaining fix — one flag() line in
// api/lib/barkpark/plugins/capabilities.ex plus its cli_commands_manifest_test
// coverage and an OpenAPI regen — is the api lane's, exactly as the settled
// precedent for this defect class (PR #3810, scaffy-w4-file-flag-fix) was:
// 2 files, both under api/, zero Go lines.
// ---------------------------------------------------------------------------

// docPatchManifest renders the two-command slice this smoke needs. withFile
// selects between the manifest the api serves TODAY (flags: [set]) and the one
// it serves after the row's remaining one-liner lands (flags: [file, set]) —
// the SAME JSON otherwise, so any difference in behaviour below is attributable
// to that one declaration and to nothing else.
//
// doc.create is carried alongside as the flat-merge control: it declares a file
// flag and NO set_key, so its file body must keep landing at the top level.
func docPatchManifest(withFile bool) string {
	patchFlags := `{"name":"set","type":"string","repeatable":true,"summary":"Field key=value to change."}`
	if withFile {
		// Verbatim the line the api lane owes this row, as manifest JSON.
		patchFlags = `{"name":"file","type":"file","summary":"Fields to change as a JSON object from a file or - for stdin."},` + patchFlags
	}
	return `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "doc", "summary": "Documents."}],
  "commands": [
    {"id":"doc.get","noun":"doc","verb":"get","summary":"Fetch one document by type and id.",
     "http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"doc_id","required":true,"type":"string","summary":"Document id."}],
     "flags":[{"name":"perspective","type":"string","default":"published","summary":"published | drafts | raw."}],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table","scoped_prefix":"/w/:workspace_slug/p/:project_slug"},
    {"id":"doc.create","noun":"doc","verb":"create","summary":"Create a document.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."}],
     "flags":[{"name":"file","type":"file","summary":"Document fields as a JSON object from a file or - for stdin."},
              {"name":"set","type":"string","repeatable":true,"summary":"Field key=value."}],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"create"},
    {"id":"doc.patch","noun":"doc","verb":"patch","summary":"Patch a document.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"id","required":true,"type":"string","summary":"Document id."}],
     "flags":[` + patchFlags + `],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"patch","set_key":"set"}
  ]
}`
}

// thePatchedRow is an ordinary published, UNCLAIMED task row — the disposable
// document this smoke patches. Unclaimed on purpose: a claimed row is refused
// before the body is built (claimed_draft_patch_guard_test.go), and a guard
// firing first would make every assertion here vacuous.
const thePatchedRow = "task-file-body-smoke"

const theUnclaimedSmokeDoc = `{"result":{"_id":"` + thePatchedRow + `","_type":"task","_draft":false,` +
	`"_rev":"r1","title":"PROBE","lifecycle_status":"open"}}`

// filePatchHarness stands up a fake instance and records the RAW body of every
// mutation. Recording the path would only prove a write happened; the row's
// defect is about which SHAPE goes with it.
type filePatchHarness struct {
	t    *testing.T
	m    *manifest.Manifest
	ctx  manifest.Context
	sent []string
}

func newFilePatchHarness(t *testing.T, withFile bool) *filePatchHarness {
	t.Helper()
	h := &filePatchHarness{t: t}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/") {
			_, _ = w.Write([]byte(theUnclaimedSmokeDoc))
			return
		}
		raw, _ := io.ReadAll(r.Body)
		h.sent = append(h.sent, string(raw))
		_, _ = w.Write([]byte(`{"transactionId":"tx1","results":[{"id":"` + thePatchedRow + `","operation":"update"}]}`))
	}))
	t.Cleanup(srv.Close)

	m, err := manifest.Parse([]byte(strings.Replace(docPatchManifest(withFile), "http://replaced", srv.URL, 1)))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	h.ctx = manifest.Context{
		Server: srv.URL, Token: "tok", Workspace: "acme", Project: "site",
		Dataset: "production", WorkspaceExplicit: true, ProjectExplicit: true,
	}
	return h
}

// run drives the real runCommand — the whole dispatch, not buildBody in
// isolation — so an edit that moves or bypasses the routing reds here.
func (h *filePatchHarness) run(noun, verb string, tail ...string) (int, string, string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup(noun, verb)
	if !ok {
		h.t.Fatalf("fixture manifest has no %s %s", noun, verb)
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	code := runCommand(w, globals{}, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

// mutation decodes the single mutation the harness captured and returns the
// operation's object. It FAILS rather than returning a zero value on every
// miss: an empty map would let the assertions below pass for free, which is the
// failure mode a wire-shape test is most prone to.
func (h *filePatchHarness) mutation(op string) map[string]any {
	h.t.Helper()
	if len(h.sent) != 1 {
		h.t.Fatalf("want exactly 1 mutation on the wire, got %d — nothing was measured", len(h.sent))
	}
	var env struct {
		Mutations []map[string]json.RawMessage `json:"mutations"`
	}
	if err := json.Unmarshal([]byte(h.sent[0]), &env); err != nil {
		h.t.Fatalf("mutation body is not JSON: %v\nbody=%s", err, h.sent[0])
	}
	if len(env.Mutations) != 1 {
		h.t.Fatalf("want 1 mutation entry, got %d: %s", len(env.Mutations), h.sent[0])
	}
	raw, ok := env.Mutations[0][op]
	if !ok {
		h.t.Fatalf("mutation is not a %q: %s", op, h.sent[0])
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		h.t.Fatalf("%q operation is not an object: %v", op, err)
	}
	return out
}

// writeBody writes a JSON body file and returns its path.
func writeBody(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "body.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write body file: %v", err)
	}
	return p
}

// theNestedBody is the payload class that forced the raw-HTTP fallback this row
// was filed for: a structured array too large and too nested to ride --set on a
// command line. Kept small enough to read, deep enough that a flat merge or a
// stringified value would be visible.
const theNestedBody = `{"blocks":[{"type":"paragraph","content":[{"type":"span","text":"one"}]},` +
	`{"type":"heading","level":2,"content":[{"type":"span","text":"two"}]}],` +
	`"title":"patched from a file"}`

// TestDocPatchFileBodyNestsUnderSet is the arm that REDS ON REVERSION.
//
// RED PROOF (run by hand before committing): in run.go, change the file-object
// seed from `if cmd.SetKey == "" && fileObj != nil` to `if fileObj != nil`, or
// drop the `setTarget = fileObj` assignment in the SetKey branch. Either reds
// here with the fields found as siblings of an empty "set".
func TestDocPatchFileBodyNestsUnderSet(t *testing.T) {
	h := newFilePatchHarness(t, true)

	code, _, stderr := h.run("doc", "patch", "task", thePatchedRow, "--file", writeBody(t, theNestedBody))
	if code != exitOK {
		t.Fatalf("exit = %d, stderr=%s — the smoke never reached the wire", code, stderr)
	}

	patch := h.mutation("patch")

	// The addressing keys stay where the writer reads them.
	if patch["id"] != thePatchedRow {
		t.Errorf("patch.id = %v, want %q", patch["id"], thePatchedRow)
	}
	if patch["type"] != "task" {
		t.Errorf("patch.type = %v, want \"task\"", patch["type"])
	}

	set, ok := patch["set"].(map[string]any)
	if !ok {
		t.Fatalf("patch.set is not an object: %#v", patch["set"])
	}
	if len(set) == 0 {
		t.Fatalf("patch.set is EMPTY — this is the malformed body measured 2026-09-16: the "+
			"file's fields did not reach the set map. patch=%#v", patch)
	}

	// The file's own keys must be UNDER set, and must not have leaked up beside
	// it. Asserting both directions is what separates "routed" from "copied".
	for _, key := range []string{"blocks", "title"} {
		if _, under := set[key]; !under {
			t.Errorf("patch.set is missing %q — the file body did not land under the set key", key)
		}
		if _, sibling := patch[key]; sibling {
			t.Errorf("%q is a SIBLING of patch.set — a --file object on a set_key command must "+
				"become the set payload, not the body base; the writer does not read siblings "+
				"as field changes. patch=%#v", key, patch)
		}
	}

	// Structure survived: a nested array is still an array of objects, not a
	// string. A body that round-tripped through a --set value would fail here.
	blocks, ok := set["blocks"].([]any)
	if !ok || len(blocks) != 2 {
		t.Fatalf("set.blocks is not a 2-element array: %#v", set["blocks"])
	}
	first, ok := blocks[0].(map[string]any)
	if !ok || first["type"] != "paragraph" {
		t.Fatalf("set.blocks[0] lost its structure: %#v", blocks[0])
	}
}

// TestDocPatchFileBodyMergesWithSet proves --set stays backward compatible on
// top of a file body, which is the second half of the row's criterion 2. Without
// it, "the file becomes the set payload" could have been implemented by having
// the file REPLACE the set map.
func TestDocPatchFileBodyMergesWithSet(t *testing.T) {
	h := newFilePatchHarness(t, true)

	code, _, stderr := h.run("doc", "patch", "task", thePatchedRow,
		"--file", writeBody(t, theNestedBody), "--set", "lifecycle_status=closed")
	if code != exitOK {
		t.Fatalf("exit = %d, stderr=%s", code, stderr)
	}

	set, ok := h.mutation("patch")["set"].(map[string]any)
	if !ok {
		t.Fatalf("patch.set is not an object")
	}
	if set["lifecycle_status"] != "closed" {
		t.Errorf("--set key missing from patch.set: %#v", set)
	}
	if _, ok := set["blocks"]; !ok {
		t.Errorf("--set overwrote the file body instead of merging onto it: %#v", set)
	}
}

// TestDocPatchWithoutFileFlagRefusesFileAndHelpAgrees is the LIVE DEFECT, held
// still. It serves the manifest the api declares TODAY and asserts the two
// halves this row is about agree with each other: the parser refuses --file,
// AND the body help line does not advertise it.
//
// This arm is the QUIET one — it is about the manifest shape, not about the
// routing, so reverting PR #18616 leaves it passing. That is the point: a
// control that moves with the thing it controls proves nothing.
func TestDocPatchWithoutFileFlagRefusesFileAndHelpAgrees(t *testing.T) {
	h := newFilePatchHarness(t, false)

	code, _, stderr := h.run("doc", "patch", "task", thePatchedRow, "--file", writeBody(t, theNestedBody))
	if code != exitUsage {
		t.Errorf("exit = %d, want %d (usage) — a manifest declaring only --set must refuse --file",
			code, exitUsage)
	}
	if !strings.Contains(stderr, "--file") {
		t.Errorf("refusal does not name the rejected flag: %s", stderr)
	}
	if len(h.sent) != 0 {
		t.Errorf("a refused flag must not send a mutation; got %d: %v", len(h.sent), h.sent)
	}

	// The half #18603 fixed, re-pinned against a PARSED manifest rather than a
	// hand-built struct: help must not advertise what the manifest refuses.
	cmd, _ := h.m.Tree().Lookup("doc", "patch")
	hint := writeBodyHint(*cmd)
	if hint == "" {
		t.Fatal("writeBodyHint is empty for doc.patch — this arm measured nothing")
	}
	if strings.Contains(hint, "--file") {
		t.Errorf("body help advertises --file while the manifest refuses it — that contradiction "+
			"IS this row's defect. hint=%q", hint)
	}
}

// TestDocPatchWithFileFlagHelpAdvertisesIt closes the agreement in the other
// direction: the day the api lane lands the declaration, help must start naming
// the flag. Without this arm, "help and manifest agree" would be satisfiable by
// a writeBodyHint that never says --file at all.
func TestDocPatchWithFileFlagHelpAdvertisesIt(t *testing.T) {
	h := newFilePatchHarness(t, true)
	cmd, _ := h.m.Tree().Lookup("doc", "patch")

	hint := writeBodyHint(*cmd)
	if !strings.Contains(hint, "--file") {
		t.Errorf("doc.patch declares a file flag but the body help omits it: %q", hint)
	}
	if !strings.Contains(hint, "--set") {
		t.Errorf("the file flag must not displace --set in the help: %q", hint)
	}
}

// TestFlatWriteFileBodyStaysFlat is the second QUIET control: a write with NO
// set_key is untouched by the routing under test. doc.create's file body must
// keep landing at the top level of its mutation. If a future edit "simplifies"
// the SetKey branch into an unconditional nest, this reds while the doc.patch
// arms above stay green — which is how the two are told apart.
func TestFlatWriteFileBodyStaysFlat(t *testing.T) {
	h := newFilePatchHarness(t, true)

	code, _, stderr := h.run("doc", "create", "task", "--file", writeBody(t, theNestedBody))
	if code != exitOK {
		t.Fatalf("exit = %d, stderr=%s", code, stderr)
	}

	create := h.mutation("create")
	if _, ok := create["blocks"]; !ok {
		t.Errorf("doc.create has no set_key, so its file body must merge FLAT into the mutation; "+
			"blocks is missing. create=%#v", create)
	}
	if _, nested := create["set"]; nested {
		t.Errorf("doc.create grew a \"set\" wrapper it never declared: %#v", create)
	}
}
