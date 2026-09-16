package cli

// claimed_draft_patch_guard.go is the claim-wall pre-flight for
// `bp doc patch task drafts.<id>` — the fourth client-side gate on the
// manifest-driven command surface, beside the prod write-guard (run.go), the
// destroy-tier confirm (destroy_confirm.go) and the published-twin guard
// (discard_draft_guard.go).
//
// ── THE TRAP, REPRODUCED LIVE ON guerrilla 2026-09-16 (task-bff844cc812f0fe4)
//
// A worker holds a row and wants to append evidence to its description. The
// draft-addressed patch answers with a clean receipt and a command to run:
//
//	$ bp doc patch task drafts.task-71cb55571fb12e84 --set description=… --yes
//	DRAFT updated (drafts.task-71cb55571fb12e84): the published row is
//	UNCHANGED until you run `bp doc publish task task-71cb55571fb12e84`
//	rev: 2c3f73559fb1942256dee533385785d3
//
//	$ bp doc publish task task-71cb55571fb12e84 --yes
//	bp: task content failed validation
//	  claim: stale draft: the published row carries claim state (worker
//	  "cli-r20-w19", epoch 1) this draft does not — publishing would obliterate
//	  it. Re-derive the draft from the published row (patch, then publish) …
//
// The publish wall (api/lib/barkpark/content/lifecycle.ex, `stale_claim?/2`:
// `draft_content["claim"] != pub_content["claim"]`) is CORRECT — the draft
// really would obliterate a live lease — and it is not negotiable from here.
// What is wrong is that the CLI walked the operator into it and then PRINTED
// the doomed command as the remedy. The write is not destructive; it is
// merely unlandable, and it stays that way forever: the draft can never grow
// the claim block the published row keeps moving underneath it.
//
// ── WHY THE REMEDY IN THE PUBLISH REFUSAL CANNOT BE FOLLOWED
//
// "Re-derive the draft from the published row (patch, then publish)" is the
// one path a draft-addressed patch has already closed. Once the twin exists,
// the BARE-id patch is refused too, by the published-first fork fence
// (mutations.ex): "a draft twin `drafts.<id>` already exists … Resolve the
// fork first — `discardDraft` … or `publish` …". So the two refusals point at
// each other: publish says patch, patch says publish-or-discard. Measured,
// both ways, on one row in one minute.
//
// THE PATH THAT ACTUALLY WORKS, also measured on that row:
//
//	bp doc discard-draft task <bare id>     # drop the unlandable twin
//	bp doc patch task <bare id> --set …     # published-first: LANDS
//
// The bare-id patch on a `type:task` row is published-first since
// task-f0de48637a21d3dc (`@published_first_patch_types`, `land_patch/5`): it
// reads the published row as its base and publishes in the same call, so the
// claim rides through untouched. Readback after that sequence: the description
// changed and `claim.worker` / `claim.epoch` were byte-identical.
//
// ── WHAT THIS GUARD DOES, AND WHAT IT DELIBERATELY DOES NOT
//
// It fires ONLY on `doc patch`, ONLY for `type:task`, and ONLY when the id
// names the draft twin explicitly (`drafts.…`). A bare-id patch is the path
// that works and is never gated — that is the quiet arm, and it does no
// network work at all.
//
//   - published row CLAIMED  -> refuse before sending, name the working path.
//   - published row UNCLAIMED -> proceed, silent. A draft-addressed patch on an
//     unclaimed row publishes fine; gating it would be a guard with no subject.
//   - probe FAILED / row ABSENT -> PROCEED, with one line saying the check did
//     not land. This is the deliberate inverse of discardDraftTwinUnknown's
//     fail-CLOSED, and the difference is the blast radius: discard-draft on the
//     unchecked case DELETES a document, while this write only parks bytes on a
//     draft. Failing closed on a read hiccup would block a harmless edit; what
//     it must never do is report "unclaimed" about a row nobody measured, so
//     UNKNOWN keeps its own sentence.
//
// The escape hatch is an explicit command-local flag, never the global --yes —
// the discard-draft guard's rule, for the same reason: --yes is the prod
// write-guard's answer and is set in every CI script. Editing a twin on
// purpose (to inspect it, or to fix it before discarding) stays available
// through --edit-claimed-draft, because the server itself names that as the
// deliberate act ("To edit the twin deliberately, address it by name").

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// docPatchCommandID keys the guard on the manifest command ID rather than on
// the noun/verb spelling, so a server that renames the verb cannot silently
// un-gate it (the destroyTargets registry's rule, and discardDraftCommandID's).
const docPatchCommandID = "doc.patch"

