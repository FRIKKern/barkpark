package cli

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// docGetCommandID is the manifest id this file keys on. Named once so the guard
// and its test cannot drift from the command they describe.
const docGetCommandID = "doc.get"

// docGetDraftProbePerspective is the lens the probe reads. `drafts` PREFERS the
// drafts.<id> twin and falls back to the published row — and the published row
// is the one that just answered not_found, so a 2xx here can only have come
// from the draft twin. That fallback is what makes the probe unambiguous rather
// than merely suggestive.
const docGetDraftProbePerspective = "drafts"

// emitDocGetDraftPerspective turns `bp doc get <type> <id>`'s bare not_found into
// a statement about WHICH LENS answered, when — and only when — a one-request
// probe PROVES the document exists as a draft.
//
// THE DEFECT. `bp doc get` reads the PUBLISHED perspective by default, and
// QueryController.show keeps an exact-id lookup there, so an id whose only row
// is `drafts.<id>` answers 404. The server annotates that 404 with its own hint
// — "Check the document _id, type, and dataset in the URL — the resource does
// not exist in this scope" — which is the worst possible sentence for this case:
// the id is right, the type is right, the dataset is right, and the resource
// DOES exist. Measured live against guerrilla.barkpark.cloud on 2026-09-11:
// `bp doc get task gh-6292` 404s with exactly that hint while
// `bp doc get task gh-6292 --perspective drafts` returns the row; 761 of the
// 9,079 task rows on that ledger are draft-only. A verification lane in wave 33
// spent its initial conclusion on this — it read "does this draft exist?" as
// answered "no".
//
// WHY THIS IS NOT A HINT. The hint slot cannot carry it. `apiError.hint()`
// prefers the SERVER's hint over any locally derived one, pinned by
// TestServerHintOutranksTheDerivedHint, and doc.get is one of the routes that
// always sends a server hint — so a localHint from notFoundHint's seam would be
// computed and then discarded. This is therefore an ADVISORY on stderr, the
// same shape as emitMutatePerspective and emitClaimLease: it never changes the
// exit code, never touches stdout, and so leaves `-o json` byte-identical.
//
// WHY IT IS NOT A GUESS. The advisory is printed only after a read that
// RETURNED THE ROW. A 404 on the probe, a transport error, a server that does
// not declare --perspective, or any non-2xx status all print nothing — silence
// here means "not established", never "no draft exists".
//
// WHAT IT COSTS. One extra GET, paid only on a 404 from this one command with
// no explicit --perspective. Every success, every other status, every other
// command and every caller who already chose a lens pays nothing.
func emitDocGetDraftPerspective(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, status int) {
	if !docGetDraftProbeApplies(cmd, tail, status) {
		return
	}
	if m == nil {
		return
	}
	if !commandDeclaresFlag(cmd, "perspective") {
		// An older server with no perspective flag cannot be asked the
		// question, and inventing the remedy would name a flag it would refuse.
		return
	}
	typeName, id, ok := docGetArgs(cmd, tail)
	if !ok {
		return
	}

	// Headless dispatch on the command's OWN route with the caller's OWN
	// credentials — never a hand-rolled URL. g.yes because the prod
	// write-guard lives in runCommand (this is a GET regardless), and --dry-run
	// cleared so a previewed dry run still asks rather than asking nothing.
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false

	probe := []string{typeName, id, "--perspective", docGetDraftProbePerspective}
	probeStatus, _, err := execManifestCommand(lg, ctx, m, cmd, probe)
	if err != nil || probeStatus < 200 || probeStatus >= 300 {
		return
	}

	out.errf("bp: %s `%s` EXISTS as a draft (`drafts.%s`) — this not_found is the PUBLISHED perspective answering, not the document being absent. `bp doc get` reads `--perspective published` by default; re-run with `--perspective %s` (or `raw`) to read it%s.",
		typeName, id, id, docGetDraftProbePerspective, docGetDraftTaskClause(typeName, id))
}

// docGetDraftTaskClause adds the task-specific remedy, and only for a task: `bp
// task get` reads /v1/tasks, which has no perspective at all and resolves the
// bare id against both lenses. Naming it for a `paper` or a `post` would be a
// command that cannot read the row.
func docGetDraftTaskClause(typeName, id string) string {
	if typeName != "task" {
		return ""
	}
	return ", or `bp task get " + id + "` which resolves the bare id across both lenses"
}

// docGetDraftProbeApplies is the cheap gate: every condition that can be decided
// WITHOUT a request. Split out so a test can pin the no-network arms
// individually.
func docGetDraftProbeApplies(cmd manifest.Command, tail []string, status int) bool {
	if cmd.ID != docGetCommandID || status != 404 {
		return false
	}
	_, flags, err := splitArgs(cmd, tail)
	if err != nil {
		return false
	}
	if len(flags["perspective"]) > 0 {
		// The caller already chose a lens. A 404 under an EXPLICIT
		// `--perspective drafts` is a real absence, and re-probing the lens
		// they named would tell them what they already asked.
		return false
	}
	return true
}

// docGetArgs recovers the (type, doc_id) positionals `doc get` bound, or ok=false
// when the command bound neither. It reads the same bindArgs shape the request
// builder did rather than re-scanning tail, so a flag VALUE can never be
// mistaken for the id.
//
// A `drafts.`-prefixed id is refused: that caller already addressed the draft
// lens by hand, so the published perspective is not what surprised them.
func docGetArgs(cmd manifest.Command, tail []string) (string, string, bool) {
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return "", "", false
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return "", "", false
	}
	typeName, id := args["type"], args["doc_id"]
	if typeName == "" || id == "" {
		return "", "", false
	}
	if strings.HasPrefix(id, "drafts.") {
		return "", "", false
	}
	return typeName, id, true
}
