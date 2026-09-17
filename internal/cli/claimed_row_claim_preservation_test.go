package cli

// claimed_row_claim_preservation_test.go closes the LAST half of the claim
// contract on task-bff844cc812f0fe4: "NO CLAIM IS OBLITERATED BY THE FIX …
// a test asserts that enriching a claimed row leaves its claim byte-identical."
//
// WHY THIS IS NOT THE TEST NEXT DOOR. TestTheEnrichmentPathNeverPutsTheClaimOnTheWire
// asserts a property of the REQUEST: the bare-id patch the guard prescribes
// carries no `claim` key. That is the right assertion about the wire and it is
// not the criterion. The criterion is about the DOCUMENT afterwards — a request
// with no claim key still obliterates the claim if the write that consumes it
// REPLACES content instead of merging into it, and nothing in a request-shaped
// test can tell those two servers apart. So this file's fake instance is
// STATEFUL: it stores the row, applies the mutation the CLI actually sends with
// the published-first patch's own shallow-merge semantics
// (api/lib/barkpark/content/mutations.ex `land_patch/5`: `set` merges into the
// published content, `unset` drops keys), and the assertions read the stored
// document back.
//
// WHAT IT CAN AND CANNOT PROVE. It cannot prove the live server merges rather
// than replaces — that is guerrilla's property, re-measured below, not Go's.
// What it does prove, and what no request-shaped arm can, is that the CLIENT's
// mutation is claim-preserving under merge semantics AND that this harness can
// SEE an obliteration when one happens: the second arm feeds the same applying
// server a claim-bearing mutation and requires the claim bytes to CHANGE. An
// arm that could not fail would make the first arm's silence worth nothing.
//
// LIVE RE-MEASUREMENT, guerrilla 2026-09-17, on a scratch row this worker
// created and cancelled (task-c2411909ff7fc83b, claimed by
// cli-r21-w23-holder, epoch 1):
//
//	bp task get task-c2411909ff7fc83b -o json | jq -Sc .doc.claim   > before
//	bp doc patch task task-c2411909ff7fc83b --set description=… --yes
//	  -> published document changed: task-c2411909ff7fc83b
//	     rev: fa54957f2e7a0bf76e0c5c92dcd5c9d1
//	bp task get task-c2411909ff7fc83b -o json | jq -Sc .doc.claim   > after
//	diff before after   # EMPTY
//
// EMPTY over the WHOLE block — worker, epoch, ts_iso, session, lease_expires_at
// and the work_field_digests map, `description` digest included, which is the
// sharpest form of the claim: the enrichment moved the description on the
// published row and did not move one byte of the lease that governs it. The
// readback showed the new description, so the identity is not the identity of
// a write that never landed.

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

// theClaimBlock is the claim state the stored row starts with — worker, epoch
// AND the timestamp, because "preserves the claim" means the whole block, not
// the two fields the guard happens to print.
const theClaimBlock = `{"worker":"cli-r20-w19","epoch":1,"ts_iso":"2026-09-16T09:24:53.504043Z"}`

// applyingHarness is a fake instance that REMEMBERS. Unlike
// claimedPatchHarness, whose mutate arm answers a canned receipt, this one
// applies what it is sent, so a test can read the document back and assert on
// what survived.
type applyingHarness struct {
	t       *testing.T
	server  *httptest.Server
	m       *manifest.Manifest
	ctx     manifest.Context
	content map[string]any
	applied int
}

func newApplyingHarness(t *testing.T) *applyingHarness {
	t.Helper()
	h := &applyingHarness{t: t}
	if err := json.Unmarshal([]byte(`{
		"_id": "`+theClaimedRow+`", "_type": "task", "_draft": false, "_rev": "r1",
		"title": "PROBE", "description": "before", "lifecycle_status": "open",
		"claim": `+theClaimBlock+`}`), &h.content); err != nil {
		t.Fatalf("seed content: %v", err)
	}

	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/") {
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{"result": h.content})
			return
		}
		raw, _ := io.ReadAll(r.Body)
		h.apply(raw)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"transactionId":"tx1","results":[{"id":"` + theClaimedRow + `","operation":"update"}]}`))
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(claimedPatchManifestJSON, "http://replaced", h.server.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	h.ctx = manifest.Context{
		Server: h.server.URL, Token: "tok",
		Workspace: "acme", Project: "site", Dataset: "production",
		WorkspaceExplicit: true, ProjectExplicit: true,
	}
	return h
}

// apply is the published-first patch's merge semantics, and ONLY those: `set`
// merges key by key into the stored content and `unset` deletes keys. A key the
// mutation does not name is not touched — which is exactly the server property
// that makes a claim-free request claim-preserving, and exactly what makes the
// control arm below able to destroy it.
func (h *applyingHarness) apply(raw []byte) {
	var env struct {
		Mutations []map[string]json.RawMessage `json:"mutations"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		h.t.Fatalf("fake instance could not read the mutation body — the test is measuring nothing: %v\n%s", err, raw)
	}
	for _, mut := range env.Mutations {
		for _, payload := range mut {
			var op struct {
				Set   map[string]any `json:"set"`
				Unset []string       `json:"unset"`
			}
			if json.Unmarshal(payload, &op) != nil {
				continue
			}
			for k, v := range op.Set {
				h.content[k] = v
			}
			for _, k := range op.Unset {
				delete(h.content, k)
			}
			h.applied++
		}
	}
}

