package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// claimedPatchManifestJSON is the two-verb slice of the LIVE manifest this
// guard needs, copied field-for-field from what the api declares
// (Barkpark.Plugins.Capabilities: doc.get / doc.patch — note doc.patch's second
// arg is named `id`, not `doc_id`). Both carry the real scoped_prefix, so the
// URLs the fake server sees are the URLs the CLI sends.
const claimedPatchManifestJSON = `{
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
    {"id":"doc.patch","noun":"doc","verb":"patch","summary":"Patch a document.",
     "http":{"method":"POST","path_template":"/v1/data/mutate/:dataset"},
     "auth_tier":"write",
     "args":[{"name":"type","required":true,"type":"string","summary":"Document type."},
             {"name":"id","required":true,"type":"string","summary":"Document id."}],
     "flags":[{"name":"set","type":"string","repeatable":true,"summary":"Field key=value."}],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug",
     "mutation_op":"patch","set_key":"set"}
  ]
}`

// theClaimedRow is the shape measured on guerrilla 2026-09-16: a published
// task row holding a live claim, whose draft twin accepts a patch and can then
// never be published.
const theClaimedRow = "task-71cb55571fb12e84"

// claimedPatchHarness stands up a fake instance and the parsed manifest pointed
// at it, and records every request path+method the CLI actually sends — the
// only way to prove the mutate was WITHHELD rather than merely unrendered.
type claimedPatchHarness struct {
	t          *testing.T
	server     *httptest.Server
	m          *manifest.Manifest
	ctx        manifest.Context
	seen       []string
	docStatus  int    // status the published-row GET answers (0 -> 200)
	docBody    string // body the published-row GET answers with (empty -> claimed)
	mutateBody string
	// recordBody, when set, receives the RAW body of every mutation the CLI
	// sends. Recording the path alone proves a write happened; recording the
	// body is what lets a test say which FIELDS went with it — the difference
	// between "a patch was sent" and "a patch that could overwrite the claim
	// was sent".
	recordBody func(string)
}

// theClaimedDocBody is the published-row read as `bp doc get --perspective
// published` renders it: content FLAT, the claim block a top-level object
// beside the reserved keys. Copied from the live readback of theClaimedRow.
const theClaimedDocBody = `{"result":{"_id":"` + theClaimedRow + `","_type":"task","_draft":false,"_rev":"r1",` +
	`"title":"PROBE","description":"…","lifecycle_status":"open",` +
	`"claim":{"worker":"cli-r20-w19","epoch":1,"ts_iso":"2026-09-16T09:24:53.504043Z"}}}`

// theUnclaimedDocBody is the SAME row with no claim block at all — the shape an
// unclaimed published task really has (the key is absent, not null).
const theUnclaimedDocBody = `{"result":{"_id":"` + theClaimedRow + `","_type":"task","_draft":false,"_rev":"r1",` +
	`"title":"PROBE","description":"…","lifecycle_status":"open"}}`

func newClaimedPatchHarness(t *testing.T) *claimedPatchHarness {
	t.Helper()
	h := &claimedPatchHarness{t: t}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/"):
			status := h.docStatus
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			body := h.docBody
			if body == "" {
				body = theClaimedDocBody
			}
			if status != http.StatusOK {
				body = `{"error":{"code":"not_found","message":"no such document"}}`
			}
			_, _ = w.Write([]byte(body))
		default:
			if h.recordBody != nil {
				raw, _ := io.ReadAll(r.Body)
				h.recordBody(string(raw))
			}
			w.WriteHeader(http.StatusOK)
			body := h.mutateBody
			if body == "" {
				body = `{"transactionId":"tx1","results":[{"id":"drafts.` + theClaimedRow + `","operation":"update"}]}`
			}
			_, _ = w.Write([]byte(body))
		}
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(claimedPatchManifestJSON, "http://replaced", h.server.URL, 1)
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

func (h *claimedPatchHarness) sent(want string) bool {
	for _, got := range h.seen {
		if got == want {
			return true
		}
	}
	return false
}

// Both routes carry the SCOPED PREFIX, the discard guard's rule: probe and
// mutation move together under the prefix or stay together without it.
const (
	claimedScopePrefix = "/w/acme/p/site"
	claimedMutatePath  = claimedScopePrefix + "/v1/data/mutate/production"
	claimedDocPath     = claimedScopePrefix + "/v1/data/doc/production/task/" + theClaimedRow
)

