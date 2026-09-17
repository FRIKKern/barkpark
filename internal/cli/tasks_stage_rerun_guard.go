package cli

// tasks_stage_rerun_guard.go — the ORPHANED-RERUN pre-flight for
// `bp task stage --note … --supersede`, beside the other client-side write
// gates in run.go (the prod write-guard, the destroy confirm, the discard-draft
// twin guard, the three claim-wall pre-flights).
//
// ── THE DEFECT, REPRODUCED LIVE ON guerrilla 2026-09-17 (task-5509618e1868d9f2)
//
// `content.disposition_rerun` is the FOURTH durable adjudication key: ONE
// command an auditor can run to try to prove the row's `disposition_reason`
// WRONG. It is written by `bp task stage --rerun`, and the raw
// `/v1/data/mutate` door refuses the key by name so the verb's falsifiability
// screen cannot be bypassed.
//
// `--note` and `--rerun` are SEPARATE OPTIONAL FLAGS ON THE SAME CALL. So a
// stage that replaces the reason on purpose — `--note <new> --supersede` — and
// says nothing about the rerun leaves the rerun BYTE-IDENTICAL, still bound to
// a reason that no longer exists. Measured on a scratch row:
//
//	$ bp task stage <row> open --note 'REASON A: tasks_adjudication.go exists
//	  on origin/main, so the vocabulary screen ships.' --yes
//	reason: 'REASON A: …'
//	rerun : 'git cat-file -e origin/main:internal/cli/tasks_adjudication.go'
//
//	$ bp task stage <row> open --note 'REASON C: THE RULING — pick it up.
//	  Nothing here turns on any file or symbol.' --supersede --yes
//	exit=0
//	reason: 'REASON C: THE RULING — pick it up. …'
//	rerun : 'git cat-file -e origin/main:internal/cli/tasks_adjudication.go'
//
// The row now presents a GREEN, RECENT, SYMBOL-SPECIFIC probe for a claim it no
// longer makes. That is worse than carrying no rerun at all: an absent rerun is
// an honest "this reason refuses to be checked", while an orphaned one is a
// check that passes about something nobody asserted. The filing measured 136
// such rows across the ledger, 125 of them minted by exactly this call shape.
//
// ── WHY THE OVERRIDE IS ITS OWN FLAG AND NEVER --supersede
//
// The codebase's own reason, at check_instruction_supersession: "Two slots with
// one key to both locks is one slot wearing a costume." `--supersede` is the
// caller saying they read the REASON they are replacing. It is not them saying
// they read the rerun. So the opt-in here is a SEPARATE flag, --keep-rerun, and
// the ways past this gate are exactly the two that leave the row honest:
//
//	--rerun '<new probe>'   re-bind the rerun to the reason you are writing
//	--keep-rerun            state that the EXISTING rerun still binds the new
//	                        reason (the shared-rerun shape PDS-D391b(b) and
//	                        PDS-D336(a) rule honest, and which the measurement
//	                        agrees is the majority case)
//
// A THIRD way out — REMOVING the rerun outright — does not exist yet, at any
// door: `--rerun ''` is a no-op ("blank counts as absent"), and
// `/v1/data/mutate` refuses `disposition_rerun: null` by name. That is the
// SERVER half of task-5509618e1868d9f2 (`--clear-rerun` / `:clear_rerun` in
// api/lib/barkpark/tasks/stage.ex) and it is outside this fence. Until it
// lands, a reason that is a pure ruling can only be made honest by
// --keep-rerun'ing a probe that does not bind it, which is why this guard SAYS
// so in the refusal rather than pretending the removal exists.
//
// ── WHAT IT DELIBERATELY DOES NOT DO
//
// No distinctness refusal on this field, ever: PDS-D391b(b) and PDS-D336(a)
// rule a SHARED rerun over distinct rows the honest shape, --rerun's own help
// says so, and the filing measured that such a refusal would have refused 191
// correct writes.
//
// ── THE QUIET ARMS (no refusal, and for most of them no network work at all)
//
//   - no --note, or a blank --note           -> nothing is displaced
//   - no --supersede                         -> the SERVER already refuses a
//     displacing note (409 note_would_supersede), so a gate here would have no
//     subject; a same-text re-stage is not a displacement either
//   - --rerun on the same call               -> the rerun is being re-bound
//   - --keep-rerun                           -> stated on purpose
//   - row carries no rerun / a blank one     -> nothing to orphan
//   - row's existing reason is blank/absent  -> nothing is being displaced
//   - row's existing reason == the new note  -> not a replacement
//
// ── FAIL OPEN, AND SAY SO
//
// A probe that cannot read the row answers UNKNOWN, and UNKNOWN proceeds with
// one line on stderr. This is the claimed-draft-patch guard's direction, not the
// publish wall's, and the difference is blast radius: refusing here would block
// an adjudication write that destroys nothing the ledger cannot recover (every
// stage emits a task.staged event carrying the superseded note in full), while
// refusing every --supersede under a read hiccup would stall the one verb the
// fleet adjudicates with. What it must never do is assert "this row has no
// rerun" about a row it never read, so UNKNOWN gets its own sentence.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// taskStageCommandID keys the guard on the manifest command ID, not on the
// noun/verb spelling, so a server that renames the verb cannot silently un-gate
// it (the destroyTargets registry's rule, and docPatchCommandID's).
const taskStageCommandID = "task.stage"

