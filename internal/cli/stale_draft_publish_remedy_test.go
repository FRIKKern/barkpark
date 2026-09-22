package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// publishRemedyManifestJSON is the one-verb slice of the LIVE manifest this
// advisory needs, copied field-for-field from what the api declares
// (Barkpark.Plugins.Capabilities: doc.publish — note its second arg is named
// `id`, the same as doc.patch's). The real scoped_prefix is carried, so the URL
// the fake server sees is the URL the CLI sends.
const publishRemedyManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "doc", "summary": "Documents."}],
  "commands": [
    {"id":"doc.publish","noun":"doc","verb":"publish","summary":"Publish a document's draft.",
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

// thePublishRefusedRow is the disposable row the trap was re-measured on,
// guerrilla, 2026-09-18 (created, claimed, forked and cancelled by
// cli-r21f-w10). Its refusal bodies below are that server's, not invented.
const thePublishRefusedRow = "task-967347fae9367384"

// theStaleDraftRefusalBody is the refusal `bp doc publish task <id> --yes -o json`
// answered with, VERBATIM from the live run — including the remedy clause this
// advisory exists to correct.
const theStaleDraftRefusalBody = `{"error":{"code":"validation_failed",` +
	`"details":{"claim":["stale draft: the published row carries claim state (worker \"probe-w10-holder2\", epoch 1) ` +
	`this draft does not — publishing would obliterate it. Re-derive the draft from the published row ` +
	`(patch, then publish), or move the claim through the sanctioned verbs ` + "(`bp task claim` / `bp task release` / `bp task close`)." + `"]},` +
	`"hint":"Fix the listed validation errors to match the schema, then resubmit.",` +
	`"message":"task content failed validation","request_id":"GNZOW6HCc9cWMdkAAEaR"},"ok":false}`

// theFixedStaleDraftRefusalBody is the SAME wall answering with a remedy that
// works — the shape api/ will send once task-922e616cb9b99243 lands. It is the
// advisory's self-retirement control: the marker is still there, the broken
// clause is not, and nothing may be printed.
const theFixedStaleDraftRefusalBody = `{"error":{"code":"validation_failed",` +
	`"details":{"claim":["stale draft: the published row carries claim state (worker \"probe-w10-holder2\", epoch 1) ` +
	`this draft does not — publishing would obliterate it. Drop the twin with ` + "`bp doc discard-draft`" + ` and edit the ` +
	`published row with a bare-id patch."]},` +
	`"hint":"Fix the listed validation errors to match the schema, then resubmit.",` +
	`"message":"task content failed validation","request_id":"REQ2"},"ok":false}`

// theUnrelatedRefusalBody is a different validation_failed on the same route —
// the published-first fork fence, which keys on `_id`, not `claim`.
const theUnrelatedRefusalBody = `{"error":{"code":"validation_failed",` +
	`"details":{"_id":["a draft twin ` + "`drafts." + thePublishRefusedRow + "`" + ` already exists for the published task."]},` +
	`"message":"task content failed validation","request_id":"REQ3"},"ok":false}`

// publishRemedyHarness stands up a fake instance and the parsed manifest
// pointed at it, and records every request the CLI sends — so a test can say
// the advisory cost NO extra round trip, not merely that it printed.
type publishRemedyHarness struct {
	t      *testing.T
	server *httptest.Server
	m      *manifest.Manifest
	ctx    manifest.Context
	seen   []string
	status int    // status the mutate route answers (0 -> 200)
	body   string // body it answers with (empty -> a successful publish receipt)
}

func newPublishRemedyHarness(t *testing.T) *publishRemedyHarness {
	t.Helper()
	h := &publishRemedyHarness{t: t}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		status := h.status
		if status == 0 {
			status = http.StatusOK
		}
		body := h.body
		if body == "" {
			body = `{"transactionId":"tx1","results":[{"id":"` + thePublishRefusedRow + `","operation":"update"}]}`
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(h.server.Close)

	parsed := strings.Replace(publishRemedyManifestJSON, "http://replaced", h.server.URL, 1)
	m, err := manifest.Parse([]byte(parsed))
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

// runPublish drives the real runCommand — the whole dispatched path, not the
// emitter in isolation — so an edit that moves or drops the call site in run.go
// reds these tests instead of passing on a bypassed helper.
func (h *publishRemedyHarness) runPublish(tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", "publish")
	if !ok {
		h.t.Fatal("fixture manifest has no doc publish")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true}
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

// THE LOUD ARM. The refusal an operator actually sees names `patch, then
// publish`, and that sequence is refused by the fork fence while the twin
// exists — measured both ways on one row on guerrilla 2026-09-18. The CLI must
// print the sequence that lands.
//
// REVERT-RED: drop the emitStaleDraftPublishRemedy call from run.go and the two
// remedy commands vanish from stderr, so every `want` below fires.
func TestTheStaleDraftPublishRefusalGetsARemedyThatWorks(t *testing.T) {
	h := newPublishRemedyHarness(t)
	h.status = http.StatusUnprocessableEntity
	h.body = theStaleDraftRefusalBody

	code, stdout, stderr := h.runPublish("task", thePublishRefusedRow)

	// PRECONDITION, asserted rather than assumed: the server's own refusal
	// reached stderr. Without this the arm below could pass on a run that never
	// rendered the refusal at all.
	if !strings.Contains(stderr, "stale draft") {
		t.Fatalf("precondition failed: the server refusal never rendered; stderr = %q", stderr)
	}
	if code == exitOK {
		t.Errorf("exit = %d (ok) — a refused publish must not report success", code)
	}

	// The advisory must carry BOTH commands of the working sequence, bare-id
	// (a `drafts.`-prefixed id in either would hand over a sequence that does
	// not run), and it must say plainly that the printed remedy is wrong.
	for _, want := range []string{
		"THE REMEDY IN THAT REFUSAL DOES NOT WORK",
		"bp doc discard-draft task " + thePublishRefusedRow,
		"bp doc patch task " + thePublishRefusedRow,
	} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr is missing %q\n--- stderr ---\n%s", want, stderr)
		}
	}
	if strings.Contains(stderr, "bp doc discard-draft task "+draftIDPrefix) ||
		strings.Contains(stderr, "bp doc patch task "+draftIDPrefix) {
		t.Errorf("the remedy names a drafts.-prefixed id — neither command takes one\n--- stderr ---\n%s", stderr)
	}

	// stdout is the machine surface: the advisory must never reach it.
	if stdout != "" {
		t.Errorf("stdout = %q — the advisory must be stderr-only so `-o json` stays byte-identical", stdout)
	}

	// It costs NO extra round trip: the whole decision is made from the body
	// the dispatch already held.
	if len(h.seen) != 1 {
		t.Errorf("requests seen = %v — the advisory must read the body it already has, not probe", h.seen)
	}
}

// THE QUIET ARM. Three cases in which the advisory must say NOTHING, and the
// first is the one that matters most: the SAME wall, refusing for the SAME
// reason, with a remedy that works. That is the shape api/ will send once
// task-922e616cb9b99243 lands, and this advisory has to retire itself then —
// keyed on the broken phrase, not on the refusal.
//
// Without this arm the loud arm above is satisfiable by an emitter that fires
// on every stale-draft refusal, which would leave two contradictory remedies
// side by side forever.
func TestTheRemedyAdvisoryIsSilentWhenItShouldBe(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"the wall already prints a remedy that works", http.StatusUnprocessableEntity, theFixedStaleDraftRefusalBody},
		{"a different refusal on the same route", http.StatusUnprocessableEntity, theUnrelatedRefusalBody},
		{"a publish that succeeds", 0, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newPublishRemedyHarness(t)
			h.status = tc.status
			h.body = tc.body

			_, _, stderr := h.runPublish("task", thePublishRefusedRow)

			// Forbidden strings are the ADVISORY's own, never a substring the
			// server might legitimately print: the post-fix wall names
			// `bp doc discard-draft` itself, so matching that bare phrase would
			// red on the server's correct sentence rather than on this emitter.
			// The id-bearing command form is what only this file emits.
			for _, forbidden := range []string{
				"THE REMEDY IN THAT REFUSAL DOES NOT WORK",
				"bp doc discard-draft task " + thePublishRefusedRow,
				"bp doc patch task " + thePublishRefusedRow,
			} {
				if strings.Contains(stderr, forbidden) {
					t.Errorf("the advisory fired on %s (found %q)\n--- stderr ---\n%s", tc.name, forbidden, stderr)
				}
			}
		})
	}
}