// runPatchWith drives the real runCommand — the whole guarded path, not the
// guard in isolation — so a future edit that moves or drops the gate call site
// reds these tests instead of passing on a bypassed helper.
func (h *claimedPatchHarness) runPatchWith(g globals, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("doc", "patch")
	if !ok {
		h.t.Fatal("fixture manifest has no doc patch")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

func (h *claimedPatchHarness) runPatch(tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	return h.runPatchWith(globals{}, tail...)
}

// THE DEFECT (task-bff844cc812f0fe4), reproduced on guerrilla 2026-09-16:
// `bp doc patch task drafts.<id>` on a row whose published twin is CLAIMED
// returns a clean `rev:` receipt and prints `bp doc publish task <id>` as the
// next step — and that publish is refused forever by the claim wall, because
// the draft can never grow the claim block the published row holds. The write
// must not be sent, and the refusal must name the sequence that does land.
//
// REVERT-RED: drop the guardClaimedDraftPatch call from run.go and the mutate
// is sent, so `h.sent(POST …)` fires and the exit code is exitOK.
func TestPatchOnClaimedRowsDraftTwinSendsNoMutation(t *testing.T) {
	h := newClaimedPatchHarness(t)

	code, _, stderr := h.runPatch("task", "drafts."+theClaimedRow, "--set", "description=evidence")

	if code == exitOK {
		t.Errorf("exit = %d (ok) — an unpublishable draft write must not report success", code)
	}
	if h.sent("POST " + claimedMutatePath) {
		t.Error("the patch mutation was sent against a claimed row's draft twin — the guard did not hold")
	}
	if !h.sent("GET " + claimedDocPath) {
		t.Errorf("the guard never probed the published row; requests seen: %v", h.seen)
	}
	// The refusal must carry: WHO holds it, and the two commands that land the
	// edit. A refusal an operator cannot act on is a different bug.
	for _, want := range []string{
		"cli-r20-w19",
		"epoch 1",
		"bp doc discard-draft task " + theClaimedRow,
		"bp doc patch task " + theClaimedRow,
		claimedDraftPatchFlag,
	} {
		if !strings.Contains(stderr, want) {
			t.Errorf("refusal omits %q — it must name the holder and the way out:\n%s", want, stderr)
		}
	}
}

// THE QUIET ARM. An UNCLAIMED row's draft twin patches and publishes normally —
// that is the control the row itself isolated the cause with — so the guard
// must be invisible there: the mutation goes out, the exit is 0, and it says
// nothing about claims.
func TestPatchOnUnclaimedRowsDraftTwinProceedsSilently(t *testing.T) {
	h := newClaimedPatchHarness(t)
	h.docBody = theUnclaimedDocBody

	code, _, stderr := h.runPatchWith(globals{yes: true}, "task", "drafts."+theClaimedRow, "--set", "description=evidence")

	if code != exitOK {
		t.Errorf("exit = %d — an unclaimed row's draft twin must patch exactly as before, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + claimedMutatePath) {
		t.Errorf("the mutation was withheld on an UNCLAIMED row; requests seen: %v", h.seen)
	}
	for _, unwanted := range []string{"refusing to patch", "CLAIMED", "discard-draft"} {
		if strings.Contains(stderr, unwanted) {
			t.Errorf("the guard spoke about claims on an unclaimed row (%q):\n%s", unwanted, stderr)
		}
	}
}

// THE OTHER QUIET ARM, and the one that keeps the guard cheap: a BARE-id task
// patch is the path that WORKS (published-first since task-f0de48637a21d3dc —
// it edits the published row in place and leaves the claim untouched). It must
// not be gated, and it must not cost a probe request either.
func TestBareIDTaskPatchIsNeitherGatedNorProbed(t *testing.T) {
	h := newClaimedPatchHarness(t)

	code, _, stderr := h.runPatchWith(globals{yes: true}, "task", theClaimedRow, "--set", "description=evidence")

	if code != exitOK {
		t.Errorf("exit = %d — the bare-id patch is the working path and must never be gated, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + claimedMutatePath) {
		t.Errorf("the bare-id mutation was withheld; requests seen: %v", h.seen)
	}
	if h.sent("GET " + claimedDocPath) {
		t.Errorf("the guard probed on the bare-id path, which it never gates — that is a request for nothing: %v", h.seen)
	}
}

// A NON-TASK draft patch is outside the claim wall entirely (`stale_claim?/2`
// is reached only by `ensure_task_publish_transition_legal("task", …)`), so the
// guard must not fire — and must not spend a request — on `drafts.` ids of any
// other type.
func TestNonTaskDraftPatchIsNeitherGatedNorProbed(t *testing.T) {
	h := newClaimedPatchHarness(t)

	code, _, stderr := h.runPatchWith(globals{yes: true}, "article", "drafts.some-article", "--set", "title=x")

	if code != exitOK {
		t.Errorf("exit = %d — a non-task draft patch must be untouched, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + claimedMutatePath) {
		t.Errorf("the mutation was withheld on a non-task draft; requests seen: %v", h.seen)
	}
	if strings.Contains(stderr, "refusing to patch") {
		t.Errorf("the guard fired on a non-task type:\n%s", stderr)
	}
}

// The escape hatch has to exist — the server itself names editing the twin by
// name as the deliberate act — and it has to be EXPLICIT, so it says out loud
// what the operator is getting.
func TestEditClaimedDraftFlagProceedsAndSaysThePublishWillRefuse(t *testing.T) {
	h := newClaimedPatchHarness(t)

	code, _, stderr := h.runPatch("task", "drafts."+theClaimedRow, "--set", "description=evidence", claimedDraftPatchFlag)

	if code != exitOK {
		t.Errorf("exit = %d — the explicit opt-in must let the twin edit through, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + claimedMutatePath) {
		t.Errorf("the mutation was withheld even under %s; requests seen: %v", claimedDraftPatchFlag, h.seen)
	}
	if !strings.Contains(stderr, "will refuse it") {
		t.Errorf("the flagged path never says the publish is doomed:\n%s", stderr)
	}
}

// The global --yes must NOT be the key to this door. It is the prod
// write-guard's answer, it is set in every CI script, and reading it here would
// re-open the trap for exactly the callers most likely to hit it.
func TestGlobalYesDoesNotUnlockTheClaimedDraftPatch(t *testing.T) {
	h := newClaimedPatchHarness(t)

	code, _, _ := h.runPatchWith(globals{yes: true}, "task", "drafts."+theClaimedRow, "--set", "description=evidence")

	if code == exitOK {
		t.Error("--yes unlocked the claimed-draft patch — the opt-in must be the command-local flag")
	}
	if h.sent("POST " + claimedMutatePath) {
		t.Error("--yes let the unpublishable write through")
	}
}

// UNKNOWN is a state of its own and must never be reported as "unclaimed". It
// fails OPEN here — unlike the discard guard's unchecked case, this write
// destroys nothing — but it has to SAY the check did not land, and it has to
// carry the recovery for the case it could not rule out.
func TestUnreadablePublishedRowProceedsButSaysTheCheckDidNotLand(t *testing.T) {
	h := newClaimedPatchHarness(t)
	h.docStatus = http.StatusInternalServerError

	code, _, stderr := h.runPatchWith(globals{yes: true}, "task", "drafts."+theClaimedRow, "--set", "description=evidence")

	if code != exitOK {
		t.Errorf("exit = %d — an unreadable probe must not block a non-destructive write, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + claimedMutatePath) {
		t.Errorf("the mutation was withheld on an UNKNOWN verdict; requests seen: %v", h.seen)
	}
	for _, want := range []string{"could not check", "HTTP 500", "discard-draft"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("the unknown verdict omits %q — it must not read as a measurement:\n%s", want, stderr)
		}
	}
}

// A draft-only document (no published row at all) has no claim to obliterate,
// so the 404 is a FREE verdict, not an unknown: patch it and say nothing.
func TestDraftOnlyDocumentPatchesSilently(t *testing.T) {
	h := newClaimedPatchHarness(t)
	h.docStatus = http.StatusNotFound

	code, _, stderr := h.runPatchWith(globals{yes: true}, "task", "drafts."+theClaimedRow, "--set", "description=evidence")

	if code != exitOK {
		t.Errorf("exit = %d — a draft-only row has no claim wall to hit, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + claimedMutatePath) {
		t.Errorf("the mutation was withheld on a draft-only row; requests seen: %v", h.seen)
	}
	if strings.Contains(stderr, "could not check") || strings.Contains(stderr, "refusing to patch") {
		t.Errorf("a 404 published row was reported as unknown or claimed:\n%s", stderr)
	}
}

// claimHolder is the one place a body becomes a verdict, so pin its edges
// directly: a null claim, an empty worker and an undecodable body must all read
// as UNHELD rather than as a claim by "".
func TestClaimHolderReadsOnlyARealClaim(t *testing.T) {
	cases := []struct {
		name       string
		body       string
		wantHeld   bool
		wantWorker string
		wantEpoch  int
	}{
		{"claimed", theClaimedDocBody, true, "cli-r20-w19", 1},
		{"no claim key", theUnclaimedDocBody, false, "", 0},
		{"null claim", `{"result":{"_id":"x","claim":null}}`, false, "", 0},
		{"blank worker", `{"result":{"_id":"x","claim":{"worker":"  ","epoch":3}}}`, false, "", 0},
		{"claim without epoch", `{"result":{"_id":"x","claim":{"worker":"w"}}}`, true, "w", 0},
		{"unparseable", `not json`, false, "", 0},
		{"unwrapped shape", `{"_id":"x","claim":{"worker":"w2","epoch":7}}`, true, "w2", 7},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			worker, epoch, held := claimHolder([]byte(tc.body))
			if held != tc.wantHeld || worker != tc.wantWorker || epoch != tc.wantEpoch {
				t.Errorf("claimHolder = (%q, %d, %v), want (%q, %d, %v)",
					worker, epoch, held, tc.wantWorker, tc.wantEpoch, tc.wantHeld)
			}
		})
	}
}

// The opt-in flag must be stripped before splitArgs ever sees it (the manifest
// never declares it), and only in its BARE form — an inline `=value` typo must
// keep falling through to the ordinary unknown-flag refusal rather than
// silently succeeding.
func TestExtractClaimedDraftPatchFlag(t *testing.T) {
	got, kept := extractClaimedDraftPatchFlag([]string{"task", "drafts.x", claimedDraftPatchFlag, "--set", "a=b"})
	if !got {
		t.Error("the bare flag was not detected")
	}
	if strings.Join(kept, " ") != "task drafts.x --set a=b" {
		t.Errorf("tail after strip = %v", kept)
	}

	got, kept = extractClaimedDraftPatchFlag([]string{"task", "drafts.x", claimedDraftPatchFlag + "=yes"})
	if got {
		t.Error("an inline --edit-claimed-draft=yes was honoured; it must fall through to splitArgs")
	}
	if len(kept) != 3 {
		t.Errorf("the inline form was stripped from the tail: %v", kept)
	}
}

// ── THE ROW'S OWN THREE CASES (task-bff844cc812f0fe4, criterion 3)
//
// The reproduction that filed this row ran three rows, not two, and the third
// is the one that says what the trap is ABOUT. A draft twin is unpublishable
// because it does not carry the published row's claim BLOCK — not because the
// operator is a stranger to the claim. So a row claimed by ANOTHER lane
// (l2core-ssl) and a row claimed by THE ACTOR THEMSELF (l6-docs) are the same
// trap, and the guard must refuse both, naming whichever worker it read. The
// UNCLAIMED control is the third: it is what proves the claim block is the
// cause, because it patches and publishes on the first attempt.
//
// Re-measured live on guerrilla 2026-09-16 by cli-r20-w51 against a row it
// created itself (task-6b973b4578afa660, since cleaned up): with the twin in
// place, `bp doc patch task drafts.<id> --edit-claimed-draft` answered "DRAFT
// updated … rev: bcd2ac2…" and the following publish answered `claim: stale
// draft: the published row carries claim state (worker "probe-w51-holder",
// epoch 1) this draft does not`. Both halves of the title's assertion hold.
//
// REVERT-RED: drop the guardClaimedDraftPatch call from run.go and both
// claimed arms send their mutation and exit 0.
func TestTheRowsThreeCases(t *testing.T) {
	// The identifiers are the row's own, kept verbatim so the cases stay
	// traceable to the reproduction that filed it.
	const (
		otherLaneWorker = "l2core-ssl" // the row claimed by a DIFFERENT lane
		actorWorker     = "l6-docs"    // the row claimed by THE ACTOR
	)

	claimedBody := func(worker string) string {
		return `{"result":{"_id":"` + theClaimedRow + `","_type":"task","_draft":false,"_rev":"r1",` +
			`"title":"PROBE","lifecycle_status":"open",` +
			`"claim":{"worker":"` + worker + `","epoch":2,"ts_iso":"2026-09-16T09:24:53.504043Z"}}}`
	}

	cases := []struct {
		name        string
		body        string
		wantRefused bool
		wantWorker  string
	}{
		{"claimed by another lane", claimedBody(otherLaneWorker), true, otherLaneWorker},
		{"claimed by the actor themself", claimedBody(actorWorker), true, actorWorker},
		{"the UNCLAIMED control", theUnclaimedDocBody, false, ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newClaimedPatchHarness(t)
			h.docBody = tc.body

			code, _, stderr := h.runPatchWith(globals{yes: true},
				"task", "drafts."+theClaimedRow, "--set", "description=evidence")

			sent := h.sent("POST " + claimedMutatePath)
			if tc.wantRefused {
				if code == exitOK || sent {
					t.Errorf("exit = %d, mutation sent = %v — a claimed row's twin must be refused BEFORE the write, whoever holds it:\n%s",
						code, sent, stderr)
				}
				if !strings.Contains(stderr, tc.wantWorker) {
					t.Errorf("the refusal does not name the holder %q — it named someone else or nobody:\n%s", tc.wantWorker, stderr)
				}
				// The guard must not be keyed on WHO holds the claim: being the
				// claimant yourself does not make the draft publishable, so the
				// way out is the same sequence in both claimed cases.
				if !strings.Contains(stderr, "bp doc discard-draft task "+theClaimedRow) {
					t.Errorf("the refusal omits the sequence that lands the edit:\n%s", stderr)
				}
				return
			}
			if code != exitOK || !sent {
				t.Errorf("exit = %d, mutation sent = %v — the unclaimed control must patch exactly as before:\n%s", code, sent, stderr)
			}
			if strings.Contains(stderr, "refusing to patch") {
				t.Errorf("the control was gated, so it proves nothing:\n%s", stderr)
			}
		})
	}
}

// ── NO CLAIM IS OBLITERATED BY THE FIX (task-bff844cc812f0fe4, criterion 4)
//
// The claim lives server-side, so the byte-for-byte proof that an enrichment
// leaves it untouched is an api-side assertion and belongs with the api row
// (task-922e616cb9b99243). What IS provable from here, and is the half this
// guard owns, is that the CLI never puts the claim in play: on the refusal
// path it issues no mutation at all, and on the remedy it prescribes — the
// bare-id patch — the request body it sends carries the edited field and no
// `claim` key, so there is nothing in the wire format that could overwrite it.
//
// Measured against the same live row on 2026-09-16: `bp doc discard-draft task
// <id>` then `bp doc patch task <id> --set description=…` changed the
// description while `jq -S .claim` before and after diffed EMPTY.
//
// REVERT-RED: have guardClaimedDraftPatch return (exitOK, false) on
// publishedClaimHeld and the first arm sees the mutation on the wire.
func TestTheEnrichmentPathNeverPutsTheClaimOnTheWire(t *testing.T) {
	t.Run("the refusal issues no mutation at all", func(t *testing.T) {
		h := newClaimedPatchHarness(t)

		_, _, _ = h.runPatchWith(globals{yes: true}, "task", "drafts."+theClaimedRow, "--set", "description=evidence")

		for _, got := range h.seen {
			if strings.HasPrefix(got, "POST ") {
				t.Errorf("the guard issued %q — a refusal that has already written cannot protect a claim; requests seen: %v", got, h.seen)
			}
		}
	})

	t.Run("the prescribed bare-id patch sends no claim field", func(t *testing.T) {
		h := newClaimedPatchHarness(t)
		var bodies []string
		h.recordBody = func(b string) { bodies = append(bodies, b) }

		code, _, stderr := h.runPatchWith(globals{yes: true}, "task", theClaimedRow, "--set", "description=evidence")

		if code != exitOK {
			t.Fatalf("exit = %d — the remedy the refusal prints must itself run, stderr:\n%s", code, stderr)
		}
		if len(bodies) == 0 {
			t.Fatal("the bare-id patch sent no body at all; there is nothing to inspect")
		}
		for _, b := range bodies {
			if !strings.Contains(b, `"description"`) {
				t.Errorf("the request does not carry the edited field, so this arm is measuring nothing: %s", b)
			}
			if strings.Contains(b, `"claim"`) {
				t.Errorf("the enrichment request carries a claim key — that is the byte that could obliterate a live lease: %s", b)
			}
		}
	})
}
