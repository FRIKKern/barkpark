package cli

// claimed_restore_revision_guard.go is the SECOND door onto the claim wall.
//
// claimed_draft_patch_guard.go closed `bp doc patch task drafts.<id>`: on a
// published row that is CLAIMED, that patch mints a draft twin the publish wall
// will refuse forever. This file closes the same trap reached by a different
// verb — `bp doc restore-revision <rev_id> task` — which writes the SAME
// unlandable twin and answers with a bare `ok`.
//
// ── THE TRAP, REPRODUCED LIVE ON guerrilla 2026-09-16 (task-fbc594aaf3b013d1)
//
// On a probe row published, then claimed by "w52-probe-holder" at epoch 1:
//
//	$ bp doc restore-revision 5d6bace2-b0f5-4970-bc94-66b7699d6246 task --yes
//	ok
//
//	$ bp doc get task drafts.task-d651ead531380b88 -o json | jq -c '{claim}'
//	{"claim":null}                 # the twin exists and carries NO claim block
//
//	$ bp doc publish task task-d651ead531380b88 --yes
//	bp: task content failed validation
//	  claim: stale draft: the published row carries claim state (worker
//	  "w52-probe-holder", epoch 1) this draft does not — publishing would
//	  obliterate it.
//
//	$ bp doc patch task task-d651ead531380b88 --set description=… --yes
//	bp: task content failed validation
//	  _id: a draft twin `drafts.task-d651ead531380b88` already exists …
//
// A bare `ok` is the whole receipt for a write whose result can never land —
// and it is WORSE than the patch door it mirrors. The patch door at least
// printed a sentence saying a draft had been created; `ok` says nothing at all,
// so the caller has no way to know an edit was parked somewhere unreachable.
// Worse still, the same one command FORKS the row: while that twin exists the
// bare-id patch — the published-first path that lands, and the one the patch
// guard prescribes as the remedy — is refused too by the draft-twin fork
// fence. One restore-revision therefore takes away the only working way to
// enrich a claimed row until somebody knows to run `bp doc discard-draft`.
//
// ── WHY THIS IS A SECOND DOOR AND NOT A SECOND GUARD
//
// Two doors reaching one trap with two independently written claim probes is
// how one of them drifts. So the claim QUESTION is asked in exactly one place:
// probePublishedClaim (claimed_draft_patch_guard.go), reused verbatim here,
// with its three-state publishedClaimVerdict and its published-perspective
// read. What this file adds is only the part that genuinely differs — the
// ADDRESSING.
//
// `doc patch` names its target document directly, so the patch guard can ask
// the claim question from the arguments alone. `doc restore-revision` names a
// REVISION (`rev_id type`), and a revision id says nothing about which document
// it belongs to. So this guard spends ONE extra hop first — `bp doc revision
// <rev_id>`, which answers `{"revision":{"doc_id":…,"type":…}}` — to turn the
// revision into the document id probePublishedClaim already knows how to ask
// about. That hop is the whole delta between the two doors.
//
// ── THE QUIET ARM
//
// `type` is a positional ARGUMENT of restore-revision, so a restore on any
// non-task type is filtered out before any network work at all: no probe, no
// resolve, not one request. On a task whose published row is UNCLAIMED the
// restore proceeds silently — restoring a revision onto an unclaimed row is
// exactly what the verb is for, and gating it would be a guard with no subject.
//
// ── THE THIRD DOOR, MEASURED AND NOT CLOSED HERE
//
// Enumerating the draft-writing verbs BY SHAPE rather than by name (every
// manifest command that can land bytes on `drafts.<id>` of an existing
// published task) gives: doc.patch (closed), doc.restore-revision (this file),
// doc.create-or-replace / doc.create / doc.create-if-not-exists with
// `--set _id=drafts.<id>`, and doc.mutate carrying any of those as a batch op.
// The create-family door was reproduced live on the same probe row in the same
// session and reaches the identical publish refusal; it is filed separately
// rather than folded in here, because each verb needs its own opt-in flag and
// its own refusal wording, and a guard written for a door nobody measured is
// how the wording goes wrong.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// docRestoreRevisionCommandID and docRevisionCommandID key this guard on
// manifest command IDs rather than on verb spelling, so a server that renames
// a verb cannot silently un-gate it — docPatchCommandID's rule.
const (
	docRestoreRevisionCommandID = "doc.restore-revision"
	docRevisionCommandID        = "doc.revision"
)

