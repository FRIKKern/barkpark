package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// restoreManifestJSON is the three-verb slice of the LIVE manifest this guard
// needs, copied field-for-field from what the api declares
// (Barkpark.Plugins.Capabilities): doc.get (the claim probe's read),
// doc.revision (the rev_id -> doc_id hop, ONE positional, no `type`), and
// doc.restore-revision (the gated write, positionals `rev_id type` in that
// order). All three carry the real scoped_prefix, so the URLs the fake server
// sees are the URLs the CLI sends.
const restoreManifestJSON = `{
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
    {"id":"doc.revision","noun":"doc","verb":"revision","summary":"Fetch one revision by id, with its content.",
     "http":{"method":"GET","path_template":"/v1/data/revision/:dataset/:rev_id"},
     "auth_tier":"read",
     "args":[{"name":"rev_id","required":true,"type":"string","summary":"Revision id."}],
     "flags":[],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table","scoped_prefix":"/w/:workspace_slug/p/:project_slug"},
    {"id":"doc.restore-revision","noun":"doc","verb":"restore-revision","summary":"Restore a revision.",
     "http":{"method":"POST","path_template":"/v1/data/revision/:dataset/:rev_id/restore"},
     "auth_tier":"write",
     "args":[{"name":"rev_id","required":true,"type":"string","summary":"Revision id."},
             {"name":"type","required":true,"type":"string","summary":"Document type."}],
     "flags":[],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug"}
  ]
}`

// theRestoredRev / theRestoredRow are the shapes measured on guerrilla
// 2026-09-16 (task-fbc594aaf3b013d1): a revision of a published task row
// holding a live claim, whose restore answers `ok` and mints a twin that can
// never be published.
const (
	theRestoredRev = "5d6bace2-b0f5-4970-bc94-66b7699d6246"
	theRestoredRow = "task-d651ead531380b88"
	theHolder      = "w52-probe-holder"
)

// theRevisionBody is `bp doc revision <rev_id>` as the live endpoint renders it:
// the revision one level in, carrying the doc_id and the type. Copied from the
// live readback of theRestoredRev.
const theRevisionBody = `{"revision":{"id":"` + theRestoredRev + `","doc_id":"` + theRestoredRow + `",` +
	`"type":"task","rev":"3e4f2d2ffce9df0dbc97a102284850f0","status":"draft",` +
	`"title":"PROBE","content":{"kind":"task","lifecycle_status":"open"}}}`

// theRestoreClaimedBody / theRestoreFreeBody are the published row WITH and
// WITHOUT a claim block. The unclaimed shape omits the key entirely — that is
// what an unclaimed published task really looks like, not `"claim":null`.
const theRestoreClaimedBody = `{"result":{"_id":"` + theRestoredRow + `","_type":"task","_draft":false,"_rev":"r1",` +
	`"title":"PROBE","description":"…","lifecycle_status":"open",` +
	`"claim":{"worker":"` + theHolder + `","epoch":1,"ts_iso":"2026-09-16T21:12:01.657824Z"}}}`

const theRestoreFreeBody = `{"result":{"_id":"` + theRestoredRow + `","_type":"task","_draft":false,"_rev":"r1",` +
	`"title":"PROBE","description":"…","lifecycle_status":"open"}}`

// restoreHarness stands up a fake instance and the parsed manifest pointed at
// it, and records every request path+method the CLI actually sends — the only
// way to prove the restore was WITHHELD rather than merely unrendered. A string
// check on the output could not tell those apart: the defect under test is a
// write that SUCCEEDS and prints `ok`.
type restoreHarness struct {
	t      *testing.T
	server *httptest.Server
	m      *manifest.Manifest
	ctx    manifest.Context
	seen   []string

	revStatus int    // status the revision lookup answers (0 -> 200)
	revBody   string // body the revision lookup answers with (empty -> theRevisionBody)
	docStatus int    // status the published-row GET answers (0 -> 200)
	docBody   string // body the published-row GET answers with (empty -> claimed)
}