// claimBytes renders the stored claim block canonically (Go marshals map keys
// sorted), so "byte-identical" is a comparison of the SAME serialisation on
// both sides and not of two incidental orderings.
func (h *applyingHarness) claimBytes() string {
	h.t.Helper()
	b, err := json.Marshal(h.content["claim"])
	if err != nil {
		h.t.Fatalf("marshal stored claim: %v", err)
	}
	return string(b)
}

// canonicalJSON re-serialises a literal through the same marshaller
// claimBytes uses, so the precondition compares CONTENT and not the key order
// two hand-written spellings happen to have.
func canonicalJSON(t *testing.T, raw string) string {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		t.Fatalf("canonicalise %q: %v", raw, err)
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("canonicalise %q: %v", raw, err)
	}
	return string(b)
}

func (h *applyingHarness) field(key string) string {
	s, _ := h.content[key].(string)
	return s
}

func (h *applyingHarness) runPatch(tail ...string) (int, string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", "patch")
	if !ok {
		h.t.Fatal("fixture manifest has no doc patch")
	}
	var so, se bytes.Buffer
	g := globals{yes: true}
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	return runCommand(w, g, h.ctx, h.m, *cmd, tail), se.String()
}

// TestEnrichingAClaimedRowLeavesItsClaimByteIdentical is criterion 4 of
// task-bff844cc812f0fe4.
//
// REVERT-RED, both directions:
//   - make the CLI send the claim (arm 2 does exactly this, by argv) and the
//     stored claim bytes change — so the first arm's equality is falsifiable.
//   - neutralise BOTH claimed-draft gates in run.go (guardClaimedDraftPatch and
//     the broader guardClaimedDraftMutation — either one alone still holds the
//     line, which is itself worth knowing) and arm 3 sees an applied mutation
//     on the draft twin: "the guard let 1 mutation(s) through", description
//     "before" -> "evidence appended". Run 2026-09-17.
func TestEnrichingAClaimedRowLeavesItsClaimByteIdentical(t *testing.T) {
	t.Run("the prescribed bare-id enrichment leaves the claim byte-identical", func(t *testing.T) {
		h := newApplyingHarness(t)

		// PRECONDITION, asserted rather than assumed: a row with NO claim would
		// make "byte-identical" true for free. Print the block being protected.
		before := h.claimBytes()
		if want := canonicalJSON(t, theClaimBlock); before != want {
			t.Fatalf("precondition broken: the stored row does not carry the claim under test\n got: %s\nwant: %s", before, want)
		}

		code, stderr := h.runPatch("task", theClaimedRow, "--set", "description=evidence appended")
		if code != exitOK {
			t.Fatalf("exit = %d — the remedy the guard prescribes must itself run; stderr:\n%s", code, stderr)
		}

		// SECOND PRECONDITION: the enrichment LANDED. Byte-identity after a write
		// that did nothing is the identity of a no-op, which proves nothing.
		if h.applied == 0 {
			t.Fatal("the fake instance applied no mutation — this arm is measuring a write that never happened")
		}
		if got := h.field("description"); got != "evidence appended" {
			t.Fatalf("description = %q — the enrichment did not land, so the claim's survival is vacuous", got)
		}

		if after := h.claimBytes(); after != before {
			t.Errorf("the claim was not preserved by the enrichment\nbefore: %s\n after: %s", before, after)
		}
	})

	t.Run("control: a claim-bearing mutation DOES move the bytes", func(t *testing.T) {
		// This arm is not a statement about what `bp` does on its own — the live
		// server walls a claim reassignment through /v1/data/mutate outright
		// ("cannot be reassigned through /v1/data/mutate", measured 2026-09-16).
		// It is a statement about THIS HARNESS: if a claim ever did ride a patch,
		// the arm above would see it. Without this, an applying server that
		// silently dropped every `set` key would pass the first arm forever.
		h := newApplyingHarness(t)
		before := h.claimBytes()

		code, stderr := h.runPatch("task", theClaimedRow, "--set", `claim:={"worker":"thief","epoch":9}`)
		if code != exitOK {
			t.Fatalf("exit = %d — the control never reached the applying server; stderr:\n%s", code, stderr)
		}
		if after := h.claimBytes(); after == before {
			t.Fatalf("the control did not move the claim bytes (%s) — this harness cannot detect an obliteration, so the arm above is vacuous", after)
		}
	})

	t.Run("the refused draft-twin patch leaves the WHOLE document untouched", func(t *testing.T) {
		h := newApplyingHarness(t)
		before := h.claimBytes()
		beforeDesc := h.field("description")

		code, _ := h.runPatch("task", "drafts."+theClaimedRow, "--set", "description=evidence appended")

		if code == exitOK {
			t.Errorf("exit = %d (ok) — the unpublishable draft write must refuse", code)
		}
		if h.applied != 0 {
			t.Errorf("the guard let %d mutation(s) through to the applying server", h.applied)
		}
		if after := h.claimBytes(); after != before {
			t.Errorf("a REFUSAL moved the claim\nbefore: %s\n after: %s", before, after)
		}
		if got := h.field("description"); got != beforeDesc {
			t.Errorf("a REFUSAL moved the description: %q -> %q", beforeDesc, got)
		}
	})
}
