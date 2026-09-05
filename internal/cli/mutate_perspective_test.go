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

// THE MEASUREMENT THIS FILE LOCKS (spd-doc-mutate-rev-reads-as-success).
//
// RED WITHOUT the emitter — MEASURED through this exact harness by deleting the
// one `emitMutatePerspective(out, cmd, respBody)` line from run.go (anchor
// asserted present exactly once first, diff asserted non-empty) and re-running:
//
//	--- FAIL: TestMutateDraftOnlyWriteSaysThePublishedRowIsUnchanged/minimal
//	    the receipt never said the write went to a DRAFT.
//	    stdout="rev: tx-77\n"
//	--- FAIL: …/table  --- FAIL: …/json  --- FAIL: …/yaml
//	--- FAIL: TestMutatePublishedChangePrintsTheOtherWording
//	    a published-row change did not say so.
//	    stdout="rev: tx-78\n" stderr=""
//	--- FAIL: TestMutatePerspectiveKeepsJSONByteIdentical
//	--- FAIL: TestMutateStaleDraftBaseIsNamed
//
// THAT IS THE WHOLE TRAP, in two captures side by side: a draft-only write and
// a real published change printed `rev: tx-77` and `rev: tx-78` — the SAME
// shape, differing only in a hash nobody can interpret. Indistinguishable.
//
// The pre-existing emitWarnings (run.go) did print #15851's advisory MESSAGE,
// but only in `minimal` and `table` (its stderr in the json/yaml red arms is
// empty), and only when the server chose to warn — a `--file` batch addressing
// `drafts.<id>` directly forks nothing, warns about nothing, and was the exact
// reproduction filed on this row. The verdict line is unconditional.
//
// GREEN WITH the emitter: all six tests / fourteen subtests pass; the run
// output is quoted in the PR body.

// fakeMutateAPI answers a mutate POST and a published document GET on one
// httptest server, so the draft-only test can assert BOTH halves of the
// criterion: the CLI says the published row is unchanged, AND a published read
// really does still return the pre-mutate body.
type fakeMutateAPI struct {
	mutateBody string
	// published is the body /v1/data/doc/... returns. The mutate handler NEVER
	// touches it — that is the point: the write went to the draft twin.
	published string
	// publishedReads counts GETs of the published row, so a test can prove the
	// verdict was derived from the mutate envelope and not from a second read.
	publishedReads int
	mutatePosts    int
}

func (f *fakeMutateAPI) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost {
			f.mutatePosts++
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(f.mutateBody))
			return
		}
		f.publishedReads++
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(f.published))
	})
}

func mutateCommand() manifest.Command {
	return manifest.Command{
		ID:            "doc.mutate",
		Noun:          "doc",
		Verb:          "mutate",
		HTTP:          manifest.HTTP{Method: http.MethodPost, PathTemplate: "/v1/data/mutate/production"},
		Writes:        true,
		DefaultOutput: "minimal",
	}
}

func docGetCommand() manifest.Command {
	return manifest.Command{
		ID:            "doc.get",
		Noun:          "doc",
		Verb:          "get",
		HTTP:          manifest.HTTP{Method: http.MethodGet, PathTemplate: "/v1/data/doc/production/post/p1"},
		DefaultOutput: "json",
	}
}

// draftOnlyMutateBody is #15851's envelope shape for the reported reproduction:
// a patch naming the BARE published id `p1`, which the server applied to the
// draft twin `drafts.p1` and warned about. Every field this emitter reads is a
// real key of that response — results[].document carries the Content.Envelope
// reserved keys (_draft/_publishedId/_type), and `warnings` is the advisory
// channel MutateController drains into the success body.
const draftOnlyMutateBody = `{
  "transactionId": "tx-77",
  "results": [
    {"id": "drafts.p1", "operation": "update",
     "document": {"_id":"drafts.p1","_type":"post","_rev":"r2","_draft":true,"_publishedId":"p1","title":"NEW"}}
  ],
  "warnings": [
    {"code":"patch.forked_published","severity":"warning",
     "message":"this patch names a published document but writes a DRAFT twin (` + "`drafts.p1`" + `)."}
  ]
}`