// claimedRestoreRevisionFlag is the deliberate-restore opt-in, named for the
// act rather than for its volume, and deliberately NOT the global --yes: --yes
// is the prod write-guard's answer and is set in every CI script, so it cannot
// also mean "I know this draft can never be published".
const claimedRestoreRevisionFlag = "--restore-onto-claimed"

// extractClaimedRestoreRevisionFlag removes every bare occurrence of
// claimedRestoreRevisionFlag from tail and reports whether it was present. An
// inline `--restore-onto-claimed=x` form is left in tail so it falls through to
// splitArgs' ordinary unknown-flag refusal instead of succeeding on a typo —
// extractClaimedDraftPatchFlag's rule.
func extractClaimedRestoreRevisionFlag(tail []string) (bool, []string) {
	found := false
	kept := make([]string, 0, len(tail))
	for _, a := range tail {
		if a == claimedRestoreRevisionFlag {
			found = true
			continue
		}
		kept = append(kept, a)
	}
	return found, kept
}

// claimedRestoreRevisionArgs re-resolves cmd's positionals so the guard probes
// the same revision the mutation will restore, re-running the PURE
// splitArgs/bindArgs exactly as claimedDraftPatchArgs does (buildManifestRequest
// must still run once and only once — it is the one that reads stdin).
//
// ok is false for every command that is not a `type:task` restore-revision, so
// the guard costs nothing — not even a request — on any other type or verb.
func claimedRestoreRevisionArgs(cmd manifest.Command, tail []string) (revID string, ok bool) {
	if cmd.ID != docRestoreRevisionCommandID {
		return "", false
	}
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return "", false
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return "", false
	}
	if args["type"] != "task" {
		return "", false
	}
	rev := strings.TrimSpace(args["rev_id"])
	if rev == "" {
		return "", false
	}
	return rev, true
}

// revisionDoc is the slice of `bp doc revision <rev_id>` this guard reads. The
// endpoint answers `{"revision":{…,"doc_id":"task-…","type":"task"}}` —
// measured against guerrilla — so the doc_id sits one level in, beside the
// revision's own id. unwrapResult still runs first because an `{"ok":…,
// "result":…}` envelope is the other shape this transport uses.
type revisionDoc struct {
	Revision *struct {
		DocID string `json:"doc_id"`
		Type  string `json:"type"`
	} `json:"revision"`
}

// revisionDocID reports the BARE published id the revision belongs to. A
// revision taken from the draft twin carries a `drafts.`-prefixed doc_id, and
// the claim question is always about the PUBLISHED row, so the prefix is
// stripped here rather than at the probe — probePublishedClaim is entitled to
// assume it was handed a bare id.
//
// ok=false for every body it could not read a doc_id out of; it never guesses,
// and the caller turns that into UNKNOWN with its own sentence.
func revisionDocID(body []byte) (bareID string, ok bool) {
	var doc revisionDoc
	if json.Unmarshal(unwrapResult(body), &doc) != nil || doc.Revision == nil {
		return "", false
	}
	id := strings.TrimSpace(doc.Revision.DocID)
	id = strings.TrimPrefix(id, draftIDPrefix)
	if id == "" {
		return "", false
	}
	return id, true
}

// resolveRestoreTarget turns a revision id into the bare document id it belongs
// to, using the command's own sibling read on the same route with the same
// credentials — never a hand-rolled URL, the discard guard's rule.
//
// why is non-empty exactly when ok is false, and carries the reason in the
// operator's words, so the UNKNOWN path can say which hop failed rather than
// printing a shrug.
func resolveRestoreTarget(g globals, ctx manifest.Context, m *manifest.Manifest, revID string) (bareID string, why string, ok bool) {
	rev, found := m.Tree().Lookup("doc", "revision")
	if !found || rev.ID != docRevisionCommandID {
		return "", "this server declares no `bp doc revision`, so the revision's document could not be named", false
	}

	// Headless dispatch, exactly as probePublishedClaim does it: no rendering,
	// no guards, no stdout; --yes so the prod write-guard in runCommand cannot
	// prompt on what is a GET either way, and --dry-run cleared so a previewed
	// dry run still performs the check rather than checking nothing.
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false

	status, body, err := execManifestCommand(lg, ctx, m, *rev, []string{revID})
	switch {
	case err != nil:
		return "", "the revision lookup never reached the server (" + err.Error() + ")", false
	case status/100 != 2:
		return "", fmt.Sprintf("the revision lookup answered HTTP %d", status), false
	}

	id, parsed := revisionDocID(body)
	if !parsed {
		return "", "the revision lookup answered a body with no `doc_id`", false
	}
	return id, "", true
}

