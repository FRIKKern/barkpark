package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// claimedMutationManifestJSON is the slice of the LIVE manifest this choke
// point needs, copied field-for-field from what the api declares (verified
// against internal/manifest/testdata/capabilities-guerrilla-2026-09-04.json):
// doc.get to probe with, and the four UNGUARDED doors — create,
// create-or-replace, create-if-not-exists and mutate. Note doc.mutate's shape:
// NO args at all, only `--file`. That is the whole reason this guard cannot be
// keyed on positionals.
const claimedMutationManifestJSON = `{
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
     "flags":[{"name":"set","type":"string","repeatable":true,"summary":"Field key=value."},
              {"name":"file","type":"file","summary":"JSON body."}],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"create"},
    {"id":"doc.create-or-replace","noun":"doc","verb":"create-or-replace","summary":"Create or replace a document.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."}],
     "flags":[{"name":"set","type":"string","repeatable":true,"summary":"Field key=value."},
              {"name":"file","type":"file","summary":"JSON body."}],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"createOrReplace"},
    {"id":"doc.create-if-not-exists","noun":"doc","verb":"create-if-not-exists","summary":"Create a document if absent.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."}],
     "flags":[{"name":"set","type":"string","repeatable":true,"summary":"Field key=value."},
              {"name":"file","type":"file","summary":"JSON body."}],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"createIfNotExists"},
    {"id":"doc.mutate","noun":"doc","verb":"mutate","summary":"Apply a raw mutation batch.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[],
     "flags":[{"name":"file","type":"file","summary":"JSON mutation batch."},
              {"name":"quiet","type":"bool","summary":"Suppress the receipt."}],
     "writes":true,"batch":true,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug"},
    {"id":"doc.delete","noun":"doc","verb":"delete","summary":"Delete a document.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"id","required":true,"type":"string","summary":"Document id."}],
     "flags":[],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"delete"},
    {"id":"doc.publish","noun":"doc","verb":"publish","summary":"Publish a draft.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"id","required":true,"type":"string","summary":"Document id."}],
     "flags":[],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"publish"}
  ]
}`

// theMutationRow is the live probe row of 2026-09-16 (task-f74742b835867f8d),
// published and claimed by "w55-probe-holder" at epoch 1 — the row every door
// below was reproduced against before this guard existed.
const theMutationRow = "task-f74742b835867f8d"

const theMutationClaimedBody = `{"result":{"_id":"` + theMutationRow + `","_type":"task","_draft":false,"_rev":"r1",` +
	`"title":"PROBE","description":"…","lifecycle_status":"open",` +
	`"claim":{"worker":"w55-probe-holder","epoch":1,"ts_iso":"2026-09-16T21:38:22.941018Z"}}}`

// theMutationUnclaimedBody is the SAME row with no claim block at all — the
// shape an unclaimed published task really has (the key is absent, not null).
const theMutationUnclaimedBody = `{"result":{"_id":"` + theMutationRow + `","_type":"task","_draft":false,"_rev":"r1",` +
	`"title":"PROBE","description":"…","lifecycle_status":"open"}}`

// mutationHarness stands up a fake instance and records the METHOD and path of
// every request the CLI actually sends. The method is the load-bearing field:
// the refusal's whole promise is that NO non-GET request goes out, and that is
// a fact about the wire, never about the text on stderr.
type mutationHarness struct {
	t       *testing.T
	server  *httptest.Server
	m       *manifest.Manifest
	ctx     manifest.Context
	seen    []string
	docBody string // body the published-row GET answers (empty -> claimed)
	docCode int    // status it answers with (0 -> 200)
}