// publishedChangedMutateBody is the CONTROL: the same verb, the same rev-shaped
// receipt, but the server says the write landed on the published row.
const publishedChangedMutateBody = `{
  "transactionId": "tx-78",
  "results": [
    {"id": "p1", "operation": "update",
     "document": {"_id":"p1","_type":"post","_rev":"r3","_draft":false,"_publishedId":"p1","title":"NEW"}}
  ]
}`

// unchangedPublished is what a published read returns before AND after the
// draft-only mutate: the OLD title.
const unchangedPublished = `{"result":{"_id":"p1","_type":"post","_rev":"r1","_draft":false,"title":"OLD"}}`

func runAgainst(t *testing.T, srvURL, shape string, cmd manifest.Command) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: shape, outputSet: true, yes: true}
	out.applyGlobals(g)
	code := runCommand(out, g, manifest.Context{Server: srvURL}, &manifest.Manifest{}, cmd, nil)
	return stdout.String(), stderr.String(), code
}

// TestMutateDraftOnlyWriteSaysThePublishedRowIsUnchanged is criterion c1. It
// drives a real mutate through runCommand against a fake API answering
// #15851's envelope, then reads the published row through the SAME server and
// asserts it never moved — the two halves the ledger trap kept apart.
func TestMutateDraftOnlyWriteSaysThePublishedRowIsUnchanged(t *testing.T) {
	for _, shape := range []string{"minimal", "table", "json", "yaml"} {
		t.Run(shape, func(t *testing.T) {
			fake := &fakeMutateAPI{mutateBody: draftOnlyMutateBody, published: unchangedPublished}
			srv := httptest.NewServer(fake.handler())
			defer srv.Close()

			// 1. The published row BEFORE the write.
			before, _, code := runAgainst(t, srv.URL, "json", docGetCommand())
			if code != exitOK {
				t.Fatalf("pre-read exit = %d, want 0", code)
			}

			// 2. The mutate.
			stdout, stderr, code := runAgainst(t, srv.URL, shape, mutateCommand())
			if code != exitOK {
				t.Fatalf("mutate exit = %d, want 0; stdout=%q stderr=%q", code, stdout, stderr)
			}
			if !strings.Contains(stderr, "DRAFT updated (drafts.p1)") {
				t.Fatalf("the receipt never said the write went to a DRAFT.\nstdout=%q stderr=%q", stdout, stderr)
			}
			if !strings.Contains(stderr, "published row is UNCHANGED") {
				t.Fatalf("the receipt never said the published row is unchanged.\nstderr=%q", stderr)
			}
			// The remedy is the exact command, not a gesture at one.
			if !strings.Contains(stderr, "bp doc publish post p1") {
				t.Fatalf("the receipt named no publish remedy.\nstderr=%q", stderr)
			}
			// The fork fact from #15851 rides the same receipt.
			if !strings.Contains(stderr, "FORKED the published row") {
				t.Fatalf("the fork advisory (#15851 patch.forked_published) was not rendered.\nstderr=%q", stderr)
			}

			// 3. The published row AFTER the write — byte-identical.
			after, _, code := runAgainst(t, srv.URL, "json", docGetCommand())
			if code != exitOK {
				t.Fatalf("post-read exit = %d, want 0", code)
			}
			if before != after {
				t.Fatalf("the published read MOVED across a draft-only mutate:\nbefore=%q\nafter=%q", before, after)
			}
			if !strings.Contains(after, `"OLD"`) {
				t.Fatalf("the published row does not still carry the pre-mutate title: %q", after)
			}

			// The verdict cost NO extra request: exactly the two reads this
			// test made itself, and one POST.
			if fake.publishedReads != 2 || fake.mutatePosts != 1 {
				t.Fatalf("request count moved — the emitter did a read-after-write: reads=%d posts=%d",
					fake.publishedReads, fake.mutatePosts)
			}
		})
	}
}

// TestMutatePublishedChangePrintsTheOtherWording is the CONTROL c1 demands. A
// guard that shouted "DRAFT updated" on every mutate would pass the test above
// while saying nothing; this proves the emitter DISCRIMINATES.
func TestMutatePublishedChangePrintsTheOtherWording(t *testing.T) {
	fake := &fakeMutateAPI{mutateBody: publishedChangedMutateBody, published: unchangedPublished}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	stdout, stderr, code := runAgainst(t, srv.URL, "minimal", mutateCommand())
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "published document changed: p1") {
		t.Fatalf("a published-row change did not say so.\nstdout=%q stderr=%q", stdout, stderr)
	}
	if strings.Contains(stderr, "DRAFT updated") || strings.Contains(stderr, "UNCHANGED") {
		t.Fatalf("a published-row change was reported as a draft write.\nstderr=%q", stderr)
	}
}