// stageKeepRerunFlag is the deliberate-keep opt-in. Named for the act, not for
// its volume: --force says nothing, --keep-rerun says the existing probe still
// binds the reason you are about to write.
const stageKeepRerunFlag = "--keep-rerun"

// stageRerunOrphanCode is the refusal's named error code, shaped like the
// server's own adjudication refusals (note_would_supersede,
// instruction_would_supersede, unfalsifiable_rerun) so a caller that parses
// codes reads one vocabulary whether the refusal came from here or from the
// verb's write seam.
const stageRerunOrphanCode = "rerun_would_orphan"

// stageKeepRerunBodyKey is what the flag becomes on the wire. The server reads
// BOTH "keep_rerun" and "keep-rerun" (Params.stage_keep_rerun); the snake form
// is sent because that is the spelling the door documents.
const stageKeepRerunBodyKey = "keep_rerun"

// extractStageKeepRerunFlag removes every bare occurrence of stageKeepRerunFlag
// from tail and reports whether it was present. An inline `--keep-rerun=x` form
// is LEFT in tail so it falls through to splitArgs' ordinary unknown-flag
// refusal instead of succeeding on a typo — extractClaimedDraftPatchFlag's rule.
func extractStageKeepRerunFlag(tail []string) (bool, []string) {
	found := false
	kept := make([]string, 0, len(tail))
	for _, a := range tail {
		if a == stageKeepRerunFlag {
			found = true
			continue
		}
		kept = append(kept, a)
	}
	return found, kept
}

// stageKeepRerunFlagApplies keeps the strip scoped to `task stage`, and stands
// down for any server whose manifest already declares a flag of this name so
// the additive spelling can never shadow a real one.
func stageKeepRerunFlagApplies(cmd manifest.Command) bool {
	if cmd.ID != taskStageCommandID {
		return false
	}
	return !commandDeclaresFlag(cmd, strings.TrimPrefix(stageKeepRerunFlag, "--"))
}

