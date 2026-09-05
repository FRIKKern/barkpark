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
