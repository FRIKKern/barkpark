package cli

// discard_draft_guard.go is the published-twin guard for `bp doc discard-draft`
// — the third client-side gate on the manifest-driven command surface, beside
// the prod write-guard (run.go) and the destroy-tier confirm
// (destroy_confirm.go). Neither of those can catch this one.
//
// THE DEFECT, FOUND THE HARD WAY (dr-w23-bl). `discard-draft` reads as "throw
// away my unpublished EDITS". On a document that has never been published there
// are no edits to throw away — there is only the document — and the server
// deletes it: Content.Lifecycle.do_discard_draft resolves the `drafts.` id and
// deletes that row unconditionally, with no published row to fall back to. Its
// own docstring says "Published version (if any) remains", and the "(if any)"
// is the whole bug. A real backlog row with a full description and four
// acceptance criteria vanished this way, and `bp task get` answered not_found
// until it was dug back out with `bp doc restore-revision`.
//
// WHY DRAFT-ONLY DOCUMENTS EXIST IN QUANTITY, which is what turns a sharp edge
// into a trap: the publish wall's near-duplicate guard refuses a publish with
// 422 duplicate_of and LEAVES THE DRAFT BEHIND. Boards read the published
// ledger, so those rows are invisible — and the verb an agent reaches for to
// tidy an invisible row is the verb that destroys it. The two behaviours
// compose into data loss; this file breaks the composition on the client side.
//
// THE GUARD IS A PORT, NOT AN INVENTION. The Go TUI has had exactly this check
// since armDiscard was written (cmd/barkpark/tui_mutations.go): it probes the
// bare published id before arming R, refuses when the twin is absent, and
// routes the user to D (delete) with its own confirm. Its comment states the
// mechanism plainly — "the twin probe runs here at arm time because the
// server's discardDraft does NOT twin-guard". The TUI and the CLI are two front
// ends on one mutation, and only one of them was hardened. This is the other
// one, following the TUI's three-state discipline verbatim:
//
//   - twin PRESENT  -> proceed, untouched. A genuine revert is not gated.
//   - twin ABSENT   -> refuse, unless --delete-unpublished is passed.
//   - probe FAILED  -> refuse, with a DIFFERENT sentence. "We could not ask" is
//     not "there is nothing there", and reporting it as an absence would assert
//     a fact nobody measured — the exact error discardTwinStatusMessage exists
//     to prevent in the TUI.
//
// WHY NOT THE GLOBAL --yes. It is the prod write-guard's answer, it is set in
// every CI script that touches a live instance, and the destroy-tier gate
// already consumes it for a different question. Keying this door on it would
// leave it wide open for precisely the callers most likely to walk through.
// The opt-in is a command-local flag, and because the manifest never declares
// it, it must be stripped from tail before splitArgs ever sees it — the
// `--fail-on-failed-delivery` precedent in run.go.

