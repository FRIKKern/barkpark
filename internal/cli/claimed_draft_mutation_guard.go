package cli

// claimed_draft_mutation_guard.go is the CHOKE POINT onto the claim wall.
//
// claimed_draft_patch_guard.go closed one verb (`bp doc patch task
// drafts.<id>`). claimed_restore_revision_guard.go closed a second
// (`bp doc restore-revision <rev_id> task`). Both are keyed on the command's
// POSITIONAL ARGUMENTS, and that is the shape this file exists to stop
// repeating: task-7b13c4042bb0ab7c named four more doors, and one of them —
// `bp doc mutate` — DECLARES NO POSITIONAL ARGUMENTS AT ALL. Its whole payload
// is a `--file` batch, so an argument-keyed guard cannot see it, and a fourth,
// fifth and sixth hand-placed call site is how one of them drifts.
//
// ── THE CHOKE POINT, MEASURED (bp --dry-run against guerrilla, 2026-09-16)
//
// Six draft-writing verbs resolve to ONE route with ONE body shape:
//
//	doc patch task drafts.X --set title=T
//	  POST /v1/data/mutate/:dataset
//	  {"mutations":[{"patch":{"id":"drafts.X","set":{"title":"T"},"type":"task"}}]}
//	doc create task --set _id=drafts.X --set title=T
//	  {"mutations":[{"create":{"_id":"drafts.X","title":"T","type":"task"}}]}
//	doc create-or-replace …
//	  {"mutations":[{"createOrReplace":{"_id":"drafts.X",…,"type":"task"}}]}
//	doc create-if-not-exists …
//	  {"mutations":[{"createIfNotExists":{"_id":"drafts.X",…,"type":"task"}}]}
//	doc mutate --file batch.json
//	  the batch VERBATIM — any of the above, any number of them, one request
//
// So the claim question does not need to be asked once per verb. It needs to
// be asked once, on the RESOLVED REQUEST — `buildManifestRequest`'s output,
// the one object every CLI dispatch and every headless MCP dispatch passes
// through. That is what this file guards, and it is why it is keyed on the
// HTTP METHOD and the body's SHAPE rather than on any command id: a seventh
// verb that lands draft bytes through this route is covered the day it ships,
// with no code change here.
//
// ── THE FOUR DOORS, REPRODUCED LIVE ON guerrilla 2026-09-16
//
// Probe row task-f74742b835867f8d, published, then claimed by
// "w55-probe-holder" at epoch 1 (created, released and deleted by the
// reporter). Each door was run against a build of origin/main:
//
//	$ bp doc create-or-replace task --set _id=drafts.task-f74742b835867f8d …--yes
//	DRAFT created (drafts.task-f74742b835867f8d): the published row is UNCHANGED
//	until you run `bp doc publish task task-f74742b835867f8d`
//	rev: d6ed8f82b88a65037938719e710700ee
//	$ bp doc create               … -> DRAFT created, rev: 64a8064da9a71b17d944afe41dbf83a1
//	$ bp doc create-if-not-exists … -> DRAFT created, rev: 2c4240b5e201eac13e76d78a693f659d
//
//	$ bp doc mutate --file '{"mutations":[{"createOrReplace":{"_id":"drafts.task-f74742b835867f8d",…}}]}' --yes
//	DRAFT created (drafts.task-f74742b835867f8d) …
//	rev: 24a22013777b696eef2801917fe9fed7
//	$ bp doc mutate --file '{"mutations":[{"patch":{"id":"drafts.task-f74742b835867f8d",…}}]}' --yes
//	DRAFT updated (drafts.task-f74742b835867f8d) …
//	rev: fde0ae423714f59da75bbe70d65e0b4f
//
//	$ bp doc get task drafts.task-f74742b835867f8d -o json | jq -c '{claim}'
//	{"claim":null}
//
//	$ bp doc publish task task-f74742b835867f8d --yes
//	bp: task content failed validation
//	  claim: stale draft: the published row carries claim state (worker
//	  "w55-probe-holder", epoch 1) this draft does not — publishing would
//	  obliterate it.
//
// All four landed. The mutate door landed TWICE — a `createOrReplace` op mints
// the twin and a `patch` op then edits it, both inside a batch body no
// positional guard can read. The trap is the patch door's exactly: the write
// is accepted, its result can never be published, and the receipt names the
// doomed publish as the next step.
//
// ── THE PREDICATE, NOT A LIST
//
// Nine of the ten `writes:true` doc commands share this route, and four of
// them must NOT be caught here — measured, same session:
//
//	doc publish        {"mutations":[{"publish":{"id":"task-X","type":"task"}}]}
//	doc unpublish      {"mutations":[{"unpublish":{"id":"task-X","type":"task"}}]}
//	doc delete         {"mutations":[{"delete":{"id":"task-X","type":"task"}}]}
//	doc discard-draft  {"mutations":[{"discardDraft":{"id":"task-X","type":"task"}}]}
//
// They are excluded by TWO independent fences, neither of which is a list of
// verb names (an enumeration is a snapshot; a predicate is a rule):
//
//  1. the id they name is BARE, not `drafts.`-prefixed — there is no draft twin
//     in the request at all; and
//  2. the op object carries NOTHING beyond its addressing keys, so it lands no
//     bytes on a draft. An op whose payload is empty cannot mint the
//     claim-less twin the publish wall refuses.
//
// Either fence alone excludes all four today. Requiring both is what makes a
// future addressing-only verb (a `deleteIfExists`, say) excluded without an
// edit, while a future CONTENT-landing verb is caught without one.
//
// ── WHAT IT DELIBERATELY DOES NOT DO
//
// It asks the claim question through probePublishedClaim
// (claimed_draft_patch_guard.go) — the single place that question is asked for
// every door — so there is still exactly ONE published-perspective read, one
// three-state verdict, and one definition of "claimed" in the CLI.
//
// It does not replace the two argument-keyed guards. They run FIRST and carry
// refusal wording written for their verb (`doc patch`'s names the
// discard-then-bare-patch sequence; `doc restore-revision`'s explains the fork
// it would create). This one is the backstop underneath them: if either call
// site is ever dropped, the write still does not go out.
//
// It never fires on a GET. The probe it issues is itself a GET, so the whole
// gate is provably send-free — a test drives the real runCommand against a
// recording fake and asserts no non-GET request reached the server.
//
// ── THE NEXT DOOR
//
// A verb that lands draft bytes through a DIFFERENT route escapes this file,
// exactly as `doc restore-revision` does today. That is not left to be
// noticed: claimed_draft_route_census_test.go enumerates every `writes:true`
// doc command in the live capabilities fixture, derives its route, and refuses
// any route that is neither this choke point nor an explicitly guarded
// exception. A seventh door on a new route reds that test on the day the
// manifest grows it, rather than becoming the next row.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// claimedDraftMutationFlag is the deliberate-write opt-in for the doors this
// choke point covers that have no opt-in of their own (the create family and
// `doc mutate`). Named for the act, and deliberately NOT the global --yes —
// --yes is the prod write-guard's answer and is set in every CI script, so it
// cannot also mean "I know this draft can never be published".
const claimedDraftMutationFlag = "--write-claimed-draft"