// stageRerunArgs re-resolves cmd's positionals and flags so the guard asks about
// the same row the stage will write, re-running the PURE splitArgs/bindArgs
// exactly as claimedDraftPatchArgs does (buildManifestRequest must still run
// once and only once — it is the one that reads stdin).
//
// ok is false for every call that cannot orphan a rerun, so the guard costs
// nothing — not even a request — on a plain stage, a stage with no note, a
// stage that is not superseding, and a stage that re-binds the rerun itself.
func stageRerunArgs(cmd manifest.Command, tail []string) (docID, note, dataset string, ok bool) {
	if cmd.ID != taskStageCommandID {
		return "", "", "", false
	}
	pos, flags, err := splitArgs(cmd, tail)
	if err != nil {
		return "", "", "", false
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return "", "", "", false
	}
	docID = strings.TrimSpace(args["doc_id"])
	if docID == "" {
		return "", "", "", false
	}
	note = stageLastFlagValue(flags, "note")
	if strings.TrimSpace(note) == "" {
		// No note, or a blank one: nothing is displaced, so nothing is orphaned.
		return "", "", "", false
	}
	if stageLastFlagValue(flags, "supersede") != "true" {
		// Without --supersede the SERVER refuses a displacing note outright
		// (409 note_would_supersede) and accepts only a same-text re-stage,
		// which replaces nothing. A gate here would have no subject.
		return "", "", "", false
	}
	if strings.TrimSpace(stageLastFlagValue(flags, "rerun")) != "" {
		// The same call re-binds the rerun. That is the fix, not the defect.
		return "", "", "", false
	}
	return docID, note, strings.TrimSpace(stageLastFlagValue(flags, "dataset")), true
}

// stageLastFlagValue reads the LAST occurrence of a flag, matching splitArgs'
// own last-wins resolution for a non-repeatable flag; a bool flag reads as
// "true". It does NOT trim, unlike tasks_landed_cmd.go's lastFlagValue: the note
// is compared BYTE-FOR-BYTE against the reason already on the row, and a trimmed
// comparison would call a write that changes only leading whitespace a no-op.
func stageLastFlagValue(flags map[string][]string, name string) string {
	values := flags[name]
	if len(values) == 0 {
		return ""
	}
	return values[len(values)-1]
}

// stageRerunVerdict is the three-state answer. UNKNOWN is a state in its own
// right and never collapses into "no rerun" — that collapse would let the guard
// wave through a write on the strength of a row it never read.
type stageRerunVerdict int

const (
	stageRerunWouldOrphan stageRerunVerdict = iota
	stageRerunHarmless
	stageRerunUnknown
)

// stageAdjudicationFields is the slice of the task row this guard reads. The
// task doors render a row as {"doc":{"content":{…}}}; the generic document
// doors render content FLAT under {"result":{…}}. Both shapes are decoded so the
// guard keeps working if the probe is ever re-pointed at the other route.
type stageAdjudicationFields struct {
	Doc struct {
		Content map[string]any `json:"content"`
	} `json:"doc"`
	Content map[string]any `json:"content"`
}

// stageAdjudication pulls (reason, rerun) out of a probe response. ok=false
// means the body could not be read as a task row at all — the caller turns that
// into UNKNOWN rather than into "no rerun".
func stageAdjudication(body []byte) (reason, rerun string, ok bool) {
	var parsed stageAdjudicationFields
	if json.Unmarshal(body, &parsed) != nil {
		return "", "", false
	}
	content := parsed.Doc.Content
	if content == nil {
		content = parsed.Content
	}
	if content == nil {
		// The flat rendering: content fields sit beside the reserved keys.
		var flat map[string]any
		if json.Unmarshal(unwrapResult(body), &flat) != nil {
			return "", "", false
		}
		if _, isTask := flat["_id"]; !isTask {
			if _, hasReason := flat["disposition_reason"]; !hasReason {
				if _, hasRerun := flat["disposition_rerun"]; !hasRerun {
					return "", "", false
				}
			}
		}
		content = flat
	}
	reason, _ = content["disposition_reason"].(string)
	rerun, _ = content["disposition_rerun"].(string)
	return reason, rerun, true
}