// TestMutatePerspectiveKeepsJSONByteIdentical: `-o json` is the machine
// contract. The facts are ALREADY in the envelope (results[].document._draft,
// warnings[]), so stdout must stay ONE document — the advisory is stderr-only.
func TestMutatePerspectiveKeepsJSONByteIdentical(t *testing.T) {
	fake := &fakeMutateAPI{mutateBody: draftOnlyMutateBody, published: unchangedPublished}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	stdout, stderr, code := runAgainst(t, srv.URL, "json", mutateCommand())
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("stdout is not one JSON document — the advisory leaked onto stdout:\n%s", stdout)
	}
	var want map[string]any
	if err := json.Unmarshal([]byte(draftOnlyMutateBody), &want); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	gotB, _ := json.Marshal(got)
	wantB, _ := json.Marshal(want)
	if string(gotB) != string(wantB) {
		t.Fatalf("the -o json body drifted from the server envelope:\n got %s\nwant %s", gotB, wantB)
	}
	if !strings.Contains(stderr, "DRAFT updated") {
		t.Fatalf("json shape lost the advisory entirely (it belongs on stderr): %q", stderr)
	}
}

// TestMutatePerspectiveSilentWhereItMustBe pins the emitter's blast radius: it
// is verb-keyed to doc mutate/patch, and it never asserts a lens the envelope
// did not declare. A body without `_draft` is UNKNOWN, not "published".
func TestMutatePerspectiveSilentWhereItMustBe(t *testing.T) {
	cases := []struct {
		name string
		cmd  manifest.Command
		body string
	}{
		{"another_write_verb", writeReceiptCommand(), draftOnlyMutateBody},
		{"no_draft_key", mutateCommand(), `{"transactionId":"t","results":[{"id":"p1","operation":"update","document":{"_id":"p1","_type":"post"}}]}`},
		{"no_results", mutateCommand(), `{"transactionId":"t","results":[]}`},
		{"unrecognised_receipt", mutateCommand(), `{"ok":true,"frobnicated":3}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeMutateAPI{mutateBody: tc.body, published: unchangedPublished}
			srv := httptest.NewServer(fake.handler())
			defer srv.Close()
			_, stderr, code := runAgainst(t, srv.URL, "minimal", tc.cmd)
			if code != exitOK {
				t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
			}
			if strings.Contains(stderr, "DRAFT updated") || strings.Contains(stderr, "published document changed") {
				t.Fatalf("the emitter spoke where it must be silent: %q", stderr)
			}
		})
	}
}

// TestMutateStaleDraftBaseIsNamed covers #15851's OTHER code — the dangerous
// half, where the merge base was an EXISTING draft rather than the published
// row the caller read.
func TestMutateStaleDraftBaseIsNamed(t *testing.T) {
	body := strings.Replace(draftOnlyMutateBody, "patch.forked_published", "patch.stale_draft_base", 1)
	fake := &fakeMutateAPI{mutateBody: body, published: unchangedPublished}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, stderr, code := runAgainst(t, srv.URL, "minimal", mutateCommand())
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "FORKED onto an EXISTING draft") {
		t.Fatalf("patch.stale_draft_base was not named: %q", stderr)
	}
	if !strings.Contains(stderr, "lifecycle_status") {
		t.Fatalf("the stale-base line does not name the field that actually rots: %q", stderr)
	}
}

// ---------------------------------------------------------------------------
// #17 — THE CREATE FAMILY (task-7f06080cfd584194).
//
// RED WITHOUT the fix — measured by reverting mutatePerspectiveVerbs to the
// two-entry map (`doc mutate`, `doc patch`) and re-running:
//
//	--- FAIL: TestDocCreateSaysItMadeADraft/doc_create
//	    `bp doc create` said nothing about a draft. stdout="rev: tx-90\n" stderr=""
//	--- FAIL: TestDocCreateSaysItMadeADraft/doc_create-or-replace
//	    stdout="rev: tx-91\n" stderr=""
//	--- FAIL: TestDocCreateSaysItMadeADraft/doc_create-if-not-exists
//
// That is #17 exactly: a create returned a fresh transaction rev — the universal
// "it worked" signal — for a document no published reader can see. Gyldendal's
// imported tasks were invisible until publication and the receipt never said
// why.

// createDraftMutateBody is what the server answers a `doc create` with today:
// the new row is the `drafts.` twin, and results[].operation names the op.
func createDraftMutateBody(tx, op, id string) string {
	return `{
  "transactionId": "` + tx + `",
  "results": [
    {"id": "drafts.` + id + `", "operation": "` + op + `",
     "document": {"_id":"drafts.` + id + `","_type":"task","_rev":"r1","_draft":true,"_publishedId":"` + id + `","title":"Imported"}}
  ]
}`
}

func docWriteCommand(id, verb, op string) manifest.Command {
	return manifest.Command{
		ID:            id,
		Noun:          "doc",
		Verb:          verb,
		HTTP:          manifest.HTTP{Method: http.MethodPost, PathTemplate: "/v1/data/mutate/production"},
		Writes:        true,
		MutationOp:    op,
		DefaultOutput: "minimal",
	}
}

// TestDocCreateSaysItMadeADraft is criterion c1's create half: `create` must SAY
// it made a draft and give the EXACT publish command. It drives the real
// runCommand against httptest for all three create-family verbs and all four
// output shapes.
func TestDocCreateSaysItMadeADraft(t *testing.T) {
	cases := []struct {
		name string
		cmd  manifest.Command
		op   string
		verb string // the word the receipt must open with
	}{
		{"doc create", docWriteCommand("doc.create", "create", "create"), "create", "DRAFT created"},
		{"doc create-or-replace", docWriteCommand("doc.create-or-replace", "create-or-replace", "createOrReplace"), "createOrReplace", "DRAFT created"},
		{"doc create-if-not-exists", docWriteCommand("doc.create-if-not-exists", "create-if-not-exists", "createIfNotExists"), "create", "DRAFT created"},
	}
	for _, tc := range cases {
		for _, shape := range []string{"minimal", "table", "json", "yaml"} {
			t.Run(tc.name+"/"+shape, func(t *testing.T) {
				fake := &fakeMutateAPI{
					mutateBody: createDraftMutateBody("tx-90", tc.op, "t1"),
					published:  unchangedPublished,
				}
				srv := httptest.NewServer(fake.handler())
				defer srv.Close()

				stdout, stderr, code := runAgainst(t, srv.URL, shape, tc.cmd)
				if code != exitOK {
					t.Fatalf("exit = %d, want 0; stdout=%q stderr=%q", code, stdout, stderr)
				}
				if !strings.Contains(stderr, tc.verb+" (drafts.t1)") {
					t.Fatalf("`bp %s` said nothing about a draft. stdout=%q stderr=%q",
						tc.name, stdout, stderr)
				}
				if !strings.Contains(stderr, "bp doc publish task t1") {
					t.Fatalf("the create receipt named no publish remedy. stderr=%q", stderr)
				}
				if !strings.Contains(stderr, "published row is UNCHANGED") {
					t.Fatalf("the create receipt never said the published row is unchanged. stderr=%q", stderr)
				}
			})
		}
	}
}

// TestDocCreateReceiptSaysCREATEDNotUPDATED is the wording discrimination c1
// demands. "DRAFT updated" on a fresh create would be a receipt describing a
// document the caller has never seen — it would pass a loose contains-"DRAFT"
// assertion while still misdescribing the write.
func TestDocCreateReceiptSaysCREATEDNotUPDATED(t *testing.T) {
	fake := &fakeMutateAPI{mutateBody: createDraftMutateBody("tx-92", "create", "t2"), published: unchangedPublished}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, stderr, _ := runAgainst(t, srv.URL, "minimal", docWriteCommand("doc.create", "create", "create"))
	if strings.Contains(stderr, "DRAFT updated") {
		t.Fatalf("a create was reported as an UPDATE. stderr=%q", stderr)
	}
	if !strings.Contains(stderr, "DRAFT created") {
		t.Fatalf("a create was not reported as a create. stderr=%q", stderr)
	}

	// And the mirror: a patch must still say "updated", not "created".
	fake2 := &fakeMutateAPI{mutateBody: draftOnlyMutateBody, published: unchangedPublished}
	srv2 := httptest.NewServer(fake2.handler())
	defer srv2.Close()
	_, stderr2, _ := runAgainst(t, srv2.URL, "minimal", mutateCommand())
	if !strings.Contains(stderr2, "DRAFT updated") {
		t.Fatalf("a patch stopped saying `updated`. stderr=%q", stderr2)
	}
}

// TestCreateIfNotExistsNoopSaysNothingChanged: the server answers a
// createIfNotExists against an existing id with operation "noop". A receipt that
// claimed a write there would be a second, quieter lie.
func TestCreateIfNotExistsNoopSaysNothingChanged(t *testing.T) {
	fake := &fakeMutateAPI{mutateBody: createDraftMutateBody("tx-93", "noop", "t3"), published: unchangedPublished}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, stderr, _ := runAgainst(t, srv.URL, "minimal",
		docWriteCommand("doc.create-if-not-exists", "create-if-not-exists", "createIfNotExists"))
	if !strings.Contains(stderr, "left unchanged") {
		t.Fatalf("a no-op createIfNotExists was not reported as a no-op. stderr=%q", stderr)
	}
	if strings.Contains(stderr, "DRAFT created") {
		t.Fatalf("a no-op was reported as a create. stderr=%q", stderr)
	}
}

// TestPublishVerbGetsNoDraftVerdict is the NEGATIVE arm (criterion c3): the
// draft model is untouched, and the verbs that MOVE the published lens keep
// their receipt exactly as it was.
func TestPublishVerbGetsNoDraftVerdict(t *testing.T) {
	for _, verb := range []string{"publish", "unpublish", "discard-draft", "delete"} {
		t.Run(verb, func(t *testing.T) {
			fake := &fakeMutateAPI{mutateBody: createDraftMutateBody("tx-94", "create", "t4"), published: unchangedPublished}
			srv := httptest.NewServer(fake.handler())
			defer srv.Close()
			_, stderr, _ := runAgainst(t, srv.URL, "minimal", docWriteCommand("doc."+verb, verb, verb))
			if strings.Contains(stderr, "DRAFT") {
				t.Fatalf("`bp doc %s` printed a draft verdict; those verbs are not the trap. stderr=%q",
					verb, stderr)
			}
		})
	}
}

// TestTaskAcceptanceCriteriaPatchReceiptIsSelfEvidencing is criterion c5: our
// OWN trapped flow, the one memory `bp-task-write-contract` records — a
// `bp doc patch task <id> --set acceptance_criteria:=[…]` whose printed rev is
// NOT persistence, and whose working recipe was "read the criteria back from
// .doc.content.* to confirm they landed". The receipt must now carry that fact
// itself, so the read-back is no longer the only way to know.
func TestTaskAcceptanceCriteriaPatchReceiptIsSelfEvidencing(t *testing.T) {
	const body = `{
  "transactionId": "tx-95",
  "results": [
    {"id": "drafts.task-7f06080cfd584194", "operation": "update",
     "document": {"_id":"drafts.task-7f06080cfd584194","_type":"task","_rev":"r9","_draft":true,
                  "_publishedId":"task-7f06080cfd584194","title":"S6"}}
  ],
  "warnings": [
    {"code":"patch.forked_published","severity":"warning",
     "message":"this patch names a published document but writes a DRAFT twin."}
  ]
}`
	fake := &fakeMutateAPI{mutateBody: body, published: unchangedPublished}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	patchCmd := docWriteCommand("doc.patch", "patch", "patch")
	stdout, stderr, code := runAgainst(t, srv.URL, "minimal", patchCmd)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	for _, want := range []string{
		"DRAFT updated (drafts.task-7f06080cfd584194)",
		"published row is UNCHANGED",
		"bp doc publish task task-7f06080cfd584194",
		"FORKED the published row",
	} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("the acceptance-criteria patch receipt is missing %q.\nstdout=%q\nstderr=%q",
				want, stdout, stderr)
		}
	}
	t.Logf("c5 receipt:\nstdout=%s\nstderr=%s", stdout, stderr)
}
