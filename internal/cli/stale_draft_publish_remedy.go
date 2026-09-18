package cli

// stale_draft_publish_remedy.go is the PUBLISH-side half of the claimed-draft
// trap that claimed_draft_patch_guard.go gates on the PATCH side.
//
// ── THE DEFECT, REPRODUCED LIVE ON guerrilla 2026-09-18 (task-bff844cc812f0fe4)
//
// A draft twin of a CLAIMED task can never be published, and the refusal that
// says so PRESCRIBES A REMEDY THAT IS ITSELF REFUSED. Measured end to end on a
// disposable row (task-967347fae9367384, since cancelled):
//
//	$ bp doc publish task task-967347fae9367384 --yes
//	bp: task content failed validation
//	  claim: stale draft: the published row carries claim state (worker
//	  "probe-w10-holder2", epoch 1) this draft does not — publishing would
//	  obliterate it. Re-derive the draft from the published row (patch, then
//	  publish), or move the claim through the sanctioned verbs …
//
//	$ bp doc patch task task-967347fae9367384 --set description=… --yes   # "patch"
//	bp: task content failed validation
//	  _id: a draft twin `drafts.task-967347fae9367384` already exists for the
//	  published task … Resolve the fork first …
//
//	$ bp doc publish task task-967347fae9367384 --yes                     # "then publish"
//	bp: task content failed validation
//	  claim: stale draft: … (byte-identical to the first refusal)
//
// Three commands, one closed loop. The prescribed remedy is the one path the
// twin has already shut, so an operator who follows the sentence in front of
// them lands exactly where they started.
//
// THE SEQUENCE THAT ACTUALLY WORKS, measured on that same row in the same
// minute, with the claim read before and after:
//
//	bp doc discard-draft task <bare id>     # drop the unlandable twin
//	bp doc patch task <bare id> --set …     # published-first: LANDS
//
// `jq -S .claim` over the row before and after diffed EMPTY — worker, epoch,
// ts_iso, lease_expires_at and the whole work_field_digests map — while the
// description read back as the new text. The bare-id patch on a `type:task`
// row is published-first (`@published_first_patch_types` / `land_patch/5`), so
// it edits the published row in place and the lease rides through untouched.
//
// ── FENCE, AND WHY THIS IS A CLI FILE AND NOT AN api ONE
//
// The wrong sentence is a server string: api/lib/barkpark/content/lifecycle.ex
// (the "Re-derive the draft from the published row (patch, then publish)"
// clause). Rewriting it is the api lane's work and is tracked separately as
// task-922e616cb9b99243. This file does NOT touch the wall, the refusal, or
// the exit code. It is the surface that PRINTS that sentence to a human, and
// it adds one line naming the sequence that lands — the same advisory shape as
// emitDocGetDraftPerspective and emitMutatePerspective.
//
// ── IT RETIRES ITSELF
//
// The advisory is keyed on the BROKEN REMEDY PHRASE, not merely on the
// stale-draft refusal. The day api/ stops prescribing "Re-derive the draft from
// the published row", this file goes silent on its own and cannot contradict
// the corrected sentence beside it. A guard that must be remembered to be
// removed is a guard that outlives its subject.
//
// ── WHAT IT COSTS
//
// Nothing. No probe, no extra request, no read of any kind: the whole decision
// is made from the response body the dispatch already holds. Every success,
// every other command, every other refusal and every claimed-draft refusal from
// a server that has been fixed all render byte-identically to before. It writes
// to stderr only, so `-o json` stays one byte-identical document.

