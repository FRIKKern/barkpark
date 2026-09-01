package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// discardManifestJSON is the two-verb slice of the LIVE manifest this guard
// needs, copied field-for-field from what guerrilla.barkpark.cloud serves at
// GET /v1/capabilities (doc.get / doc.discard-draft). Both carry the real
// scoped_prefix, so the URLs the fake server sees are the URLs the CLI sends.
const discardManifestJSON = `{
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
    {"id":"doc.discard-draft","noun":"doc","verb":"discard-draft","summary":"Discard a document's draft edits (keep the published version).",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"id","required":true,"type":"string","summary":"Document id."}],
     "flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"discardDraft"}
  ]
}`

// discardHarness stands up a fake instance and the parsed manifest pointed at
// it, and records every request path+method the CLI actually sends — the only
// way to prove the mutate was WITHHELD rather than merely unrendered.
type discardHarness struct {
	t          *testing.T
	server     *httptest.Server
	m          *manifest.Manifest
	ctx        manifest.Context
	seen       []string
	twinStatus int // status the published-twin GET answers (0 -> 200)
}

// theDraftOnlyRow is the shape that cost a real backlog row: a task document
// created, refused by the publish wall's duplicate_of guard, and therefore
// draft-only ever since. Its bare (published) id resolves to NOTHING.
const theDraftOnlyRow = "dr-w18-bl-boundary-continuity-gauge"