// claimedRestoreRevisionRefusal is the refusal text. Built here, not inline, so
// the test can assert on the same sentence the operator reads.
func claimedRestoreRevisionRefusal(revID, bareID, worker string, epoch int) string {
	return fmt.Sprintf(
		"refusing to restore revision %s onto task %s: the published row is CLAIMED (worker %q, epoch %d), and restore-revision writes its content back as a DRAFT — a draft that carries no claim block and can therefore never be published, because the publish wall refuses a draft that does not carry the published row's claim (\"stale draft: … publishing would obliterate it\"). Worse, the twin it would create also FORKS the row: while `drafts.%s` exists, the bare-id patch that does land is refused too by the draft-twin fork fence, so this one command takes away the only working way to edit the row. The receipt for that write is a bare `ok`. If you want the revision's CONTENT on the row, read it with `bp doc revision %s` and apply the fields with a bare-id `bp doc patch task %s --set …` — a bare-id task patch is published-first, so it edits the published row in place and leaves worker/epoch untouched. To write the draft anyway (you will then need `bp doc discard-draft task %s` to unfork the row), re-run with %s.",
		revID, bareID, worker, epoch, bareID, revID, bareID, bareID, claimedRestoreRevisionFlag)
}

// guardClaimedRestoreRevision gates one `bp doc restore-revision <rev_id> task`.
// It reports refused=true with the exit code the caller must return WITHOUT
// sending; refused=false lets the mutation proceed unchanged. It is a no-op —
// and does no network work — for every command that is not a task
// restore-revision.
func guardClaimedRestoreRevision(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, restoreOntoClaimed bool) (int, bool) {
	revID, ok := claimedRestoreRevisionArgs(cmd, tail)
	if !ok {
		return exitOK, false
	}

	bareID, why, resolved := resolveRestoreTarget(g, ctx, m, revID)
	if !resolved {
		// UNKNOWN fails OPEN, the patch guard's rule and for its reason: this
		// write destroys nothing, so refusing on a read hiccup would block a
		// legitimate restore. What it must never do is assert an absence it
		// never measured, so the unknown gets its own sentence rather than
		// silence.
		out.errf("could not check whether restoring revision %s would land on a CLAIMED row — %s. Proceeding; if the row IS claimed, the restored draft can never be published and `bp doc discard-draft task <id>` is what unforks the row.", revID, why)
		return exitOK, false
	}

	switch verdict, pwhy, worker, epoch := probePublishedClaim(g, ctx, m, bareID); verdict {
	case publishedClaimFree:
		return exitOK, false

	case publishedClaimHeld:
		if restoreOntoClaimed {
			// The preview guarantee the destroy gate established: say what the
			// write will and will not do before doing it. Reachable only once the
			// probe has PROVEN the claim, so this sentence is a measurement.
			out.errf("task %s is CLAIMED (worker %q, epoch %d) — this restore stays on `drafts.%s`, `bp doc publish task %s` will refuse it, and the bare-id patch is forked until `bp doc discard-draft task %s` (%s was given).",
				bareID, worker, epoch, bareID, bareID, bareID, claimedRestoreRevisionFlag)
			return exitOK, false
		}
		return useError(out, "claimed_restore_revision", claimedRestoreRevisionRefusal(revID, bareID, worker, epoch), exitValidation), true

	default:
		out.errf("could not check whether the published row task %s is claimed — %s. Proceeding; if it IS claimed, `bp doc publish task %s` will refuse the restored draft and `bp doc discard-draft task %s` is what unforks the row.",
			bareID, pwhy, bareID, bareID)
		return exitOK, false
	}
}