// mutationBatchType is the document type this guard is about. The claim wall
// (api/lib/barkpark/content/lifecycle.ex) compares claim blocks only for task
// content, so a draft twin of any other type publishes fine and gating it
// would be a guard with no subject.
const mutationBatchType = "task"

// mutationAddressingKeys are the keys that ADDRESS a mutation op rather than
// carry payload for it. An op whose object holds nothing else lands no bytes
// on the document it names — it publishes, unpublishes, deletes or discards it
// — so it can never mint the claim-less twin the publish wall refuses.
//
// `ifRevisionID` is addressing too: it is an optimistic-concurrency assertion
// about the base revision, not content.
var mutationAddressingKeys = map[string]bool{
	"_id":          true,
	"id":           true,
	"_type":        true,
	"type":         true,
	"ifRevisionID": true,
	"ifRevisionId": true,
}

// mutationBatch is the slice of the resolved request body this guard reads:
// the `mutations` array every door on POST /v1/data/mutate/:dataset carries,
// plus the optional batch-level `type` that `doc mutate` accepts as a default
// for ops that do not state their own.
type mutationBatch struct {
	Mutations []map[string]json.RawMessage `json:"mutations"`
	Type      string                       `json:"type"`
}

// draftTaskTargets reports the BARE published ids of every `type:task` draft
// twin this request body would land bytes on, in the order the batch names
// them and without repeats.
//
// It returns nil — never a guess — for a body that is not a mutation batch,
// so a request through any other route costs nothing.
func draftTaskTargets(body []byte) []string {
	var batch mutationBatch
	if json.Unmarshal(body, &batch) != nil || len(batch.Mutations) == 0 {
		return nil
	}

	seen := map[string]bool{}
	var out []string
	for _, op := range batch.Mutations {
		for _, raw := range op {
			var obj map[string]json.RawMessage
			if json.Unmarshal(raw, &obj) != nil {
				continue
			}
			id, ok := mutationOpTarget(obj, batch.Type)
			if !ok || seen[id] {
				continue
			}
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// mutationOpTarget applies the two fences to ONE mutation op object and reports
// the bare published id it would write a draft twin of. batchType is the
// batch-level default for an op that states no `type` of its own.
//
// ok=false for every op that is not a payload-carrying write onto a
// `drafts.`-prefixed task id.
func mutationOpTarget(obj map[string]json.RawMessage, batchType string) (string, bool) {
	typ := mutationJSONString(obj["type"])
	if typ == "" {
		typ = mutationJSONString(obj["_type"])
	}
	if typ == "" {
		typ = batchType
	}
	if typ != mutationBatchType {
		return "", false
	}

	id := mutationJSONString(obj["_id"])
	if id == "" {
		id = mutationJSONString(obj["id"])
	}
	if !strings.HasPrefix(id, draftIDPrefix) {
		return "", false
	}
	bare := strings.TrimPrefix(id, draftIDPrefix)
	if bare == "" {
		return "", false
	}

	// FENCE TWO: an op with no payload beyond its addressing keys lands no
	// bytes, so it cannot mint an unpublishable twin.
	payload := false
	for k := range obj {
		if !mutationAddressingKeys[k] {
			payload = true
			break
		}
	}
	if !payload {
		return "", false
	}
	return bare, true
}

// mutationJSONString decodes raw as a JSON string, answering "" for absent, null, or
// any non-string value. It never guesses a value out of a shape it could not
// read — an unreadable id is simply not a target this guard claims to know
// about.
func mutationJSONString(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return ""
	}
	return strings.TrimSpace(s)
}

// extractClaimedDraftMutationFlag removes every bare occurrence of
// claimedDraftMutationFlag from tail and reports whether it was present. An
// inline `--write-claimed-draft=x` form is left in tail so it falls through to
// splitArgs' ordinary unknown-flag refusal instead of succeeding on a typo —
// extractClaimedDraftPatchFlag's rule.
func extractClaimedDraftMutationFlag(tail []string) (bool, []string) {
	found := false
	kept := make([]string, 0, len(tail))
	for _, a := range tail {
		if a == claimedDraftMutationFlag {
			found = true
			continue
		}
		kept = append(kept, a)
	}
	return found, kept
}

// claimedDraftMutationFlagApplies reports whether claimedDraftMutationFlag
// should be stripped from this command's tail before splitArgs sees it.
//
// Keyed on SHAPE, not on a list of command ids — the whole point of this file.
// A write command is one that could reach the choke point; a command whose
// manifest already DECLARES a flag of this name keeps its own meaning, so the
// opt-in can never shadow a real server-declared flag.
func claimedDraftMutationFlagApplies(cmd manifest.Command) bool {
	if !cmd.Writes {
		return false
	}
	return !commandDeclaresFlag(cmd, strings.TrimPrefix(claimedDraftMutationFlag, "--"))
}

// claimedDraftMutationRefusal is the refusal text. Built here, not inline, so
// the test can assert on the same sentence the operator reads.
func claimedDraftMutationRefusal(verb, bareID, worker string, epoch int) string {
	return fmt.Sprintf(
		"refusing to write drafts.%s: the published row is CLAIMED (worker %q, epoch %d), so the draft this %s would land on can never be published — the publish wall refuses a draft that does not carry the published row's claim block (\"stale draft: … publishing would obliterate it\"), and no later edit can add it, because once the twin exists the bare-id patch is refused too by the draft-twin fork fence. The write is not destructive; it is unlandable, forever. To land content on this row AND keep the claim: `bp doc discard-draft task %s` (if a twin already exists) then `bp doc patch task %s --set …` — a bare-id task patch is published-first, so it edits the published row in place and leaves worker/epoch untouched. To park the draft anyway, re-run with %s.",
		bareID, worker, epoch, verb, bareID, bareID, claimedDraftMutationFlag)
}

// guardClaimedDraftMutation gates ONE resolved request, whatever verb produced
// it. It reports refused=true with the exit code the caller must return WITHOUT
// sending; refused=false lets the request proceed unchanged.
//
// It does no network work at all — not one request — for a GET, for a body
// that is not a mutation batch, and for a batch that names no payload-carrying
// `drafts.`-prefixed task id. That is the quiet arm, and it is the common case.
func guardClaimedDraftMutation(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, req *manifestRequest, deliberate bool) (int, bool) {
	if req == nil || strings.EqualFold(req.method, "GET") || len(req.body) == 0 {
		return exitOK, false
	}
	targets := draftTaskTargets(req.body)
	if len(targets) == 0 {
		return exitOK, false
	}

	verb := strings.TrimSpace(cmd.Noun + " " + cmd.Verb)
	if verb == "" {
		verb = "write"
	}

	for _, bareID := range targets {
		switch verdict, why, worker, epoch := probePublishedClaim(g, ctx, m, bareID); verdict {
		case publishedClaimFree:
			continue

		case publishedClaimHeld:
			if deliberate {
				// The preview guarantee the destroy gate established: say what the
				// write will and will not do before doing it. Reachable only once
				// the probe has PROVEN the claim, so this sentence is a
				// measurement, never a warning about a row nobody read.
				out.errf("drafts.%s is the twin of a CLAIMED row (worker %q, epoch %d) — this write stays on the draft and `bp doc publish task %s` will refuse it (%s was given).",
					bareID, worker, epoch, bareID, claimedDraftMutationFlag)
				continue
			}
			return useError(out, "claimed_draft_mutation", claimedDraftMutationRefusal(verb, bareID, worker, epoch), exitValidation), true

		default:
			// UNKNOWN fails OPEN, the patch guard's rule and for its reason: this
			// write destroys nothing, so refusing on a read hiccup would block a
			// harmless edit. What it must never do is assert an absence it never
			// measured, so the unknown gets its own sentence rather than silence.
			out.errf("could not check whether the published row task %s is claimed — %s. Proceeding; if it IS claimed, `bp doc publish task %s` will refuse this draft and the way to land the edit is `bp doc discard-draft task %s` then a bare-id `bp doc patch task %s`.",
				bareID, why, bareID, bareID, bareID)
		}
	}
	return exitOK, false
}