// probeStageRerun asks whether writing `note` over this row's reason would strand
// its rerun, using the command's own sibling read on the same route with the
// same credentials — never a hand-rolled URL, the discard guard's rule.
func probeStageRerun(g globals, ctx manifest.Context, m *manifest.Manifest, docID, note, dataset string) (stageRerunVerdict, string, string) {
	get, ok := m.Tree().Lookup("task", "get")
	if !ok {
		return stageRerunUnknown, "this server declares no `bp task get`, so the row could not be read", ""
	}

	tail := []string{docID}
	if dataset != "" && commandDeclaresFlag(*get, "dataset") {
		tail = append(tail, "--dataset", dataset)
	}

	// Headless dispatch, exactly as probePublishedClaim does it: no rendering,
	// no guards, no stdout; --yes so the prod write-guard cannot prompt on what
	// is a GET either way, and --dry-run cleared so a previewed dry run still
	// performs the check rather than checking nothing.
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false

	status, body, err := execManifestCommand(lg, ctx, m, *get, tail)
	switch {
	case err != nil:
		return stageRerunUnknown, "the check never reached the server (" + err.Error() + ")", ""
	case status/100 != 2:
		return stageRerunUnknown, fmt.Sprintf("the check answered HTTP %d", status), ""
	}

	reason, rerun, readable := stageAdjudication(body)
	if !readable {
		return stageRerunUnknown, "the row came back in a shape this check could not read", ""
	}
	if strings.TrimSpace(rerun) == "" {
		// Nothing to orphan.
		return stageRerunHarmless, "", ""
	}
	if strings.TrimSpace(reason) == "" {
		// The reason is being SET, not displaced: the rerun was already
		// unbound before this call and this write does not make it so.
		return stageRerunHarmless, "", ""
	}
	if reason == note {
		// A re-stage with the SAME text replaces nothing.
		return stageRerunHarmless, "", ""
	}
	return stageRerunWouldOrphan, "", rerun
}

// stageRerunOrphanRefusal is the refusal text. Built here, not inline, so the
// test asserts on the same sentence the operator reads. The rerun is quoted IN
// FULL — the whole point is that the caller reads the probe before deciding
// whether it still binds, and a truncated command cannot be judged.
func stageRerunOrphanRefusal(docID, rerun string) string {
	return fmt.Sprintf(
		"refusing to supersede the disposition_reason on %s: the row carries a disposition_rerun this call says nothing about, and replacing the reason under it would leave a GREEN, RECENT, SYMBOL-SPECIFIC probe attached to a claim the row no longer makes.\n"+
			"  the rerun that would be stranded, in full:\n"+
			"    %s\n"+
			"  --supersede is you saying you read the REASON you are replacing; it is not you saying you read the rerun. Two slots with one key to both locks is one slot wearing a costume. So pick one, on purpose:\n"+
			"    --rerun '<command>'   re-bind the probe to the reason you are writing\n"+
			"    %s          the EXISTING probe still binds the new reason (a SHARED rerun over distinct rows is the honest shape — PDS-D391b(b), PDS-D336(a) — and is never refused here)\n"+
			"  REMOVING a rerun is not possible at any door yet: `--rerun ''` is a no-op (blank counts as absent) and /v1/data/mutate refuses disposition_rerun by name. That is the server half of task-5509618e1868d9f2 (--clear-rerun in api/lib/barkpark/tasks/stage.ex); until it lands, a reason that is a pure ruling can only be recorded with %s.\n"+
			"  nothing was written — the row's reason and rerun are byte-identical.",
		docID, rerun, stageKeepRerunFlag, stageKeepRerunFlag)
}