func newRestoreHarness(t *testing.T) *restoreHarness {
	t.Helper()
	h := &restoreHarness{t: t}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/revision/"):
			status := h.revStatus
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			body := h.revBody
			if body == "" {
				body = theRevisionBody
			}
			if status != http.StatusOK {
				body = `{"error":{"code":"not_found","message":"no such revision"}}`
			}
			_, _ = w.Write([]byte(body))
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/"):
			status := h.docStatus
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			body := h.docBody
			if body == "" {
				body = theRestoreClaimedBody
			}
			if status != http.StatusOK {
				body = `{"error":{"code":"not_found","message":"no such document"}}`
			}
			_, _ = w.Write([]byte(body))
		default:
			// The live restore's whole receipt: `ok`. That bare word IS the defect.
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true}`))
		}
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(restoreManifestJSON, "http://replaced", h.server.URL, 1)
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

// Every route carries the SCOPED PREFIX, the discard guard's rule: probe,
// resolve and mutation move together under the prefix or stay together without.
const (
	restoreScopePrefix = "/w/acme/p/site"
	restoreWritePath   = restoreScopePrefix + "/v1/data/revision/production/" + theRestoredRev + "/restore"
	restoreRevPath     = restoreScopePrefix + "/v1/data/revision/production/" + theRestoredRev
	restoreDocPath     = restoreScopePrefix + "/v1/data/doc/production/task/" + theRestoredRow
)

func (h *restoreHarness) sent(want string) bool {
	for _, got := range h.seen {
		if got == want {
			return true
		}
	}
	return false
}

// wrote reports whether ANY mutation request was issued — keyed on the METHOD,
// not on a path, so a guard that leaks a write to some other route still reds
// this. This is the recording fake the row demands: the refusal has to be
// proven to have happened BEFORE the write, and only the absence of a non-GET
// request proves that.
func (h *restoreHarness) wrote() bool {
	for _, got := range h.seen {
		if !strings.HasPrefix(got, http.MethodGet+" ") {
			return true
		}
	}
	return false
}

// runRestoreWith drives the real runCommand — the whole guarded path, not the
// guard in isolation — so a future edit that moves or drops the gate call site
// reds these tests instead of passing on a bypassed helper.
func (h *restoreHarness) runRestoreWith(g globals, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", "restore-revision")
	if !ok {
		h.t.Fatal("fixture manifest has no doc restore-revision")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

func (h *restoreHarness) runRestore(tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	return h.runRestoreWith(globals{}, tail...)
}

// THE DEFECT (task-fbc594aaf3b013d1), reproduced on guerrilla 2026-09-16:
// `bp doc restore-revision <rev_id> task` on a row whose published twin is
// CLAIMED answers a bare `ok` and mints a draft the publish wall refuses
// forever — and the same write forks the row, so the bare-id patch that DOES
// land is refused too. The write must not be sent.
//
// REVERT-RED: drop the guardClaimedRestoreRevision call from run.go and the
// POST is sent, so h.wrote() fires and the exit code is exitOK.
func TestRestoreRevisionOntoClaimedRowSendsNoMutation(t *testing.T) {
	h := newRestoreHarness(t)

	code, _, stderr := h.runRestore(theRestoredRev, "task")

	if code == exitOK {
		t.Errorf("exit = %d (ok) — a restore whose draft can never be published must not report success", code)
	}
	if h.wrote() {
		t.Errorf("a mutation was sent against a claimed row — the guard did not hold; requests seen: %v", h.seen)
	}
	if !h.sent("GET " + restoreRevPath) {
		t.Errorf("the guard never resolved the revision to its document; requests seen: %v", h.seen)
	}
	if !h.sent("GET " + restoreDocPath) {
		t.Errorf("the guard never probed the published row; requests seen: %v", h.seen)
	}
	// The refusal must carry: WHO holds it, and a path the operator can act on.
	// A refusal nobody can act on is a different bug.
	for _, want := range []string{
		theHolder,
		"epoch 1",
		"bp doc patch task " + theRestoredRow,
		"bp doc discard-draft task " + theRestoredRow,
		claimedRestoreRevisionFlag,
	} {
		if !strings.Contains(stderr, want) {
			t.Errorf("refusal is missing %q; got:\n%s", want, stderr)
		}
	}
}

// THE QUIET ARM, half one: an UNCLAIMED published row. Restoring a revision
// onto a row nobody holds is exactly what the verb is for, so the write goes
// through with no refusal and no extra sentence.
//
// REVERT-RED: make the guard unconditional (refuse whenever the command is a
// task restore) and this reds on both the exit code and h.wrote().
func TestRestoreRevisionOntoUnclaimedRowProceedsSilently(t *testing.T) {
	h := newRestoreHarness(t)
	h.docBody = theRestoreFreeBody

	code, _, stderr := h.runRestore(theRestoredRev, "task")

	if code != exitOK {
		t.Errorf("exit = %d — a restore onto an unclaimed row is legitimate and must not be refused (stderr: %s)", code, stderr)
	}
	if !h.sent("POST " + restoreWritePath) {
		t.Errorf("the restore was withheld on an UNCLAIMED row — the guard fired with no subject; requests seen: %v", h.seen)
	}
	if strings.TrimSpace(stderr) != "" {
		t.Errorf("an unclaimed restore must print no guard commentary; got:\n%s", stderr)
	}
}

// THE QUIET ARM, half two: a NON-TASK type spends nothing. The `type` is a
// positional of restore-revision, so the guard can filter on it with no network
// work at all — not the resolve hop, not the claim probe. This is the arm that
// proves the guard is not merely silent but ABSENT off its case.
//
// REVERT-RED: drop the `args["type"] != "task"` filter from
// claimedRestoreRevisionArgs and both probe assertions red.
func TestRestoreRevisionOnNonTaskTypeSpendsNoProbe(t *testing.T) {
	h := newRestoreHarness(t)

	code, _, stderr := h.runRestore(theRestoredRev, "page")

	if code != exitOK {
		t.Errorf("exit = %d — a non-task restore is not this guard's case (stderr: %s)", code, stderr)
	}
	if h.sent("GET " + restoreRevPath) {
		t.Errorf("the guard resolved a revision on a NON-TASK restore; requests seen: %v", h.seen)
	}
	for _, got := range h.seen {
		if strings.Contains(got, "/v1/data/doc/") {
			t.Errorf("the guard probed a published row on a NON-TASK restore; requests seen: %v", h.seen)
		}
	}
	if !h.wrote() {
		t.Errorf("the non-task restore was withheld; requests seen: %v", h.seen)
	}
}

// THE OPT-IN. --restore-onto-claimed lets the deliberate act through, and the
// preview guarantee still holds: it SAYS what the write will and will not do,
// having measured the claim first. The flag is command-local on purpose — the
// global --yes is the prod write-guard's answer and is set in every CI script,
// so it must not double as consent to park an unlandable draft.
func TestRestoreOntoClaimedFlagProceedsWithAPreview(t *testing.T) {
	h := newRestoreHarness(t)

	code, _, stderr := h.runRestore(theRestoredRev, "task", claimedRestoreRevisionFlag)

	if code != exitOK {
		t.Errorf("exit = %d — %s is the deliberate act and must be allowed (stderr: %s)", code, claimedRestoreRevisionFlag, stderr)
	}
	if !h.wrote() {
		t.Errorf("%s did not let the restore through; requests seen: %v", claimedRestoreRevisionFlag, h.seen)
	}
	for _, want := range []string{theHolder, "epoch 1", "discard-draft"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("the preview is missing %q; got:\n%s", want, stderr)
		}
	}
}

// --yes is NOT the escape hatch. This is the sentence the discard guard's flag
// exists for, asserted here so a future simplification that folds the opt-in
// into --yes reds instead of shipping.
func TestGlobalYesIsNotConsentToRestoreOntoAClaimedRow(t *testing.T) {
	h := newRestoreHarness(t)

	code, _, _ := h.runRestoreWith(globals{yes: true}, theRestoredRev, "task")

	if code == exitOK || h.wrote() {
		t.Errorf("--yes let an unlandable restore through (exit %d); requests seen: %v", code, h.seen)
	}
}

// UNKNOWN fails OPEN, at BOTH hops, and never collapses into "unclaimed": a
// guard that could not measure must not print a fact about a row it never read.
// The write proceeds (it destroys nothing) and the uncertainty gets its own
// sentence.
func TestRestoreRevisionUnknownFailsOpenWithItsOwnSentence(t *testing.T) {
	t.Run("the revision lookup fails", func(t *testing.T) {
		h := newRestoreHarness(t)
		h.revStatus = http.StatusInternalServerError

		code, _, stderr := h.runRestore(theRestoredRev, "task")

		if code != exitOK || !h.wrote() {
			t.Errorf("an unresolvable revision must fail OPEN (exit %d); requests seen: %v", code, h.seen)
		}
		if !strings.Contains(stderr, "could not check") {
			t.Errorf("the unknown must say it did not measure; got:\n%s", stderr)
		}
		if h.sent("GET " + restoreDocPath) {
			t.Errorf("the claim probe ran on an unresolved revision; requests seen: %v", h.seen)
		}
	})

	t.Run("the claim probe fails", func(t *testing.T) {
		h := newRestoreHarness(t)
		h.docStatus = http.StatusInternalServerError

		code, _, stderr := h.runRestore(theRestoredRev, "task")

		if code != exitOK || !h.wrote() {
			t.Errorf("an unreadable published row must fail OPEN (exit %d); requests seen: %v", code, h.seen)
		}
		if !strings.Contains(stderr, "could not check whether the published row task "+theRestoredRow+" is claimed") {
			t.Errorf("the unknown must name the row it could not read; got:\n%s", stderr)
		}
	})
}

// A revision taken from the DRAFT twin carries a `drafts.`-prefixed doc_id, and
// the claim question is always about the PUBLISHED row. The prefix must be
// stripped before the probe, or the guard asks about the twin — whose missing
// claim block is precisely the thing in question — and answers UNCLAIMED about
// a claimed row.
//
// REVERT-RED: drop the TrimPrefix in revisionDocID and the probe goes to
// …/task/drafts.task-… instead, so restoreDocPath is never hit.
func TestRestoreRevisionProbesThePublishedIDNotTheDraftTwin(t *testing.T) {
	h := newRestoreHarness(t)
	h.revBody = strings.Replace(theRevisionBody,
		`"doc_id":"`+theRestoredRow+`"`,
		`"doc_id":"drafts.`+theRestoredRow+`"`, 1)

	code, _, _ := h.runRestore(theRestoredRev, "task")

	if !h.sent("GET " + restoreDocPath) {
		t.Errorf("the guard probed something other than the bare published id; requests seen: %v", h.seen)
	}
	if code == exitOK || h.wrote() {
		t.Errorf("a draft-sourced revision on a claimed row must still be refused (exit %d); requests seen: %v", code, h.seen)
	}
}

// revisionDocID never guesses. A body it cannot read a doc_id out of answers
// ok=false, which the caller turns into UNKNOWN — the alternative (an empty id)
// would send the claim probe at a document that does not exist and read its 404
// as "unclaimed".
func TestRevisionDocIDRefusesToGuess(t *testing.T) {
	for name, body := range map[string]string{
		"not json":          `<html>502</html>`,
		"no revision key":   `{"ok":true}`,
		"revision null":     `{"revision":null}`,
		"doc_id missing":    `{"revision":{"id":"r","type":"task"}}`,
		"doc_id blank":      `{"revision":{"doc_id":"   ","type":"task"}}`,
		"doc_id bare draft": `{"revision":{"doc_id":"drafts.","type":"task"}}`,
	} {
		if id, ok := revisionDocID([]byte(body)); ok {
			t.Errorf("%s: revisionDocID answered %q — it must refuse a body it cannot read", name, id)
		}
	}

	// The control: the SHAPE the live endpoint really emits must parse, or the
	// refusals above would be "never parses anything" rather than a measurement.
	if id, ok := revisionDocID([]byte(theRevisionBody)); !ok || id != theRestoredRow {
		t.Errorf("the live revision shape did not parse: got %q, ok=%v", id, ok)
	}
	// And the `{"result":…}` envelope the transport also uses.
	if id, ok := revisionDocID([]byte(`{"ok":true,"result":` + theRevisionBody + `}`)); !ok || id != theRestoredRow {
		t.Errorf("the result-wrapped revision shape did not parse: got %q, ok=%v", id, ok)
	}
}

// The opt-in flag is stripped before splitArgs, never passed through to the
// server, and an inline `=` form is NOT quietly accepted — it falls through to
// the ordinary unknown-flag refusal so a typo fails loudly instead of silently
// disarming the guard.
func TestExtractClaimedRestoreRevisionFlag(t *testing.T) {
	got, kept := extractClaimedRestoreRevisionFlag([]string{"rev", "task", claimedRestoreRevisionFlag, "--yes"})
	if !got {
		t.Error("the bare flag was not detected")
	}
	if strings.Join(kept, " ") != "rev task --yes" {
		t.Errorf("the flag was not stripped from the tail: %v", kept)
	}

	got, kept = extractClaimedRestoreRevisionFlag([]string{"rev", "task", claimedRestoreRevisionFlag + "=1"})
	if got {
		t.Error("an inline `=` form must not count as the opt-in")
	}
	if len(kept) != 3 {
		t.Errorf("the inline form must survive into the tail for splitArgs to refuse: %v", kept)
	}
}