import (
	"encoding/json"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// docPublishCommandID keys the advisory on the manifest command ID rather than
// on the noun/verb spelling, so a server that renames the verb cannot silently
// re-enable it against a command it was never measured on
// (docPatchCommandID's rule).
const docPublishCommandID = "doc.publish"

// staleDraftClaimMarker is the invariant half of the server's refusal — the
// clause that identifies WHICH wall answered. It has been byte-stable across
// every reproduction on this row since 2026-09-01.
const staleDraftClaimMarker = "stale draft: the published row carries claim state"

// staleDraftBrokenRemedy is the clause this advisory exists to correct, and the
// reason it is matched rather than assumed: it is the SELF-RETIREMENT KEY. No
// match, no advisory. api/lib/barkpark/content/lifecycle.ex is the emitter.
const staleDraftBrokenRemedy = "Re-derive the draft from the published row"

// staleDraftRefusal is the slice of the error envelope this file reads: the
// per-field validation_failed payload, of which only `claim` is consulted.
// Deliberately NOT a typed decode of the whole `details` object — its shape is
// per-code, and a typed decode that fits one shape fails the unmarshal on every
// other (apiError.details' own note).
type staleDraftRefusal struct {
	Error struct {
		Details struct {
			Claim []string `json:"claim"`
		} `json:"details"`
	} `json:"error"`
}

// staleDraftPublishRefused reports whether respBody is the claimed-draft publish
// refusal AND still carries the broken remedy.
//
// BOTH clauses are required, and that is the whole design: the marker alone
// would keep firing after api/ prints a remedy that works, at which point this
// line would be a second, unnecessary voice. An undecodable body, a body with
// no claim detail, or a claim detail carrying only one of the two clauses all
// answer false — silence here means "not established", never "no trap".
func staleDraftPublishRefused(respBody []byte) bool {
	var r staleDraftRefusal
	if err := json.Unmarshal(respBody, &r); err != nil {
		return false
	}
	for _, d := range r.Error.Details.Claim {
		if strings.Contains(d, staleDraftClaimMarker) && strings.Contains(d, staleDraftBrokenRemedy) {
			return true
		}
	}
	return false
}

// docPublishArgs re-resolves cmd's positionals so the advisory names the same
// document the refused publish addressed, re-running the PURE splitArgs/bindArgs
// (claimedDraftPatchArgs' rule — buildManifestRequest must still run once and
// only once, it being the one that reads stdin).
//
// The id is normalised to its BARE form: the remedy's two commands are both
// bare-id commands, so printing a `drafts.`-prefixed id would hand over a
// sequence that does not run.
func docPublishArgs(cmd manifest.Command, tail []string) (typeName, bareID string, ok bool) {
	if cmd.ID != docPublishCommandID {
		return "", "", false
	}
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return "", "", false
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return "", "", false
	}
	typeName = args["type"]
	id := args["id"]
	if id == "" {
		id = args["doc_id"]
	}
	bare := strings.TrimPrefix(id, draftIDPrefix)
	if typeName == "" || bare == "" {
		return "", "", false
	}
	return typeName, bare, true
}

// emitStaleDraftPublishRemedy prints the sequence that lands, beneath a publish
// refusal whose own remedy does not.
//
// It never refuses, never changes the exit code and never touches stdout: by
// the time it runs, renderError has already printed the server's refusal
// verbatim and the exit code is fixed. Callers on a 2xx, on any other command,
// or on any refusal that is not this one pay one cheap comparison and print
// nothing.
func emitStaleDraftPublishRemedy(out *writer, cmd manifest.Command, tail []string, status int, respBody []byte) {
	if status >= 200 && status < 300 {
		return
	}
	if cmd.ID != docPublishCommandID {
		return
	}
	if !staleDraftPublishRefused(respBody) {
		return
	}
	typeName, bareID, ok := docPublishArgs(cmd, tail)
	if !ok {
		return
	}
	out.errf("bp: THE REMEDY IN THAT REFUSAL DOES NOT WORK — `patch, then publish` is the one path this draft twin has already closed: while `%s%s` exists, the bare-id patch is refused too, by the published-first fork fence, and the publish then refuses identically. Measured both ways on one row (task-bff844cc812f0fe4). The sequence that LANDS, and leaves the claim byte-identical:\n  bp doc discard-draft %s %s\n  bp doc patch %s %s --set <field>=<value>\nThe first drops the unlandable twin; the second is published-first for a task, so it edits the published row in place and the worker/epoch ride through untouched. To keep the twin's bytes instead, read them with `bp doc get %s %s --perspective drafts` before discarding — `bp doc get` reads the published lens by default.",
		draftIDPrefix, bareID,
		typeName, bareID,
		typeName, bareID,
		typeName, bareID)
}