import (
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// discardDraftCommandID keys the guard on the manifest command ID, never on the
// noun/verb spelling, so a server that renames the verb cannot silently un-gate
// the operation (the destroyTargets registry's rule).
const discardDraftCommandID = "doc.discard-draft"

// discardDraftDeleteFlag is the explicit destructive opt-in. It is named for
// what it DOES, not for how loudly it does it: --force says nothing about the
// document, --delete-unpublished says the row has never been published and is
// about to be deleted.
const discardDraftDeleteFlag = "--delete-unpublished"

// extractDiscardDraftDeleteFlag removes every bare occurrence of
// discardDraftDeleteFlag from tail and reports whether it was present. Like
// extractFailOnFailedDeliveryFlag, an inline `--delete-unpublished=x` form is
// deliberately left in tail untouched so it falls through to splitArgs'
// ordinary "unknown flag" refusal rather than silently succeeding on a typo.
func extractDiscardDraftDeleteFlag(tail []string) (bool, []string) {
	found := false
	kept := make([]string, 0, len(tail))
	for _, a := range tail {
		if a == discardDraftDeleteFlag {
			found = true
			continue
		}
		kept = append(kept, a)
	}
	return found, kept
}

// discardDraftArgs re-resolves cmd's positionals so the guard probes the same
// document the mutation will touch. Like destroyRefArgs it re-runs the PURE
// splitArgs/bindArgs rather than threading a map out of buildManifestRequest
// (which must still run exactly once, because it is the one that reads stdin).
//
// The id is normalised to the BARE published id. That normalisation is not
// cosmetic: a drafts.-prefixed id is what a board render hands an operator, the
// server accepts it (Content.discard_draft's bare-id contract normalises it
// too), and probing it unnormalised would find the DRAFT, read that as "the
// published twin exists", and wave the delete straight through — the guard
// going vacuous while still looking green.
func discardDraftArgs(cmd manifest.Command, tail []string) (typeName, bareID string, ok bool) {
	if cmd.ID != discardDraftCommandID {
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
	typeName, id := args["type"], args["id"]
	if typeName == "" || id == "" {
		return "", "", false
	}
	return typeName, strings.TrimPrefix(id, "drafts."), true
}

// discardTwinVerdict is the three-state answer the guard acts on. UNKNOWN is a
// state in its own right and never collapses into ABSENT — that collapse is the
// one that deletes documents.
type discardTwinVerdict int

const (
	discardTwinPresent discardTwinVerdict = iota
	discardTwinAbsent
	discardTwinUnknown
)

// probeDiscardDraftTwin asks whether the BARE (published) id resolves, using
// the command's own sibling read on the same route with the same credentials —
// never a hand-rolled URL. It returns the verdict and, for UNKNOWN, the one
// clause that names WHICH failure stopped it.
//
// `--perspective published` rides the read when the server declares the flag.
// QueryController.show keeps an EXACT-ID lookup for `published` and `raw` (only
// `drafts` prefers the draft twin and falls back to the published row), so a
// bare id whose only row is a draft answers 404 — precisely the signal this
// guard needs, and the reason the probe is not vacuous.
func probeDiscardDraftTwin(g globals, ctx manifest.Context, m *manifest.Manifest, typeName, bareID string) (discardTwinVerdict, string) {
	get, ok := m.Tree().Lookup("doc", "get")
	if !ok {
		return discardTwinUnknown, "this server declares no `bp doc get`, so the published version could not be looked up"
	}

	tail := []string{typeName, bareID}
	if commandDeclaresFlag(*get, "perspective") {
		tail = append(tail, "--perspective", "published")
	}

	// Headless dispatch, exactly as destroyPreview and the MCP handlers use it:
	// no rendering, no guards, no stdout. g.yes is set because the prod
	// write-guard lives in runCommand and this read must never prompt (it is a
	// GET regardless), and --dry-run is cleared so a previewed dry run still
	// performs the check rather than checking nothing.
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false

	status, _, err := execManifestCommand(lg, ctx, m, *get, tail)
	switch {
	case err != nil:
		return discardTwinUnknown, "the check never reached the server (" + err.Error() + ")"
	case status == 404:
		return discardTwinAbsent, ""
	case status/100 == 2:
		return discardTwinPresent, ""
	default:
		return discardTwinUnknown, fmt.Sprintf("the check answered HTTP %d", status)
	}
}

// guardDiscardDraft gates one `bp doc discard-draft`. It reports refused=true
// with the exit code the caller must return WITHOUT sending; refused=false lets
// the mutation proceed unchanged. It is a no-op — and does no network work —
// for every command that is not doc.discard-draft.
func guardDiscardDraft(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, deleteUnpublished bool) (int, bool) {
	typeName, bareID, ok := discardDraftArgs(cmd, tail)
	if !ok {
		// Not this command, or positionals buildManifestRequest has already
		// refused with its own usage block. Nothing to guard.
		return exitOK, false
	}
	ref := typeName + " " + bareID

	switch verdict, why := probeDiscardDraftTwin(g, ctx, m, typeName, bareID); verdict {
	case discardTwinPresent:
		return exitOK, false

	case discardTwinAbsent:
		if deleteUnpublished {
			// The preview guarantee the destroy gate established: print WHAT is
			// being destroyed before doing it, and never let it evaporate in a
			// script. Reachable only once the probe has PROVEN the absence, so
			// this sentence is a measurement and never a guess.
			out.errf("%s has no published version — this discard DELETES the document outright (%s was given). The way back is `bp doc history` then `bp doc restore-revision <rev_id> %s`.",
				ref, discardDraftDeleteFlag, typeName)
			return exitOK, false
		}
		return useError(out, "draft_only_discard", fmt.Sprintf(
			"refusing to discard the only copy of %s: it has no published version, so discard-draft is not a revert here — it DELETES the document, and `bp doc get %s %s` will then answer not_found. There are no published edits to fall back to. If you really do mean to delete it, re-run with %s; afterwards the only way back is `bp doc history` then `bp doc restore-revision <rev_id> %s`.",
			ref, typeName, bareID, discardDraftDeleteFlag, typeName), exitValidation), true

	default:
		if deleteUnpublished {
			out.errf("could not check whether %s has a published version — %s. Proceeding because %s was given; if a published version does exist this is still a plain revert.",
				ref, why, discardDraftDeleteFlag)
			return exitOK, false
		}
		return useError(out, "discard_twin_unchecked", fmt.Sprintf(
			"refusing to discard %s: the published-version check did not land — %s — so whether this document has a published version to fall back to is UNKNOWN. That is not a report that it is missing. On a never-published document discard-draft deletes the row outright, so the unchecked case fails closed. Re-run once the read works, or pass %s to accept the delete.",
			ref, why, discardDraftDeleteFlag), exitGeneric), true
	}
}