func newDiscardHarness(t *testing.T) *discardHarness {
	t.Helper()
	h := &discardHarness{t: t}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/"):
			status := h.twinStatus
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			if status == http.StatusOK {
				_, _ = w.Write([]byte(`{"result":{"_id":"` + theDraftOnlyRow + `","_type":"task","_rev":"r1"}}`))
				return
			}
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no such document"}}`))
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"transactionId":"tx1","results":[{"id":"drafts.` + theDraftOnlyRow + `","operation":"discardDraft"}]}`))
		}
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(discardManifestJSON, "http://replaced", h.server.URL, 1)
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

func (h *discardHarness) sent(want string) bool {
	for _, got := range h.seen {
		if got == want {
			return true
		}
	}
	return false
}

// Both routes are FLAT. manifest.BuildURL composes scoped_prefix only for the
// scoped_admin / scoped_read tiers (or under a full ScopedMirror); doc.get is
// tier `none` and doc.discard-draft is tier `write`, so the prefix stays a
// future mirror hint and the live routes are the bare ones — which is exactly
// what makes the guard's probe land on the same route the operator's own
// `bp doc get` would.
const (
	discardMutatePath = "/v1/data/mutate/production"
	discardTwinPath   = "/v1/data/doc/production/task/" + theDraftOnlyRow
)

// runDiscardWith drives the real runCommand — the whole guarded path, not the
// guard in isolation — so a future edit that moves or drops the gate call site
// reds these tests instead of passing on a bypassed helper.
func (h *discardHarness) runDiscardWith(g globals, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", "discard-draft")
	if !ok {
		h.t.Fatal("fixture manifest has no doc discard-draft")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

func (h *discardHarness) runDiscard(tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	return h.runDiscardWith(globals{}, tail...)
}

// THE DEFECT (dr-w23-bl). `bp doc discard-draft <type> <id>` on a document that
// has NEVER been published is a DESTRUCTIVE DELETE, not a revert: the server's
// Content.Lifecycle.do_discard_draft deletes the draft row unconditionally and
// there is no published row to fall back to, so the whole document disappears
// and `bp doc get` answers not_found. It happened to a real backlog row with a
// full description and four acceptance criteria. Nothing warned.
func TestDiscardDraftOnDraftOnlyDocumentSendsNoMutation(t *testing.T) {
	h := newDiscardHarness(t)
	h.twinStatus = http.StatusNotFound

	code, _, stderr := h.runDiscard("task", theDraftOnlyRow)

	if code == exitOK {
		t.Errorf("exit = %d (ok) — discarding a never-published document must not succeed silently", code)
	}
	if h.sent("POST " + discardMutatePath) {
		t.Error("the discardDraft mutation was sent on a draft-only document — the guard did not hold")
	}
	if !h.sent("GET " + discardTwinPath) {
		t.Errorf("the guard never probed for the published twin; requests seen: %v", h.seen)
	}
	for _, want := range []string{theDraftOnlyRow, "restore-revision", "--delete-unpublished"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("refusal omits %q — it must name the row and the way out:\n%s", want, stderr)
		}
	}
}

// The escape hatch has to exist, and it has to be EXPLICIT — never the global
// --yes, which every script answers reflexively and which the prod write-guard
// already consumes for a different question.
func TestDiscardDraftDeleteFlagProceedsAndSaysItIsADelete(t *testing.T) {
	h := newDiscardHarness(t)
	h.twinStatus = http.StatusNotFound

	code, _, stderr := h.runDiscard("task", theDraftOnlyRow, "--delete-unpublished")

	if code != exitOK {
		t.Errorf("exit = %d — the explicit destructive flag must let the delete through, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + discardMutatePath) {
		t.Errorf("the mutation was withheld even under --delete-unpublished; requests seen: %v", h.seen)
	}
	if !strings.Contains(stderr, "DELETES") {
		t.Errorf("the flagged path never says out loud that this is a delete:\n%s", stderr)
	}
}

// The global --yes must NOT be the key to this door. It is the prod
// write-guard's answer, it is set in every CI script, and reading it here would
// re-open the footgun for exactly the callers most likely to hit it.
func TestDiscardDraftGlobalYesDoesNotUnlockTheDelete(t *testing.T) {
	h := newDiscardHarness(t)
	h.twinStatus = http.StatusNotFound

	code, _, _ := h.runDiscardWith(globals{yes: true}, "task", theDraftOnlyRow)

	if code == exitOK {
		t.Errorf("exit = %d (ok) — --yes must not stand in for --delete-unpublished", code)
	}
	if h.sent("POST " + discardMutatePath) {
		t.Error("--yes let the destructive discard through; the guard is keyed on the wrong flag")
	}
}

// The ORDINARY case must be untouched: a draft whose published twin exists is a
// real revert, and it keeps working with no prompt, no flag and no new noise.
func TestDiscardDraftWithPublishedTwinIsUnchanged(t *testing.T) {
	h := newDiscardHarness(t)
	h.twinStatus = http.StatusOK

	code, _, stderr := h.runDiscard("task", theDraftOnlyRow)

	if code != exitOK {
		t.Errorf("exit = %d — a genuine revert must not be gated, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + discardMutatePath) {
		t.Errorf("a genuine revert was withheld; requests seen: %v", h.seen)
	}
	if strings.Contains(stderr, "--delete-unpublished") {
		t.Errorf("a genuine revert was told about the destructive flag:\n%s", stderr)
	}
}

// A probe that DID NOT LAND is not a report that the twin is absent, and it is
// not a report that it is present either. It must refuse — the destructive
// reading is the one that loses data — and it must never phrase the refusal as
// "has no published version", which would assert a fact nobody measured. This
// mirrors the TUI's discardTwinStatusMessage, which has drawn exactly this line
// since armDiscard was written.
func TestDiscardDraftRefusesWhenTheTwinProbeDidNotLand(t *testing.T) {
	h := newDiscardHarness(t)
	h.twinStatus = http.StatusInternalServerError

	code, _, stderr := h.runDiscard("task", theDraftOnlyRow)

	if code == exitOK {
		t.Errorf("exit = %d (ok) — an unchecked twin must not authorise a destructive discard", code)
	}
	if h.sent("POST " + discardMutatePath) {
		t.Error("the mutation was sent although the twin probe failed — the guard fails OPEN")
	}
	if strings.Contains(stderr, "has no published version") {
		t.Errorf("a failed probe was reported as a measured absence:\n%s", stderr)
	}
	if !strings.Contains(stderr, "500") {
		t.Errorf("the refusal never names WHICH failure stopped the probe:\n%s", stderr)
	}
}

// A `drafts.`-prefixed id is what a board render hands an operator, and the
// server normalises it (Content.discard_draft's bare-id contract). The probe
// must normalise it too — probing `drafts.<id>` would find the DRAFT, read that
// as "the published twin exists", and wave the delete straight through. That is
// the guard going vacuous while still looking green.
func TestDiscardDraftNormalisesADraftsPrefixedIDBeforeProbing(t *testing.T) {
	h := newDiscardHarness(t)
	h.twinStatus = http.StatusNotFound

	code, _, _ := h.runDiscard("task", "drafts."+theDraftOnlyRow)

	if !h.sent("GET " + discardTwinPath) {
		t.Errorf("the probe did not strip the drafts. prefix, so it asked about the wrong row; requests seen: %v", h.seen)
	}
	if code == exitOK || h.sent("POST "+discardMutatePath) {
		t.Error("a drafts.-spelled draft-only id walked past the guard")
	}
}