// guardStageRerunOrphan gates one `bp task stage`. It reports refused=true with
// the exit code the caller must return WITHOUT sending; refused=false lets the
// stage proceed unchanged. It is a no-op — and does no network work — for every
// call that cannot orphan a rerun.
//
// @canonical capability:stage-rerun-orphan-guard aka:rerun_would_orphan,disposition_rerun,--keep-rerun,--clear-rerun,orphaned rerun,bp task stage --supersede
func guardStageRerunOrphan(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, keepRerun bool) (int, bool) {
	docID, note, dataset, ok := stageRerunArgs(cmd, tail)
	if !ok {
		return exitOK, false
	}

	switch verdict, why, rerun := probeStageRerun(g, ctx, m, docID, note, dataset); verdict {
	case stageRerunHarmless:
		return exitOK, false

	case stageRerunWouldOrphan:
		if keepRerun {
			// The preview guarantee the destroy gate established: say what the
			// write will and will not do before doing it. Reachable only once
			// the probe has PROVEN the rerun, so this sentence is a measurement.
			out.errf("%s: the reason is being replaced and the existing disposition_rerun is being KEPT on purpose (%s was given) — it must still bind the new reason:\n    %s",
				docID, stageKeepRerunFlag, rerun)
			return exitOK, false
		}
		return useError(out, stageRerunOrphanCode, stageRerunOrphanRefusal(docID, rerun), exitValidation), true

	default:
		// UNKNOWN fails OPEN. Refusing on a read hiccup would stall the one verb
		// the fleet adjudicates with, and this write destroys nothing the ledger
		// cannot recover (the superseded note rides the task.staged event in
		// full). What it must not do is assert an absence it never measured, so
		// the unknown gets its own sentence.
		out.errf("could not check whether %s carries a disposition_rerun this supersede would strand — %s. Proceeding; if it does, re-bind it with `bp task stage %s <state> --rerun '<command>'` or state that it still binds with %s.",
			docID, why, docID, stageKeepRerunFlag)
		return exitOK, false
	}
}

// ── FORWARDING THE FLAG (task-4d5a2dde8a02d057) ──────────────────────────────
//
// The strip above exists so splitArgs never sees --keep-rerun. For as long as
// the refusal lived only HERE that was the whole story: the flag opened a
// client-side gate and had no business on the wire.
//
// PR #18817 changed the world. `POST /v1/tasks/:doc_id/stage` now refuses the
// same shape itself — 409 rerun_would_orphan — and honours three overrides of
// its own: `rerun` (re-bind), `clear_rerun` (subtract), `keep_rerun` (carry the
// existing probe forward untouched). `clear-rerun` is DECLARED in the tasks
// manifest, so bp picks it up from /v1/capabilities and buildBody puts it on the
// wire with no Go change. `keep_rerun` is not declared, so after the strip the
// request left here BARE and the server refused the very call the operator
// reached for to get past the refusal.
//
// THE MANIFEST ROUTE WAS CONSIDERED AND REJECTED. Declaring `keep-rerun`
// alongside `clear-rerun` in api/lib/barkpark/plugins/tasks.ex would put it on
// the wire for free — and would flip stageKeepRerunFlagApplies to FALSE (it
// stands down for any manifest that declares a flag of this name, so an
// additive spelling can never shadow a real one). stageKeepRerun would then
// always read false, guardStageRerunOrphan would refuse locally, and the flag
// would be refused by the client before the server it was declared for ever saw
// it. The manifest route is a regression, not a fix. The fix is here: forward
// what the strip took.
//
// It is stamped onto the RESOLVED BODY rather than pushed back into tail, for
// the reason the strip exists in the first place — tail goes through splitArgs,
// which refuses any flag the manifest does not declare. Same seam
// execTaskNextWithPolicy uses for the MCP execution_policy_override, and it
// runs BEFORE the dry-run branch so `--dry-run` previews the byte the server
// will read.
func stampStageKeepRerun(req *manifestRequest) error {
	if req == nil {
		return nil
	}
	body := map[string]any{}
	if len(req.body) > 0 {
		if err := json.Unmarshal(req.body, &body); err != nil {
			return fmt.Errorf("decode task stage body: %w", err)
		}
	}
	body[stageKeepRerunBodyKey] = true
	encoded, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("encode %s: %w", stageKeepRerunFlag, err)
	}
	req.body = encoded
	if req.headers == nil {
		req.headers = map[string]string{}
	}
	req.headers["Content-Type"] = "application/json"
	return nil
}