// claimedDraftPatchFlag is the deliberate-twin-edit opt-in. Named for the act,
// not for its volume: --force says nothing, --edit-claimed-draft says the
// target is a draft whose published row is held by somebody.
const claimedDraftPatchFlag = "--edit-claimed-draft"

// The `drafts.` prefix this guard keys on is run.go's draftIDPrefix: a
// `drafts.`-prefixed id names the twin explicitly and keeps the draft-first
// patch base (api/lib/barkpark/content/draft_id.ex), which is precisely the
// case this guard covers.

// extractClaimedDraftPatchFlag removes every bare occurrence of
// claimedDraftPatchFlag from tail and reports whether it was present. As with
// extractDiscardDraftDeleteFlag, an inline `--edit-claimed-draft=x` form is
// left in tail so it falls through to splitArgs' ordinary unknown-flag refusal
// instead of succeeding on a typo.
func extractClaimedDraftPatchFlag(tail []string) (bool, []string) {
	found := false
	kept := make([]string, 0, len(tail))
	for _, a := range tail {
		if a == claimedDraftPatchFlag {
			found = true
			continue
		}
		kept = append(kept, a)
	}
	return found, kept
}

// claimedDraftPatchArgs re-resolves cmd's positionals so the guard probes the
// same document the mutation will touch, re-running the PURE splitArgs/bindArgs
// exactly as discardDraftArgs does (buildManifestRequest must still run once and
// only once — it is the one that reads stdin).
//
// ok is false for every command that is not a `drafts.`-addressed `type:task`
// patch, so the guard costs nothing — not even a request — on the bare-id path
// that lands, on any other type, and on any other verb.
func claimedDraftPatchArgs(cmd manifest.Command, tail []string) (bareID string, ok bool) {
	if cmd.ID != docPatchCommandID {
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
	if args["type"] != "task" || !strings.HasPrefix(args["id"], draftIDPrefix) {
		return "", false
	}
	bare := strings.TrimPrefix(args["id"], draftIDPrefix)
	if bare == "" {
		return "", false
	}
	return bare, true
}

// publishedClaimVerdict is the three-state answer. UNKNOWN is a state in its own right
// and never collapses into UNCLAIMED — that collapse would let the guard print
// a fact about a row it never read.
type publishedClaimVerdict int

const (
	publishedClaimHeld publishedClaimVerdict = iota
	publishedClaimFree
	publishedClaimUnknown
)

// publishedClaim is the slice of the published task document this guard reads.
// `bp doc get` renders content FLAT (the reserved `_id`/`_type`/`_draft` keys
// sit beside the content fields), so the claim block is a top-level `claim`
// object — measured against guerrilla, where an unclaimed row carries no such
// key at all.
type publishedClaim struct {
	Claim *struct {
		Worker string `json:"worker"`
		Epoch  *int   `json:"epoch"`
	} `json:"claim"`
}

// claimHolder reports the worker and epoch a published-row body carries, or
// ok=false when the body has no claim block (an unclaimed row) — never a guess
// from a body it could not parse: an undecodable body answers ok=false and the
// caller treats the whole probe as UNKNOWN through its own error path.
func claimHolder(body []byte) (worker string, epoch int, ok bool) {
	var doc publishedClaim
	if json.Unmarshal(unwrapResult(body), &doc) != nil || doc.Claim == nil {
		return "", 0, false
	}
	if strings.TrimSpace(doc.Claim.Worker) == "" {
		return "", 0, false
	}
	if doc.Claim.Epoch == nil {
		return doc.Claim.Worker, 0, true
	}
	return doc.Claim.Worker, *doc.Claim.Epoch, true
}

// probePublishedClaim asks whether the BARE published row is claimed, using the
// command's own sibling read on the same route with the same credentials —
// never a hand-rolled URL, the discard guard's rule.
//
// `--perspective published` rides the read when the server declares the flag:
// QueryController.show keeps an EXACT-ID lookup for `published`, so this can
// never answer about the draft twin whose claim block is the thing in question.
func probePublishedClaim(g globals, ctx manifest.Context, m *manifest.Manifest, bareID string) (publishedClaimVerdict, string, string, int) {
	get, ok := m.Tree().Lookup("doc", "get")
	if !ok {
		return publishedClaimUnknown, "this server declares no `bp doc get`, so the published row could not be looked up", "", 0
	}

	tail := []string{"task", bareID}
	if commandDeclaresFlag(*get, "perspective") {
		tail = append(tail, "--perspective", "published")
	}

	// Headless dispatch, exactly as probeDiscardDraftTwin does it: no rendering,
	// no guards, no stdout; --yes so the prod write-guard in runCommand cannot
	// prompt on what is a GET either way, and --dry-run cleared so a previewed
	// dry run still performs the check rather than checking nothing.
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false

	status, body, err := execManifestCommand(lg, ctx, m, *get, tail)
	switch {
	case err != nil:
		return publishedClaimUnknown, "the check never reached the server (" + err.Error() + ")", "", 0
	case status == 404:
		// No published row: this twin is a draft-only document, the publish wall's
		// claim gate has nothing to compare against, and the patch is an ordinary
		// draft edit. Not this guard's case.
		return publishedClaimFree, "", "", 0
	case status/100 != 2:
		return publishedClaimUnknown, fmt.Sprintf("the check answered HTTP %d", status), "", 0
	}

	worker, epoch, held := claimHolder(body)
	if !held {
		return publishedClaimFree, "", "", 0
	}
	return publishedClaimHeld, "", worker, epoch
}

// claimedDraftPatchRefusal is the refusal text. Built here, not inline, so the
// test can assert on the same sentence the operator reads.
func claimedDraftPatchRefusal(bareID, worker string, epoch int) string {
	return fmt.Sprintf(
		"refusing to patch drafts.%s: the published row is CLAIMED (worker %q, epoch %d), so this draft can never be published — the publish wall refuses a draft that does not carry the published row's claim block (\"stale draft: … publishing would obliterate it\"), and re-patching cannot add it, because the bare-id patch is then refused too by the draft-twin fork fence. The two refusals point at each other. The path that lands the edit AND preserves the claim is: `bp doc discard-draft task %s` then `bp doc patch task %s --set …` — a bare-id task patch is published-first, so it edits the published row in place and leaves worker/epoch untouched. To edit this twin deliberately anyway, re-run with %s.",
		bareID, worker, epoch, bareID, bareID, claimedDraftPatchFlag)
}

// guardClaimedDraftPatch gates one `bp doc patch task drafts.<id>`. It reports
// refused=true with the exit code the caller must return WITHOUT sending;
// refused=false lets the mutation proceed unchanged. It is a no-op — and does
// no network work — for every command that is not a draft-addressed task patch.
func guardClaimedDraftPatch(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, editClaimedDraft bool) (int, bool) {
	bareID, ok := claimedDraftPatchArgs(cmd, tail)
	if !ok {
		return exitOK, false
	}

	switch verdict, why, worker, epoch := probePublishedClaim(g, ctx, m, bareID); verdict {
	case publishedClaimFree:
		return exitOK, false

	case publishedClaimHeld:
		if editClaimedDraft {
			// The preview guarantee the destroy gate established: say what the
			// write will and will not do before doing it. Reachable only once the
			// probe has PROVEN the claim, so this sentence is a measurement.
			out.errf("drafts.%s is the twin of a CLAIMED row (worker %q, epoch %d) — this edit stays on the draft and `bp doc publish task %s` will refuse it (%s was given).",
				bareID, worker, epoch, bareID, claimedDraftPatchFlag)
			return exitOK, false
		}
		return useError(out, "claimed_draft_patch", claimedDraftPatchRefusal(bareID, worker, epoch), exitValidation), true

	default:
		// UNKNOWN fails OPEN, unlike the discard guard's unchecked case: this
		// write destroys nothing, so refusing on a read hiccup would block a
		// harmless edit. What it must not do is assert an absence it never
		// measured, so the unknown gets its own sentence rather than silence.
		out.errf("could not check whether the published row task %s is claimed — %s. Proceeding; if it IS claimed, `bp doc publish task %s` will refuse this draft and the way to land the edit is `bp doc discard-draft task %s` then a bare-id `bp doc patch task %s`.",
			bareID, why, bareID, bareID, bareID)
		return exitOK, false
	}
}