// The control the quiet arm needs to not be vacuous: prove the first quiet case
// really is the stale-draft wall answering, and differs from the loud fixture in
// exactly ONE respect — the remedy clause. Without this, "silent" could mean the
// fixture was malformed and never parsed as a refusal at all.
func TestTheFixedRefusalFixtureDiffersOnlyInItsRemedy(t *testing.T) {
	if !strings.Contains(theFixedStaleDraftRefusalBody, staleDraftClaimMarker) {
		t.Fatalf("the FIXED fixture is not the stale-draft wall at all — the quiet arm proves nothing")
	}
	if strings.Contains(theFixedStaleDraftRefusalBody, staleDraftBrokenRemedy) {
		t.Fatalf("the FIXED fixture still carries the broken remedy — it is not the post-fix shape")
	}
	if !strings.Contains(theStaleDraftRefusalBody, staleDraftClaimMarker) ||
		!strings.Contains(theStaleDraftRefusalBody, staleDraftBrokenRemedy) {
		t.Fatalf("the LIVE fixture no longer carries both clauses — re-measure before trusting the loud arm")
	}
	// And the predicate itself splits them, so the two arms above are reading a
	// real discrimination rather than an accident of rendering.
	if !staleDraftPublishRefused([]byte(theStaleDraftRefusalBody)) {
		t.Error("staleDraftPublishRefused said NO to the live refusal body")
	}
	if staleDraftPublishRefused([]byte(theFixedStaleDraftRefusalBody)) {
		t.Error("staleDraftPublishRefused said YES to a refusal whose remedy works")
	}
	if staleDraftPublishRefused([]byte(theUnrelatedRefusalBody)) {
		t.Error("staleDraftPublishRefused said YES to a refusal with no claim detail")
	}
	if staleDraftPublishRefused([]byte("not json at all")) {
		t.Error("staleDraftPublishRefused said YES to an undecodable body — silence must mean 'not established'")
	}
}