func newMutationHarness(t *testing.T) *mutationHarness {
	t.Helper()
	h := &mutationHarness{t: t}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			status := h.docCode
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			body := h.docBody
			if body == "" {
				body = theMutationClaimedBody
			}
			if status != http.StatusOK {
				body = `{"error":{"code":"not_found","message":"no such document"}}`
			}
			_, _ = w.Write([]byte(body))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"transactionId":"tx1","results":[{"id":"drafts.` + theMutationRow + `","operation":"create"}]}`))
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(claimedMutationManifestJSON, "http://replaced", h.server.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	h.ctx = manifest.Context{
		Server:            h.server.URL,
		Token:             "tok",
		Workspace:         "acme",
		Project:           "site",
		Dataset:           "production",
		WorkspaceExplicit: true,
		ProjectExplicit:   true,
	}
	return h
}

// nonGETs reports every request the CLI sent that was not a GET. This is THE
// assertion of this file: a guard that fires before the write leaves this list
// empty, whatever it printed.
func (h *mutationHarness) nonGETs() []string {
	var out []string
	for _, s := range h.seen {
		if !strings.HasPrefix(s, "GET ") {
			out = append(out, s)
		}
	}
	return out
}

func (h *mutationHarness) run(verb string, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", verb)
	if !ok {
		h.t.Fatalf("fixture manifest has no doc %s", verb)
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true}
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

// batchFile writes a mutation batch to a temp file and returns the path, so a
// `doc mutate --file` run drives the REAL --file plumbing rather than a
// hand-built request.
func (h *mutationHarness) batchFile(body string) string {
	h.t.Helper()
	p := filepath.Join(h.t.TempDir(), "batch.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		h.t.Fatalf("write batch: %v", err)
	}
	return p
}

// createTail is the argument shape all three create-family doors share — the
// one reproduced live on guerrilla, `--set _id=drafts.<id>`.
func createTail() []string {
	return []string{"task",
		"--set", "_id=drafts." + theMutationRow,
		"--set", "title=W55 TWIN",
		"--set", "description=probe",
		"--set", "kind=task",
		"--set", "lifecycle_status=open"}
}

// THE DEFECT (task-7b13c4042bb0ab7c), reproduced live on guerrilla 2026-09-16:
// each of doc create, doc create-or-replace and doc create-if-not-exists mints
// a claim-less draft twin over a CLAIMED published row, answers with a clean
// `DRAFT created` receipt, and names the one command that can never succeed.
//
// REVERT-RED: drop the guardClaimedDraftMutation call from run.go and the POST
// is sent, so nonGETs() is non-empty and the exit code is exitOK.
func TestCreateFamilyOnClaimedRowSendsNoMutation(t *testing.T) {
	for _, verb := range []string{"create", "create-or-replace", "create-if-not-exists"} {
		t.Run(verb, func(t *testing.T) {
			h := newMutationHarness(t)

			code, _, stderr := h.run(verb, createTail()...)

			if code == exitOK {
				t.Errorf("exit = %d (ok) — an unpublishable draft write must not report success", code)
			}
			if sent := h.nonGETs(); len(sent) > 0 {
				t.Errorf("a non-GET request was issued before the refusal: %v", sent)
			}
			if len(h.seen) == 0 {
				t.Error("the guard never probed the published row at all")
			}
			// The refusal must name WHO holds the row and the sequence that lands
			// the edit. A refusal an operator cannot act on is a different bug.
			for _, want := range []string{"w55-probe-holder", "epoch 1", "discard-draft", claimedDraftMutationFlag} {
				if !strings.Contains(stderr, want) {
					t.Errorf("refusal does not mention %q; got: %s", want, stderr)
				}
			}
		})
	}
}

// doc.mutate IS THE ONE THAT MATTERS. It declares NO positional arguments, so a
// guard keyed on positionals is structurally blind to it — and its batch body
// can carry every other door's op in one request. Both of these were run live
// on guerrilla 2026-09-16 and both landed.
//
// REVERT-RED: drop the guardClaimedDraftMutation call and both send.
func TestMutateBatchOnClaimedRowSendsNoMutation(t *testing.T) {
	batches := map[string]string{
		"createOrReplace op": `{"mutations":[{"createOrReplace":{"_id":"drafts.` + theMutationRow +
			`","type":"task","title":"W55 MUTATE-BATCH TWIN","description":"minted inside a batch"}}]}`,
		"patch op": `{"mutations":[{"patch":{"id":"drafts.` + theMutationRow +
			`","type":"task","set":{"description":"patched inside a batch"}}}]}`,
		"batch-level type, op states none": `{"type":"task","mutations":[{"createOrReplace":{"_id":"drafts.` + theMutationRow +
			`","title":"W55 TWIN"}}]}`,
		"claimed target hidden behind an innocent first op": `{"mutations":[` +
			`{"createOrReplace":{"_id":"drafts.task-someone-else","type":"task","title":"fine"}},` +
			`{"patch":{"id":"drafts.` + theMutationRow + `","type":"task","set":{"description":"the real target"}}}]}`,
	}
	for name, batch := range batches {
		t.Run(name, func(t *testing.T) {
			h := newMutationHarness(t)

			code, _, stderr := h.run("mutate", "--file", h.batchFile(batch))

			if code == exitOK {
				t.Errorf("exit = %d (ok) — a batch that writes an unpublishable draft must not report success", code)
			}
			if sent := h.nonGETs(); len(sent) > 0 {
				t.Errorf("the batch was sent before the refusal: %v", sent)
			}
			if !strings.Contains(stderr, "w55-probe-holder") {
				t.Errorf("refusal does not name the claim holder; got: %s", stderr)
			}
		})
	}
}

// THE QUIET ARM, part one: an UNCLAIMED row. A draft-addressed create on a row
// nobody holds publishes fine, so gating it would be a guard with no subject.
// The write must go out, and NOTHING extra may be printed.
//
// DISCRIMINATION-RED: make the guard unconditional (treat every verdict as
// publishedClaimHeld) and ONLY this arm and the non-task arm below go red.
func TestCreateOnUnclaimedRowProceedsSilently(t *testing.T) {
	h := newMutationHarness(t)
	h.docBody = theMutationUnclaimedBody

	code, _, stderr := h.run("create-or-replace", createTail()...)

	if code != exitOK {
		t.Errorf("exit = %d — a draft write on an UNCLAIMED row is legitimate and must proceed; stderr: %s", code, stderr)
	}
	if sent := h.nonGETs(); len(sent) == 0 {
		t.Errorf("the mutation was withheld on an unclaimed row; requests seen: %v", h.seen)
	}
	if strings.TrimSpace(stderr) != "" {
		t.Errorf("a legitimate write grew an extra sentence: %q", stderr)
	}
}

// THE QUIET ARM, part two: a NON-TASK type. The claim wall compares claim
// blocks only for task content, so there is no subject here — and the guard
// must not even SPEND a probe request finding that out. Exactly one request
// leaves: the mutation itself.
//
// DISCRIMINATION-RED: make the guard unconditional and this arm reds on the
// request COUNT, not on the text.
func TestCreateOnNonTaskTypeSpendsNoProbe(t *testing.T) {
	h := newMutationHarness(t)

	code, _, stderr := h.run("create-or-replace",
		"page", "--set", "_id=drafts.page-abc", "--set", "title=T")

	if code != exitOK {
		t.Errorf("exit = %d — a non-task draft write is not this guard's case; stderr: %s", code, stderr)
	}
	if len(h.seen) != 1 || strings.HasPrefix(h.seen[0], "GET ") {
		t.Errorf("expected exactly the mutation and NO probe request on a non-task type; got %v", h.seen)
	}
	if strings.TrimSpace(stderr) != "" {
		t.Errorf("a non-task write grew an extra sentence: %q", stderr)
	}
}

// THE QUIET ARM, part three: a BARE-id write. `doc delete task <bare id>` goes
// through the SAME route with the SAME body shape as every door above, and must
// sail through without even spending a probe — its op names no draft twin AND
// carries no payload. Both fences agree, and neither is a list of verb names.
// (doc publish would do as well on the predicate, but it has a pre-existing
// stale-cite read of its own, so it cannot measure "no probe was spent".)
func TestBareIDMutationThroughTheSameRouteIsUntouched(t *testing.T) {
	h := newMutationHarness(t)

	code, _, stderr := h.run("delete", "task", theMutationRow)

	if code != exitOK {
		t.Errorf("exit = %d — a bare-id delete is not this guard's case; stderr: %s", code, stderr)
	}
	if len(h.seen) != 1 || strings.HasPrefix(h.seen[0], "GET ") {
		t.Errorf("a bare-id delete should send exactly one non-GET and spend no probe; got %v", h.seen)
	}
}

// THE OPT-IN. --write-claimed-draft lets the write through, and the sentence it
// prints is a MEASUREMENT (it names the holder the probe actually read), not a
// generic warning.
func TestWriteClaimedDraftFlagProceedsWithAMeasuredNotice(t *testing.T) {
	h := newMutationHarness(t)

	code, _, stderr := h.run("create-or-replace", append(createTail(), claimedDraftMutationFlag)...)

	if code != exitOK {
		t.Errorf("exit = %d — %s must let the deliberate write through; stderr: %s", code, claimedDraftMutationFlag, stderr)
	}
	if sent := h.nonGETs(); len(sent) == 0 {
		t.Errorf("the opt-in did not let the write out; requests seen: %v", h.seen)
	}
	for _, want := range []string{"w55-probe-holder", "epoch 1"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("the opt-in notice does not name what the probe measured (%q); got: %s", want, stderr)
		}
	}
}

// UNKNOWN FAILS OPEN, and says so. A probe that cannot answer must never be
// reported as "unclaimed" — the guard proceeds, but with its own sentence.
func TestUnreadableProbeProceedsAndSaysSo(t *testing.T) {
	h := newMutationHarness(t)
	h.docCode = http.StatusInternalServerError

	code, _, stderr := h.run("create-or-replace", createTail()...)

	if code != exitOK {
		t.Errorf("exit = %d — an unreadable probe must not block a write that destroys nothing", code)
	}
	if sent := h.nonGETs(); len(sent) == 0 {
		t.Errorf("the write was withheld on an UNKNOWN verdict; requests seen: %v", h.seen)
	}
	if !strings.Contains(stderr, "could not check") {
		t.Errorf("an unmeasured row was passed over in silence; stderr: %q", stderr)
	}
}

// draftTaskTargets is the predicate itself, exercised on the op shapes measured
// live against guerrilla. The four EXCLUDED verbs are excluded by shape, not by
// name — an enumeration is a snapshot, a predicate is a rule.
func TestDraftTaskTargetsPredicate(t *testing.T) {
	cases := []struct {
		name string
		body string
		want []string
	}{
		{"bare-id publish", `{"mutations":[{"publish":{"id":"task-X","type":"task"}}]}`, nil},
		{"bare-id unpublish", `{"mutations":[{"unpublish":{"id":"task-X","type":"task"}}]}`, nil},
		{"bare-id delete", `{"mutations":[{"delete":{"id":"task-X","type":"task"}}]}`, nil},
		{"bare-id discardDraft", `{"mutations":[{"discardDraft":{"id":"task-X","type":"task"}}]}`, nil},
		// FENCE TWO on its own: a draft-addressed op that lands no bytes.
		{"draft-addressed but addressing-only", `{"mutations":[{"delete":{"id":"drafts.task-X","type":"task"}}]}`, nil},
		{"draft-addressed, ifRevisionID only", `{"mutations":[{"delete":{"id":"drafts.task-X","type":"task","ifRevisionID":"r1"}}]}`, nil},
		// FENCE ONE on its own: payload, but not a task.
		{"draft-addressed page", `{"mutations":[{"createOrReplace":{"_id":"drafts.page-X","type":"page","title":"T"}}]}`, nil},
		{"create", `{"mutations":[{"create":{"_id":"drafts.task-X","type":"task","title":"T"}}]}`, []string{"task-X"}},
		{"createOrReplace", `{"mutations":[{"createOrReplace":{"_id":"drafts.task-X","type":"task","title":"T"}}]}`, []string{"task-X"}},
		{"createIfNotExists", `{"mutations":[{"createIfNotExists":{"_id":"drafts.task-X","type":"task","title":"T"}}]}`, []string{"task-X"}},
		{"patch", `{"mutations":[{"patch":{"id":"drafts.task-X","type":"task","set":{"title":"T"}}}]}`, []string{"task-X"}},
		{"batch-level type", `{"type":"task","mutations":[{"createOrReplace":{"_id":"drafts.task-X","title":"T"}}]}`, []string{"task-X"}},
		{"two ops, one row, no repeat", `{"mutations":[` +
			`{"createOrReplace":{"_id":"drafts.task-X","type":"task","title":"T"}},` +
			`{"patch":{"id":"drafts.task-X","type":"task","set":{"title":"U"}}}]}`, []string{"task-X"}},
		{"two rows, both named", `{"mutations":[` +
			`{"createOrReplace":{"_id":"drafts.task-X","type":"task","title":"T"}},` +
			`{"createOrReplace":{"_id":"drafts.task-Y","type":"task","title":"T"}}]}`, []string{"task-X", "task-Y"}},
		// A VERB NOBODY HAS WRITTEN YET. The predicate covers it because it is a
		// rule about shape, not a list of names.
		{"an unknown future content-landing verb", `{"mutations":[{"createOrMerge":{"_id":"drafts.task-X","type":"task","title":"T"}}]}`, []string{"task-X"}},
		{"not a mutation batch", `{"type":"task"}`, nil},
		{"not JSON", `nonsense`, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := draftTaskTargets([]byte(tc.body))
			if strings.Join(got, ",") != strings.Join(tc.want, ",") {
				t.Errorf("draftTaskTargets = %v, want %v", got, tc.want)
			}
		})
	}
}
