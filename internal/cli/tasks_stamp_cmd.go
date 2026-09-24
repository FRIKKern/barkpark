package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// runTaskStamp is the client-side ergonomic wrapper around the manifest
// `task stamp` verb. The verb's `--criterion N` is a ZERO-BASED index into
// acceptance_criteria, but `bp task get`, the rubric, the spawn prompts and
// every board render criteria as 1..N — so a builder who follows the visible
// numbering silently attaches evidence one slot late. On a task whose last row
// is the standard "[MERGE-GATED — the lead closes this]" criterion, stamping
// 1..N flips that lead-owned row before the PR exists (the live footgun that
// fabricated a done in wave 4). The server's D56 guard already REJECTS a
// mis-index whose `--criterion-text` does not match the row, but the raw
// 0-vs-1 base is still a trap. This wrapper does three CLI-only things the
// generic manifest dispatch cannot, and hands the actual POST to runCommand in
// between (so ALL of the dispatch/render/guard plumbing stays shared — zero
// drift):
//
//  1. ECHO — before sending, print one stderr line that TRANSLATES the 0-based
//     index to the 1-based position boards show ("index 3 (0-based) = criterion
//     #4 as boards/rubric number them") alongside the criterion text. A 0-vs-1
//     slip is then visible at the moment of the stamp, not only when the server
//     409s a text mismatch.
//
//  2. MERGE-GATE OVERRIDE PASS-THROUGH — `--merge-gated` is now a
//     SERVER-DECLARED flag, so the wrapper forwards it and the SERVER owns the
//     refusal (`Barkpark.Tasks.Criteria.merge_gated?/1`, 409
//     merge_gated_criterion). It used to be a CLI-only flag guarding a
//     CLI-only textual tripwire, and that could not be made correct here: the
//     authoritative signal is the STORED criterion's `merge_gate` field, which
//     this process cannot see — it has only the `--criterion-text` the caller
//     typed. Keeping the verdict client-side therefore mis-fired on rows whose
//     prose merely DISCUSSES merge-gating (65 of 1853 marker-bearing criteria
//     on the live corpus), missed rows flagged `merge_gate: true` whose prose
//     never says so (14), and was bypassed outright by a direct POST. Against
//     a server too old to declare the flag the OLD client-side tripwire still
//     runs — see `stampMergeGateFallback` — so a rollout never leaves the gate
//     unguarded in either direction.
//
//  3. READ-BACK (PDS-D359/PDS-D361, wave 26) — after a 2xx, RE-READ the criterion
//     from the store and render the receipt from what the store holds, never
//     from what was asked. The epic has watched this verb return exit 0 with a
//     normal envelope on a stamp that did not land (read-back: met:false,
//     evidence:""), and every acceptance criterion in the epic is written with
//     it. A stored row that disagrees exits exitConflict naming the index, the
//     expected text and what was found; a read-back that cannot reach the store
//     exits non-zero as UNCONFIRMED, because "we could not ask" is not "it
//     landed". The correct fix regardless of WHY a write is lost — a transport
//     ceiling, a holder gate, or a bad minute on the box.
//
//     The read-back also fires on a server-side 5xx (exitServer), not only a
//     2xx: the epic's own doctrine ("a 500 can hide a write that landed") means
//     an 8 is NOT proof the write is absent — the transaction can commit and the
//     response still fail after. Every OTHER non-2xx (auth/validation/not_found/
//     conflict/rate-limit) is the server refusing BEFORE any commit, so a
//     read-back there would just be noise on a row nothing touched — those still
//     return immediately, untouched, exactly as before.
//
// The base is deliberately NOT flipped to 1-based: that is a breaking change
// for every existing script AND for the MCP tools (mcp_tasks.go) that already
// pass 0-based indices, and the D56 text-match guard makes a silent misroute
// impossible anyway. Documented-0-based + a translating echo is the
// least-surprise, fully-backward-compatible fix.
func runTaskStamp(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	// THE OVERRIDE'S FLAG TYPE, not merely its presence. `--merge-gated` used to
	// be a bare boolean and is now a REASON-CARRYING string flag, so the wrapper
	// must route three worlds, not two: a current server declares it "string"
	// (flag + reason ride the POST), a server between the two changes declares
	// it "bool" (the reason cannot land there, so only the bare flag is
	// forwarded), and a server predating the server-side guard declares it not
	// at all (flag AND reason are stripped and the legacy tripwire runs).
	gatedType := commandFlagType(cmd, "merge-gated")
	declared := gatedType != ""

	// THE NON-EVALUATING DOOR (tasks_stamp_criterion_file.go). `--criterion-text-file
	// <path>` (or `-` for stdin) is resolved FIRST, into the inline
	// `--criterion-text=<bytes>` spelling, so every stage after this line —
	// parseStampArgs, the echo, splitArgs, the POST, the read-back — sees the
	// ordinary flag and can never drift from it. The wording therefore reaches
	// the server byte-for-byte off disk, with no shell anywhere in its path.
	fromFile := stampTextCameFromFile(tail)
	if stampStdinClaimedTwice(tail) {
		return useError(out, criterionTextSourceCode,
			"only ONE of "+criterionTextFileFlag+" and "+amendedCriterionFileFlag+" can read `-` (stdin) — there is one stdin; put the other text in a file",
			exitValidation)
	}
	tail, err := resolveCriterionTextFile(tail)
	if err != nil {
		return useError(out, criterionTextSourceCode, err.Error(), exitValidation)
	}
	// The amendment's REPLACEMENT wording rides the same kind of door, resolved
	// the same way into the inline `--amended-criterion=<bytes>` spelling
	// (tasks_stamp_amend_file.go) — the flag the manifest documents and no
	// parser implemented until task-f65368969b1a2471.
	tail, err = resolveAmendedCriterionFile(tail)
	if err != nil {
		return useError(out, amendedCriterionSourceCode, err.Error(), exitValidation)
	}

	sa, forward := parseStampArgs(tail, gatedType)

	// THE OVERRIDE NOW COSTS A SENTENCE (pds-bl-merge-gated-override-carries-no-reason).
	// A bare `--merge-gated` is refused BEFORE anything is sent. The flag is the
	// one escape from the merge-gate refusal, and while it was a bare boolean an
	// override cost one word and recorded nothing — so a reflex override and a
	// deliberate one were byte-identical on the record, and the guard's whole
	// strength was that a human read the refusal and stopped. Requiring a reason
	// LOOSENS NOTHING: every criterion the guard refuses today it still refuses,
	// and the escape now has to be a statement somebody signed.
	if sa.mergeGated && strings.TrimSpace(sa.mergeGatedReason) == "" {
		return useError(out, mergeGatedReasonCode, mergeGatedReasonMessage, exitValidation)
	}

	// THE MISS-FIELD REFUSAL, AND ITS POSITION IS THE POINT. A miss keeps its
	// reason in --note and NOWHERE ELSE: the server's parse_stamp `miss ->`
	// branch (api/lib/barkpark_web/controllers/tasks_controller/params.ex) reads
	// "note" and never looks at "evidence", and the miss write path
	// (api/lib/barkpark/tasks/internal.ex, apply_entry_update on an "attempt")
	// appends to `attempts` and leaves `evidence` untouched. So `--miss --note x
	// --evidence y` is not refused anywhere — it returns 2xx and DROPS y.
	// Measured on main: the note-less spelling WAS refused, but by the server,
	// i.e. after stampEchoLine had already printed "miss (attempt) — met is
	// UNCHANGED", a line that reads like the write is under way on a call that is
	// about to be refused. Both shapes are therefore refused HERE: before the
	// echo, before the pre-check reads, before anything is sent.
	if code, msg := stampMissFieldRefusal(sa); code != "" {
		return useError(out, code, msg, exitValidation)
	}

	// LEGACY-SERVER FALLBACK ONLY. When the server declares --merge-gated it
	// owns the verdict (it can read the stored `merge_gate` field; we cannot),
	// and the flag rides the POST. Against an older manifest the flag is not
	// declared — forwarding it would fail splitArgs as an unknown flag — so we
	// strip it and run the historical text-only tripwire, which is wrong at the
	// edges but strictly better than shipping the met-flip unguarded.
	if !declared && stampMergeGateFallback(sa) {
		return useError(out, "merge_gated_criterion",
			"refusing to stamp a MERGE-GATED criterion met: --criterion-text carries the MERGE-GATED marker, and that row is the lead's to close (a builder flipping it fabricates a done before the PR exists). Pass --merge-gated \"<why this stamp is yours to make>\" to override — it is an ASSERTION, not a permission: nothing checks that you are a lead, and the server cannot, because it authenticates your api_token and not the worker_id you typed. The override is RECORDED as an assertion (content.merge_gate_autostamp.stamp_overrides, carrying \"verified\": false, your asserted worker, and the token actually authenticated). (This server is too old to declare --merge-gated, so the match is on the TEXT you passed and may be a false positive on a criterion that merely MENTIONS merge-gating.)",
			exitValidation)
	}

	// THE DISCRIMINATION PRE-CHECK (task-33e42f188c491bbe). `--criterion-text`
	// is the off-by-one guard, and every scripted caller defeats it the same
	// way: it passes `crit[i]["criterion"]` READ BACK FROM THE ROW IT IS
	// STAMPING, so the confirmation matches whatever index it lands on, by
	// construction. Before the POST, ask the store what the row's criteria
	// actually are and refuse the one case the wire can PROVE is worthless: a
	// confirmation that byte-matches MORE THAN ONE index. Such a text cannot
	// name a criterion — it fits several equally well — so it confirms nothing
	// whichever index rides beside it, and the server's own match-at-index test
	// accepts it anyway.
	if rc := refuseNonDiscriminatingCriterionText(out, ctx, sa, cmd, forward); rc != exitOK {
		return rc
	}

	// THE OUT-OF-ROW PIN (task-f7b781a0bcd7f70b). Everything above this line is
	// validated against values READ FROM THE ROW BEING STAMPED, which is why an
	// off-by-one stamp scripted in the observed shape is wire-identical to a
	// correct one. `--expect '<index>:<first words>'` is typed by the AUTHOR
	// before the row is read, so a rotated index disagrees with it. Refused here
	// (before the POST) and checked again on the read-back — see
	// tasks_stamp_expect_pin.go.
	pin, rcPin := refuseMisalignedExpectPin(out, ctx, sa, cmd, forward)
	if rcPin != exitOK {
		return rcPin
	}

	// Echo the translated target so a 0-vs-1 base slip is visible immediately —
	// stderr, so a scripted caller's stdout stays byte-identical to the bare
	// manifest path (mirrors emitHelpHints).
	if line := stampEchoLine(sa); line != "" {
		out.errf("%s", line)
		// A flag nobody can discover is a flag nobody types, and the guard this
		// stamp IS using is the one the observed shape defeats.
		if adv := stampExpectAdvisory(sa); adv != "" {
			out.errf("%s", adv)
		}
	}

	// THE MACHINE RECEIPT (criterion 2 of this row). Under -o json the dispatch
	// writes the POST's envelope to stdout and the read-back verdict rides
	// progressf to STDERR — so a scripted caller parsing stdout reads `ok:true`
	// off the TRANSPORT while the read-back, which is the only thing that knows
	// whether the store holds the stamp, speaks on a stream it does not read.
	// Measured on main before this change: a stamp the store DROPPED printed
	// `{"ok":true}` on stdout and exited exitConflict. That is the same lie in
	// the same verb that this whole read-back exists to end, one stream over.
	// So under -o json the envelope is BUFFERED here, and stampCapture.flush
	// merges the verdict into it and lets the store, not the transport, own the
	// document's `ok`.
	cap := beginStampCapture(out, g, cmd)

	// Hand the real POST to the shared dispatch. Whether `forward` still carries
	// --merge-gated is CONDITIONAL and parseStampArgs owns the decision: when the
	// server DECLARES the flag it is forwarded like any other, because the server
	// enforces the gate and needs to see the override; only against a legacy
	// manifest that does not declare it is it stripped, since an undeclared token
	// fails splitArgs with "unknown flag". See the doc comment on parseStampArgs
	// and the fallback branch above.
	rc := runCommand(out, g, ctx, m, cmd, forward)

	// THE READ-BACK (PDS-D359/PDS-D361). A 2xx is not a landed write: the epic has
	// now watched this exact verb return exit 0 with a normal envelope on a
	// stamp the store did not hold. So after the POST, ASK THE STORE what the
	// row holds and render the verdict from THAT — for a clean 2xx (rc==exitOK)
	// AND for a server-side 5xx (rc==exitServer), because a 5xx is not proof the
	// write is absent either (the transaction can commit and the response still
	// fail — see the doc comment above). --dry-run sent nothing, and every OTHER
	// non-2xx (auth/validation/not_found/conflict/rate-limit) is the server
	// refusing BEFORE any commit, so both skip straight through untouched.
	if g.dryRun || (rc != exitOK && rc != exitServer) {
		// A fenced_off 409 is the ONE refusal whose cause the caller cannot see
		// from the message: the epoch did not go wrong, a pulse MOVED it. Read
		// the row back and name the epoch that is current now (tasks_lease.go).
		if rc == exitConflict && staleEpochReasons[out.lastErrorCode] {
			if req, ok := stampRequestOf(cmd, forward); ok {
				explainStaleEpoch(out, ctx, req.docID, req.worker)
			}
		}
		// A merge-gate refusal is the OTHER 409 whose cause the caller cannot see
		// from the message: the server's hint has to hedge ("IF THIS ROW IS NOT A
		// GATE, THE MATCH WAS ON ITS PROSE") because it speaks for every row at
		// once. The row itself settles it, so read it and say WHICH detector
		// fired (tasks_stamp_cmd.go's explainMergeGateDetector).
		if out.lastErrorCode == "merge_gated_criterion" {
			if req, ok := stampRequestOf(cmd, forward); ok {
				explainMergeGateDetector(out, ctx, req.docID, req.index)
			}
		}
		// A text mismatch is the THIRD refusal whose real cause the message can
		// hide. The server's hint names one candidate — an off-by-one index or a
		// changed list — and that is the WRONG place to look when the operator's
		// own shell executed a backticked code span in the wording before bp ever
		// saw it (the measured case on task-6576859f2c12a8e8). Name the second
		// cause, say whether THIS run was even capable of it, and hand over the
		// non-evaluating recipe.
		if criteriaMismatchReason(out.lastErrorCode) {
			explainCriteriaMismatch(out, sa.criterionText, fromFile)
		}
		return cap.flush(out, rc, nil)
	}
	req, ok := stampRequestOf(cmd, forward)
	req.pin = pin
	if !ok {
		// No usable --criterion index (the manifest dispatch has already
		// reported whatever was wrong with the invocation): there is no
		// specific row to re-read, so claim nothing extra about one.
		return cap.flush(out, rc, nil)
	}
	if rc == exitServer {
		out.errf("the stamp POST answered a server error (exit %d) — checking the store before trusting that as \"nothing landed\" (a 5xx can hide a write that already committed)", rc)
	}
	rc, receipt := confirmStampLanded(out, ctx, req, rc)
	return cap.flush(out, rc, receipt)
}

const (
	// mergeGatedReasonCode is the CLI-side error code for a bare
	// `--merge-gated`. It is CLI-side and not a server code on purpose: the
	// refusal is about the INVOCATION, which the wrapper can see whole, and
	// refusing here means the reflex override never leaves the machine. The
	// server refuses the reason-less spelling too (`merge_gated_reason_required`
	// out of `Params.stamp_merge_gated/1`), because a CLI-only guard is bypassed
	// by a direct POST — the same argument that moved the merge-gate verdict
	// itself onto the server.
	mergeGatedReasonCode = "merge_gated_reason_required"

	// mergeGatedReasonMessage names what to supply, in the spelling to type.
	mergeGatedReasonMessage = "refusing a bare --merge-gated: the override now takes a REASON. " +
		"It is the ONE flag that lets a --met flip a row the lead closes on merge, and while it was a bare " +
		"boolean it cost one word and recorded nothing — a reflex override and a deliberate one were " +
		"indistinguishable on the record, because the record was empty either way. " +
		"Supply why this stamp is yours to make: --merge-gated \"PR #123 merged to main as <sha>; " +
		"I am the lead closing the gate\". " +
		"The reason is PERSISTED beside the stamp (content.merge_gate_autostamp.stamp_overrides[].reason) " +
		"on the same write as the flip, the shape the close path's close_override.* records already use. " +
		"It is still an ASSERTION and not a permission — nothing checks that you are a lead — but it is now " +
		"an assertion somebody signed."
)

// stampReadbackRetryDelay is the whole budget of the stamp read-back's second
// look — the twin of closeClaimRecheckDelay, and short enough that an operator
// never notices it. A var so tests can drive both arms without sleeping.
var stampReadbackRetryDelay = 400 * time.Millisecond

// stampRequest is what the caller ASKED the ledger to write. It is the request
// half of the receipt and is NEVER the source of the verdict — renderStampVerdict
// prints from the STORED row and uses these fields only to say what was expected.
type stampRequest struct {
	docID    string
	worker   string
	index    int
	text     string
	met      bool
	evidence string
	miss     bool
	note     string
	// withdraw is the D745 lowering outcome: met goes FALSE, the evidence is
	// preserved, and a signed record lands on the criterion's withdrawals list.
	// It is confirmed by a DIFFERENT read-back shape than --met (see
	// stampMismatches): a withdrawal that "landed" while met is still true is
	// exactly the class of lie this verb exists to end.
	withdraw bool
	// amend / amended are the wording correction (#19930): the stored text at
	// index is REPLACED by amended. text is then the SUPERSEDED wording, so the
	// read-back confirms against amended instead (see stampMismatches).
	amend   bool
	amended string
	// pin is the author-typed `--expect` expectation, or nil. It is the ONE
	// field here the row cannot supply, which is why the read-back's alignment
	// check (stampMismatches) is keyed on it rather than on --criterion-text.
	// It is attached by runTaskStamp after stampRequestOf, because the flag is
	// stripped from the forwarded tail and stampRequestOf re-parses that tail.
	pin *stampPin
}

// stampRequestOf re-resolves the stamp invocation through the SAME splitArgs +
// bindArgs the dispatch used, so the doc id and flags the read-back targets can
// never drift from the ones the POST carried. It reports false when the tail
// carries no usable --criterion index (nothing specific to re-read) or when it
// does not parse — in which case runCommand has already reported the usage
// error and nothing was written.
func stampRequestOf(cmd manifest.Command, forward []string) (stampRequest, bool) {
	pos, flags, err := splitArgs(cmd, forward)
	if err != nil {
		return stampRequest{}, false
	}
	argMap, err := bindArgs(cmd, pos)
	if err != nil {
		return stampRequest{}, false
	}
	last := func(name string) string {
		v := flags[name]
		if len(v) == 0 {
			return ""
		}
		return v[len(v)-1]
	}
	idx, err := strconv.Atoi(strings.TrimSpace(last("criterion")))
	if err != nil {
		return stampRequest{}, false
	}
	docID := strings.TrimSpace(argMap["doc_id"])
	if docID == "" {
		return stampRequest{}, false
	}
	return stampRequest{
		docID:    docID,
		worker:   strings.TrimSpace(argMap["worker_id"]),
		index:    idx,
		text:     last("criterion-text"),
		met:      last("met") == "true",
		evidence: last("evidence"),
		miss:     last("miss") == "true",
		note:     last("note"),
		withdraw: last("withdraw") == "true",
		amend:    last("amend") == "true",
		amended:  last("amended-criterion"),
	}, true
}

// confirmStampLanded performs the second read and renders its verdict. A
// read-back that cannot reach the store is reported as UNCONFIRMED and exits
// non-zero: "we could not ask" is not "it landed", and this verb's whole job
// this wave is to stop claiming the difference away.
//
// origRC is the exit code the POST itself produced (exitOK on a clean 2xx,
// exitServer on a 5xx the caller decided to double-check). When the read-back
// CANNOT reach the store either, origRC is what survives: a 5xx that already
// named a specific server failure carries more information than the generic
// exitGeneric bucket, so it is kept rather than downgraded. Only a genuinely
// unclassified starting point (origRC == exitOK, meaning the POST itself gave
// no hint of trouble) falls back to exitGeneric.
func confirmStampLanded(out *writer, ctx manifest.Context, req stampRequest, origRC int) (int, map[string]any) {
	// taskReadbackClient (tasks_close_pulse_cmd.go) is the ONE constructor the
	// three ledger read-backs share, so stamp, close and pulse can never drift
	// into reading the store through differently-configured clients.
	//
	// A comment here used to assert that "the read-back always sees the row
	// `bp task stamp` wrote, which is the PUBLISHED one (PDS-D360)". That was
	// FALSE, and a run refuted it. The route falls back to the `drafts.` twin
	// when no published row exists (tasks_controller.ex find_task_by_doc_id),
	// and `bp task create --yes` produces exactly such a draft-only row at rc=0
	// — so on those rows there IS no published row to see. The read-back now
	// carries the answering row's identity and the verdict refuses a green when
	// a draft answered; see renderStampVerdict.
	stored, readback, err := taskboard.FetchCriterion(taskReadbackClient(ctx), req.docID, req.index)
	if err != nil {
		// ONE bounded second look, the twin of close's (closeClaimRecheckDelay).
		// The line this path used to print — "the write may or may not have
		// landed; re-read with `bp task get …` before trusting it" — is the
		// exact ambiguity this verb exists to remove, and it was reached
		// LIVE during a load spike by a read that lost a single race, not by a
		// store with no answer. Under LEDGER DIET the `bp task get` it told the
		// operator to run is also the expensive call (the unindexable children
		// walk) where this read fetches one criterion. So ask again, briefly,
		// before giving up on knowing.
		time.Sleep(stampReadbackRetryDelay)
		stored, readback, err = taskboard.FetchCriterion(taskReadbackClient(ctx), req.docID, req.index)
	}
	if err != nil {
		out.userErr("✗ NOT confirmed — the read-back of %s criterion index %d could not reach the store, twice: %v",
			req.docID, req.index, err)
		// NOT "may or may not have landed". The store is what "landed" means and
		// it did not answer, so the only safe reading is UNSTORED — and acting on
		// that reading is free, because a stamp that DID land is idempotent: the
		// same --met with the same --evidence re-writes the same row.
		out.errf("  treat this stamp as NOT stored and stamp again — a stamp that did land is idempotent (same --criterion, same --met/--evidence, same row), so re-stamping costs nothing and settles it")
		rc := exitGeneric
		if origRC != exitOK {
			rc = origRC
		}
		return rc, stampReceipt(req, taskboard.CriterionItem{}, apiclient.TaskReadback{},
			[]string{fmt.Sprintf("the read-back could not reach the store, twice: %v", err)}, false)
	}
	rc := renderStampVerdict(out, req, stored, readback, origRC)
	return rc, stampReceipt(req, stored, readback, stampVerdictProblems(req, stored, readback), rc == exitOK)
}

// stampVerdictProblems is renderStampVerdict's verdict as DATA, so the machine
// receipt and the human receipt can never disagree: both are computed from the
// same two pure predicates over the same stored row. A draft answer is listed
// first for the same reason renderStampVerdict checks it first — a value that
// landed somewhere no board reads is not a landed stamp.
func stampVerdictProblems(req stampRequest, stored taskboard.CriterionItem, readback apiclient.TaskReadback) []string {
	if readback.IsDraft() {
		return []string{fmt.Sprintf(
			"the stamp landed on a DRAFT, not the board — %s answered this read-back, so no board will ever show it",
			readbackRowLabel(readback))}
	}
	return stampMismatches(req, stored)
}

// stampReceipt is the machine half of the stamp's verdict: everything the
// receipt CLAIMS, read off the row the store handed back. `confirmed` is the
// single field a script should branch on and it is never the POST's status —
// it is true only when the read-back found the write the caller asked for on a
// published row.
func stampReceipt(req stampRequest, stored taskboard.CriterionItem, readback apiclient.TaskReadback, problems []string, confirmed bool) map[string]any {
	if problems == nil {
		problems = []string{}
	}
	r := map[string]any{
		"confirmed": confirmed,
		"doc_id":    req.docID,
		// Both numberings, always: the flag is 0-based and every board renders
		// 1..N, and a receipt that prints only one of them is the 0-vs-1 trap
		// the echo line exists to defuse.
		"criterion_index":  req.index,
		"criterion_number": req.index + 1,
		"problems":         problems,
	}
	// `notes` is the machine half of the advisory: never a problem (the write
	// landed), always the same text the human receipt printed, so a scripted
	// caller that branches on `confirmed` can still SEE that its --miss left
	// met standing and read the verb that lowers it.
	notes := []string{}
	// The draft ruling is a NOTE, not a problem: the problem (a value on a row
	// no board reads) is already listed by stampVerdictProblems, and this is the
	// recorded reason the write was allowed to land there at all.
	if readback.IsDraft() {
		notes = append(notes, stampDraftRulingNote)
	}
	if n := missLeftMetTrueNote(req, stored); n != "" {
		notes = append(notes, n)
	}
	r["notes"] = notes
	r["stored"] = map[string]any{
		"criterion":      stored.Criterion,
		"met":            stored.Met,
		"evidence_bytes": len(stored.Evidence),
		"attempts":       len(stored.Attempts),
		"withdrawals":    len(stored.Withdrawals),
	}
	// WHICH ROW answered. A confirmed:true on a draft twin is exactly the green
	// that means nothing, so the identity rides the receipt rather than being
	// summarised away.
	r["row"] = map[string]any{
		"doc_id": readback.DocID,
		"status": readback.Status,
		"draft":  readback.IsDraft(),
	}
	return r
}

// renderStampVerdict is the stamp's receipt, and it is PURE: given the request
// and the row the store handed back, it prints the verdict and returns the exit
// code. Every claim it makes is read off `stored` — the requested values appear
// only as the "expected" half of a contradiction, never as the answer. Hand it a
// row that disagrees and the receipt says so and exits non-zero.
//
// origRC is the exit code the POST itself reported (exitOK or exitServer — see
// confirmStampLanded). The read-back is the SINGLE source of truth once it
// answers: a landed row is exitOK even if the POST answered a 5xx (the write is
// real regardless of what the response said), and a confirmed-absent row is
// exitConflict regardless of what the POST answered, because the store — not
// the transport — is what "landed" means. origRC only changes what gets PRINTED
// (a landed-despite-5xx row gets one extra explanatory line so the surprising
// resurrection is never silent).
//
// The receipt rides progressf: stdout in the human view, stderr under -o
// json/yaml so the dispatch's envelope stays the single parseable document on
// stdout. The exit code carries the verdict in both.
func renderStampVerdict(out *writer, req stampRequest, stored taskboard.CriterionItem, readback apiclient.TaskReadback, origRC int) int {
	// WHICH ROW answered is checked BEFORE what it holds. A draft twin can hold
	// the criterion, hold it exactly as asked, and still be invisible to every
	// board — so comparing its fields would only decorate a green that means
	// nothing. The value landed; it landed somewhere nobody reads.
	if readback.IsDraft() {
		out.userErr("stamp landed on a DRAFT, not the board — %s answered this read-back", readbackRowLabel(readback))
		out.errf("  the value is really in the store, but `%s` has no published row, so no board will ever show it", req.docID)
		out.errf("  criterion index %d (0-based) = criterion #%d as boards/rubric number them", req.index, req.index+1)
		out.errf("  the draft holds: %s", storedCriterionSummary(stored))
		out.errf("  publish the row, then stamp again — `bp doc get task %s` returns not_found until you do", req.docID)
		// The ruling that explains why the write happened at all rides the
		// refusal it governs (tasks_stamp_draft_ruling.go).
		out.errf("  %s", stampDraftRulingNote)
		return exitConflict
	}

	mismatches := stampMismatches(req, stored)
	if len(mismatches) == 0 {
		if origRC == exitServer {
			out.progressf("✓ the store holds it despite the POST answering a server error (exit %d) — a 5xx can commit the write before the response fails; the read-back is the truth here, not the transport error", origRC)
		}
		out.progressf("✓ the store holds it — criterion index %d (#%d as boards number them): %s",
			req.index, req.index+1, storedCriterionSummary(stored))
		// The miss landed AND met is still true. That is not a failure, so the
		// exit code does not move — but it is the exact moment the caller
		// learns the flag did not do what they reached for it to do, so the
		// reachable remedy is named right here.
		if note := missLeftMetTrueNote(req, stored); note != "" {
			out.progressf("  ! %s", note)
		}
		return exitOK
	}
	out.userErr("stamp NOT confirmed by the store — the write did not land as asked")
	out.errf("  criterion index %d (0-based) = criterion #%d as boards/rubric number them", req.index, req.index+1)
	if t := strings.TrimSpace(req.text); t != "" {
		out.errf("  expected criterion: %q", truncateCell(t, 72))
	}
	out.errf("  the store holds:    %s", storedCriterionSummary(stored))
	for _, m := range mismatches {
		out.errf("  ✗ %s", m)
	}
	if note := missLeftMetTrueNote(req, stored); note != "" {
		out.errf("  ! %s", note)
	}
	out.errf("  ✗ NOT stored — stamp again (re-read with `bp task get %s` first if the criteria list may have moved). A stamp is only real once the store holds it.", req.docID)
	return exitConflict
}

// Refusal codes for the two miss-field shapes. Two codes, because they are two
// different mistakes: one reached for the wrong field, the other named no reason
// at all.
const (
	stampMissEvidenceCode = "miss_takes_note_not_evidence"
	stampMissNoteCode     = "miss_requires_note"
)

// missReasonField names, in one clause, WHERE a landed miss keeps its reason.
// Spelled once so the refusal, the read-back line and the docs cannot drift into
// three different answers.
const missReasonField = "acceptance_criteria[N].attempts[].note"

// stampMissFieldRefusal decides whether a `--miss` invocation must be refused
// before the CLI echoes or sends anything, returning an error code and message.
// It returns ("", "") for every other verb: --met and --withdraw own their own
// fields and are untouched by it.
//
// Deliberately CLIENT-SIDE, and deliberately NOT a copy of the server's wording.
// The server stays the authority — it still refuses a note-less miss on its own
// and this loosens nothing. What this adds is (a) ORDER, so the reader sees the
// refusal instead of a progress line implying the write is under way, and (b)
// the `--evidence` case, which the server does not refuse at all. Because the
// prose here says what the server's message cannot (it names the field the
// reason lands in), there is no string that must stay term-identical across Go
// and Elixir; the only thing spelled on both sides is the RULE, and the server
// keeps the last word on it.
func stampMissFieldRefusal(sa stampArgs) (string, string) {
	// ONLY an unambiguous miss. `--met --miss` names two verbs, and that is the
	// "pass exactly one of --met / --miss / --withdraw" refusal's to answer (the
	// server's, which reports it as a USAGE error). Firing here would relabel a
	// two-verb command line as a miss-field mistake and move its exit code —
	// TestTaskStampExit_LostLeaseAndBadCommandLineDiffer measures exactly that.
	if !sa.miss || sa.met || sa.withdraw || sa.amend {
		return "", ""
	}
	if sa.hasEvidence {
		return stampMissEvidenceCode,
			"--miss does not take --evidence: a miss records an ATTEMPT, not a proof, and its reason rides --note. " +
				"Nothing on the server reads `evidence` on the miss path, so this text would NOT have been refused — it would have been DROPPED behind a 2xx. " +
				"Re-run it as `--miss --note \"<why it is unmet>\"`; the sentence is then readable at " + missReasonField +
				" and NOT at .evidence, which a miss never writes (a readback keyed on `.evidence|length` reports 0 for every landed miss — that false zero is what this refusal exists to stop you inheriting)."
	}
	if strings.TrimSpace(sa.note) == "" {
		return stampMissNoteCode,
			"--miss requires a non-empty --note: an honest attempt has words, and --note is the ONLY field a miss keeps them in. " +
				"It lands at " + missReasonField + ", not at .evidence, which a miss never writes. " +
				"Refused here, before the target was echoed and before anything was sent — nothing reached the store."
	}
	return "", ""
}

// storedCriterionSummary describes the row AS STORED: its wording, its met
// lock, how much evidence it carries and how many honest attempts are recorded.
// Evidence is reported by LENGTH as well as text so a truncated write (the
// transport-ceiling class) is visible rather than merely plausible.
//
// THE EMPTY-EVIDENCE MISS. A landed miss leaves `evidence` exactly as it found
// it — usually "" — and puts its reason in the attempt trail, so a bare
// "evidence <empty>" was byte-identical on a miss that stored a perfect sentence
// and on a write that vanished. When there IS an attempt trail and no evidence,
// this reports the reason's REAL address and quotes the most recent note: the
// server appends and keeps the last five (`Enum.take(attempts ++ [attempt], -5)`
// in api/lib/barkpark/tasks/internal.ex), so the LAST element is the newest. A
// row carrying evidence never reaches this branch, so every caller reading a MET
// row reads exactly what it read before.
func storedCriterionSummary(stored taskboard.CriterionItem) string {
	ev := "evidence <empty>"
	if stored.Evidence != "" {
		ev = fmt.Sprintf("evidence %d bytes %q", len(stored.Evidence), truncateCell(stored.Evidence, 48))
	} else if n := len(stored.Attempts); n > 0 {
		latest := stored.Attempts[n-1]
		ev = fmt.Sprintf("no evidence (a miss writes none) — the reason is at %s, %d bytes %q",
			missReasonField, len(latest.Note), truncateCell(latest.Note, 48))
	}
	s := fmt.Sprintf("met=%v  %s  criterion %q", stored.Met, ev, truncateCell(stored.Criterion, 72))
	if n := len(stored.Attempts); n > 0 {
		s += fmt.Sprintf("  attempts=%d", n)
	}
	// Withdrawals are named LOUDLY and last, because their presence changes how
	// the evidence above must be read: on a withdrawn row that text is the
	// SUPERSEDED proof, kept readable on purpose, not a current claim.
	if n := len(stored.Withdrawals); n > 0 {
		s += fmt.Sprintf("  WITHDRAWN×%d (evidence above is the superseded proof)", n)
	}
	return s
}

// readbackRowLabel names the row that answered a read-back, using only what the
// read-back actually carried. It never asserts more than it was told: a server
// that sent no doc_id and no status is described as unnamed, not as a draft and
// not as published.
func readbackRowLabel(rb apiclient.TaskReadback) string {
	switch {
	case rb.DocID != "" && rb.Status != "":
		return fmt.Sprintf("%s (status %q)", rb.DocID, rb.Status)
	case rb.DocID != "":
		return rb.DocID
	case rb.Status != "":
		return fmt.Sprintf("a row with status %q", rb.Status)
	default:
		return "a row the server did not name"
	}
}

// stampMismatches is the pure comparison behind the verdict: every way the
// stored row fails to be the write that was asked for. An empty result means
// the store genuinely holds the stamp.
//
// A --met is confirmed only by met AND non-empty evidence AND (when evidence
// was supplied) the SAME evidence — a server that silently truncated the write
// is exactly the failure mode this read-back exists to catch. A --miss is
// confirmed by the store carrying an attempt with that note; it never demands
// a met flip, because a miss flips nothing.
func stampMismatches(req stampRequest, stored taskboard.CriterionItem) []string {
	var out []string
	// THE ALIGNMENT CHECK, and it is FIRST because it is the only one that can
	// fail on a write the store is perfectly happy with. Every other mismatch
	// below asks "did the value land"; this one asks "did it land where the
	// AUTHOR said it should", which is a question no value read from the row can
	// pose (tasks_stamp_expect_pin.go).
	// AN AMENDMENT CHANGES THE WORDING ON PURPOSE, so the two wording checks
	// below would read its success as failure: --criterion-text and the pin
	// both name the SUPERSEDED sentence, which the server already matched
	// under its lock before replacing it. What proves an amendment landed is
	// that the row now holds the REPLACEMENT.
	if req.amend {
		if want := strings.TrimSpace(req.amended); want != "" && want != strings.TrimSpace(stored.Criterion) {
			out = append(out, "the row at that index does not hold the replacement wording — the amendment did not land")
		}
		return out
	}
	if req.pin != nil {
		if p := stampPinReadbackProblem(*req.pin, req.index, stored.Criterion); p != "" {
			out = append(out, p)
		}
	}
	if want := strings.TrimSpace(req.text); want != "" && want != strings.TrimSpace(stored.Criterion) {
		out = append(out, "the row at that index is a DIFFERENT criterion than the one named by --criterion-text")
	}
	if req.met {
		if !stored.Met {
			out = append(out, "met is still FALSE in the store — the flip did not land")
		}
		if strings.TrimSpace(stored.Evidence) == "" {
			out = append(out, "the store holds NO evidence on that row — a met without evidence is not a sealed row")
		} else if sent := strings.TrimSpace(req.evidence); sent != "" && sent != strings.TrimSpace(stored.Evidence) {
			out = append(out, fmt.Sprintf("the stored evidence differs from what was sent (%d bytes stored vs %d sent)",
				len(stored.Evidence), len(req.evidence)))
		}
	}
	if req.miss {
		if note := strings.TrimSpace(req.note); note != "" && !hasAttemptNote(stored, note) {
			out = append(out, "the store carries no recorded attempt with that note — the miss did not land")
		}
	}
	// A WITHDRAWAL is confirmed by BOTH halves, and the first one is the whole
	// point: the lock must actually be DOWN in the store. A withdrawal that
	// records its reason while met stays true would reproduce the exact defect
	// the verb was built to end — a board reading MET with the correction
	// visible only to someone who opens the row and reads prose.
	if req.withdraw {
		if stored.Met {
			out = append(out, "met is still TRUE in the store — the withdrawal did not lower the lock, so every board still counts this criterion as proven")
		}
		if note := strings.TrimSpace(req.note); note != "" && !hasWithdrawalNote(stored, note) {
			out = append(out, "the store carries no withdrawal record with that note — the correction is unsigned, so nothing says who withdrew it or why")
		}
	}
	return out
}

// hasWithdrawalNote reports whether the stored row carries a withdrawal record
// with this note. The server keeps every withdrawal (the list is unbounded), so
// a just-written one is always present.
func hasWithdrawalNote(stored taskboard.CriterionItem, note string) bool {
	for _, w := range stored.Withdrawals {
		if strings.TrimSpace(w.Note) == note {
			return true
		}
	}
	return false
}

// hasAttemptNote reports whether the stored row carries an attempt with this
// note (the server keeps the 5 most recent, so a just-written one is always in
// the window it hands back).
func hasAttemptNote(stored taskboard.CriterionItem, note string) bool {
	for _, a := range stored.Attempts {
		if strings.TrimSpace(a.Note) == note {
			return true
		}
	}
	return false
}

// stampArgs is the advisory, CLI-side view of a `task stamp` invocation used by
// the echo and the MERGE-GATED tripwire. It is NOT the authority on the request
// — splitArgs (run.go) validates and binds the forwarded flags; this view only
// drives the two client-only ergonomics.
type stampArgs struct {
	criterion     *int
	criterionText string
	met           bool
	miss          bool
	withdraw      bool
	amend         bool
	// expect is the AUTHOR-TYPED pin, verbatim as it was typed
	// (`<index>:<first words>`), or "" when none was given. It is the one value
	// in this struct that does not come from the row being stamped — see
	// tasks_stamp_expect_pin.go.
	expect string
	// mergeGated is FLAG PRESENCE, not permission: `--merge-gated` appeared in
	// the tail at all.
	mergeGated bool
	// mergeGatedReason is the REASON the flag carried. A present flag with a
	// blank reason is a usage refusal (see runTaskStamp) — the whole point of
	// the change is that the override can no longer be free.
	mergeGatedReason string
	// note / evidence record the TEXT each flag carried; hasNote / hasEvidence
	// record whether the flag was TYPED AT ALL. Those are different questions:
	// `--evidence ""` is still a caller reaching for the wrong field on a miss,
	// and the refusal has to say so rather than silently treating it as absent.
	note        string
	evidence    string
	hasNote     bool
	hasEvidence bool
}

// parseStampArgs pulls the criterion index, criterion-text, the met/miss
// outcome and the --merge-gated override out of the stamp tail. It returns the
// parsed view AND the forward slice for the manifest dispatch: every token,
// order preserved, so the CLI never re-indexes --criterion (the index the
// builder types is the index the server receives).
//
// `mergeGatedType` is the SERVER's declared type for --merge-gated, from the
// manifest: "string" on a current server (the flag carries a REASON and both
// tokens ride the POST), "bool" on a server that declares the older reason-less
// flag (the reason cannot land there, so only the bare flag is forwarded — the
// value token would otherwise bind as a positional and fail splitArgs), and ""
// on a server that predates the server-side guard entirely (flag AND reason are
// stripped, because an undeclared token fails splitArgs with "unknown flag").
// In every case sa.mergeGated / sa.mergeGatedReason record what the CALLER
// typed, so the CLI-side reason refusal is identical against all three. Both
// `--flag value` and `--flag=value` spellings are recognized. Parsing here is
// advisory only.
func parseStampArgs(tail []string, mergeGatedType string) (stampArgs, []string) {
	var sa stampArgs
	forward := make([]string, 0, len(tail))
	for i := 0; i < len(tail); i++ {
		name, val, inline := splitFlagToken(tail[i])
		// Read a space-form value from the next token (not itself a flag).
		spaceVal := func() string {
			if !inline && i+1 < len(tail) && !strings.HasPrefix(tail[i+1], "-") {
				return tail[i+1]
			}
			return val
		}
		switch name {
		case "--merge-gated":
			sa.mergeGated = true
			sa.mergeGatedReason = spaceVal()
			// Does a SEPARATE token carry the reason (the `--flag value`
			// spelling)? Then it must be consumed here, or it would bind as a
			// positional against a server that does not take a value.
			separate := !inline && i+1 < len(tail) && !strings.HasPrefix(tail[i+1], "-")
			switch mergeGatedType {
			case "string":
				// Current server: flag and (on the next iteration) its reason
				// both ride the POST, order preserved.
			case "bool":
				// Reason-less server: forward the BARE flag, drop the reason —
				// in BOTH spellings, so `--merge-gated=<why>` and
				// `--merge-gated <why>` reach it identically. Appended
				// explicitly rather than falling through to the shared append,
				// which would re-read tail[i] AFTER the value was consumed.
				if separate {
					i++
				}
				forward = append(forward, "--merge-gated")
				continue
			default:
				// Legacy server: undeclared flag, never forwarded — nor its reason.
				if separate {
					i++
				}
				continue
			}
		case "--met":
			sa.met = true
		case "--miss":
			sa.miss = true
		case "--withdraw":
			sa.withdraw = true
		case "--amend":
			sa.amend = true
		case "--criterion":
			if n, err := strconv.Atoi(strings.TrimSpace(spaceVal())); err == nil {
				sa.criterion = &n
			}
		case "--criterion-text":
			sa.criterionText = spaceVal()
		case "--note":
			sa.note = spaceVal()
			sa.hasNote = true
		case "--evidence":
			sa.evidence = spaceVal()
			sa.hasEvidence = true
		case stampExpectFlag:
			// CLIENT-SIDE AND UNDECLARABLE. The pin is an expectation authored
			// before the row was read; the server has nothing to do with it and
			// does not declare the flag, so forwarding it would fail splitArgs
			// with "unknown flag". Consume the value token too when the
			// `--expect <pin>` spelling was used, or it would bind as a
			// positional (the same shape as the legacy --merge-gated strip).
			sa.expect = spaceVal()
			if !inline && i+1 < len(tail) && !strings.HasPrefix(tail[i+1], "-") {
				i++
			}
			continue
		}
		forward = append(forward, tail[i])
	}
	return sa, forward
}

// stampMergeGateFallback is the LEGACY client-side tripwire, reached ONLY when
// the server's manifest does not declare --merge-gated (see runTaskStamp). The
// live guard is `Barkpark.Tasks.Criteria.merge_gated?/1` on the server, which
// reads the STORED criterion's `merge_gate` field and falls back to prose only
// when the author set no field. Do NOT re-promote this to the primary check:
// it sees only the `--criterion-text` the caller typed, so it cannot honour the
// structural flag in EITHER direction. Delete it once no supported server
// predates the declared flag.
// A WITHDRAWAL is never caught by it: `sa.met` is false on that path, which is
// correct and load-bearing — lowering a merge gate's lock cannot fabricate a
// done before the PR exists, which is the only harm this tripwire guards.
func stampMergeGateFallback(sa stampArgs) bool {
	return sa.met && !sa.mergeGated && isMergeGatedText(sa.criterionText)
}

// isMergeGatedText reports whether a criterion's wording carries the
// MERGE-GATED marker (the standard "[MERGE-GATED — the lead closes this]"
// row), case-insensitively and tolerant of a hyphen or space between the words.
// Frozen deliberately: it is the LEGACY-server predicate and must keep matching
// exactly what old servers assumed. The authoritative, wider predicate is
// Barkpark.Tasks.Criteria.merge_gated?/1 — find it by grepping the canonical
// capability slug "merge-gate-criterion-predicate".
func isMergeGatedText(s string) bool {
	u := strings.ToUpper(s)
	return strings.Contains(u, "MERGE-GATED") || strings.Contains(u, "MERGE GATED")
}

// commandDeclaresFlag reports whether the manifest command declares a flag by
// name — the capability probe that decides whether --merge-gated can ride the
// POST or must be stripped for an older server.
func commandDeclaresFlag(cmd manifest.Command, name string) bool {
	return commandFlagType(cmd, name) != ""
}

// commandFlagType returns the manifest's declared TYPE for a flag, or "" when
// the command does not declare it at all. Presence alone stopped being enough
// once --merge-gated grew a reason: a server can declare the flag and still not
// take a value for it, and forwarding the reason there fails splitArgs.
// A declared flag with an empty type in the manifest reads as "string", which
// is what the manifest's own default is.
func commandFlagType(cmd manifest.Command, name string) string {
	for _, f := range cmd.Flags {
		if f.Name == name {
			if f.Type == "" {
				return "string"
			}
			return f.Type
		}
	}
	return ""
}

// stampEchoLine renders the one-line, human-facing confirmation of WHICH
// criterion a stamp targets, translating the 0-based --criterion index to the
// 1-based position boards/rubric show so a 0-vs-1 base slip is caught at the
// moment of the stamp. Returns "" when no criterion index was given (the
// manifest dispatch then produces its normal usage error).
func stampEchoLine(sa stampArgs) string {
	if sa.criterion == nil {
		return ""
	}
	idx := *sa.criterion
	outcome := "stamp"
	switch {
	case sa.met:
		outcome = "met"
	case sa.miss:
		// A miss is the outcome operators reach for when they mean "lower this"
		// — and it lowers nothing. Say so BEFORE the write, and name the verb
		// that does (missLeftMetTrueNote says it again after).
		outcome = "miss (attempt) — met is UNCHANGED; " + stampWithdrawFlag + " is the verb that lowers a wrong met"
	case sa.withdraw:
		// Spelled out because a withdrawal is the one outcome that makes the
		// board's number go DOWN, and an operator who typed the wrong index
		// should see that before the write, not after.
		outcome = "WITHDRAW (met → false; the evidence is kept, the lock is lowered)"
	case sa.amend:
		// The text quoted after this line is the wording being REPLACED.
		outcome = "AMEND the wording (met and evidence are pinned) — replacing"
	}
	line := fmt.Sprintf("→ criterion index %d (0-based) = criterion #%d as boards/rubric number them → %s", idx, idx+1, outcome)
	if t := strings.TrimSpace(sa.criterionText); t != "" {
		line += fmt.Sprintf(": %q", truncateCell(t, 72))
	}
	return line
}

// ─── THE MACHINE RECEIPT ────────────────────────────────────────────────────

// stampCapture buffers the dispatch's stdout under `-o json` so the read-back
// verdict can be MERGED into the one document a scripted caller parses, instead
// of contradicting it from stderr.
//
// JSON ONLY, deliberately. Under `-o yaml` the dispatch has already emitted
// hand-rolled YAML text (renderYAML), and re-parsing an emitter's own output to
// splice a field into it would make this verb depend on a round-trip nothing
// guarantees. Under the human shapes there is nothing to merge: the verdict is
// already the primary output on stdout. So capture is armed for exactly the one
// shape whose stdout is a JSON document the CLI itself produced.
type stampCapture struct {
	buf    bytes.Buffer
	orig   io.Writer
	active bool
}

// beginStampCapture arms the capture and redirects the writer's stdout. Every
// exit path of runTaskStamp must go through flush, which restores it — a return
// that skips flush would swallow the envelope entirely.
//
// The shape is RESOLVED here, before arming. The writer arrives carrying the
// pre-command default (json whenever stdout is a pipe), and the command's own
// `default_output` — "minimal" for every task write — only lands when runCommand
// calls resolveOutputForCommand. Arming off the unresolved value armed the
// capture for every piped run and turned the minimal receipt into a JSON
// document. The call is idempotent (it is a pure function of g + cmdDefault),
// so runCommand making it again a moment later changes nothing.
func beginStampCapture(out *writer, g globals, cmd manifest.Command) *stampCapture {
	c := &stampCapture{}
	out.resolveOutputForCommand(g, cmd.DefaultOutput)
	if out.output != "json" {
		return c
	}
	c.active = true
	c.orig = out.stdout
	out.stdout = &c.buf
	return c
}

// flush restores stdout and emits the final document. With no receipt (a dry
// run, a refusal the server made before any commit, an invocation with no
// usable index) the buffered envelope is passed through BYTE-FOR-BYTE: nothing
// was read back, so nothing may be added or contradicted.
//
// With a receipt, the verdict wins. `stamp` carries it, and the envelope's
// top-level `ok` is REWRITTEN to the read-back's answer — which is the whole
// point: `ok:true` on a stamp the store does not hold is the transport
// speaking, and this verb's contract (renderStampVerdict's doc comment) is that
// once the read-back answers it is the single source of truth. The exit code
// already says so; now stdout agrees with it.
func (c *stampCapture) flush(out *writer, rc int, receipt map[string]any) int {
	if !c.active {
		return rc
	}
	out.stdout = c.orig
	c.active = false

	raw := c.buf.Bytes()
	if receipt == nil {
		if len(raw) > 0 {
			_, _ = out.stdout.Write(raw)
		}
		return rc
	}
	var env map[string]any
	if len(raw) == 0 || json.Unmarshal(raw, &env) != nil || env == nil {
		// The dispatch emitted nothing parseable as an object (a non-JSON body
		// re-encoded as a string, say). The receipt still has to reach stdout,
		// so it is emitted as a document of its own rather than dropped — and
		// the unparseable bytes are preserved on stderr, where they cannot
		// break the caller's parse.
		if len(raw) > 0 {
			out.errf("note: the stamp response was not a JSON object, so the receipt is emitted alone; the response was: %s", strings.TrimRight(string(raw), "\n"))
		}
		out.renderJSON(map[string]any{"ok": rc == exitOK, "stamp": receipt})
		return rc
	}
	env["stamp"] = receipt
	env["ok"] = rc == exitOK
	out.renderJSON(env)
	return rc
}

// ─── THE MERGE-GATE DETECTOR ────────────────────────────────────────────────

// explainMergeGateDetector answers the one question the server's 409 cannot:
// WHICH arm of `Barkpark.Tasks.Criteria.merge_gated?/1` refused this row.
//
// The server's hint has to hedge, because it is written once for every row —
// it says the match "may" have been on the prose and quotes the corpus-wide
// 3.5% mention rate. But the row itself settles it in one read: a criterion
// carrying `"merge_gate": true` was refused by the FLAG (a declared gate, not a
// false positive), and a criterion carrying no `merge_gate` key at all was
// refused by the PROSE fallback — and that row is UNDER-DECLARED in a way that
// costs more than one refusal, because `Tasks.Close.autostamp_merge_gate/6`
// keys on the flag ALONE. Worded-but-unflagged is therefore a criterion the
// builder may not stamp and the lead's merge will not autostamp: closable by
// nobody until its shape is patched to match its words. That is the state
// `bp task create` files by default, and it is why this says how to fix it.
//
// Advisory and best-effort: it prints extra stderr lines under an exit code the
// dispatch already set, and a read it cannot complete says so rather than
// guessing a detector.
func explainMergeGateDetector(out *writer, ctx manifest.Context, docID string, idx int) {
	flag, text, err := storedMergeGateFlag(taskReadbackClient(ctx), docID, idx)
	if err != nil {
		out.errf("  (could not read %s criterion index %d back to name which detector fired: %v)", docID, idx, err)
		return
	}
	switch {
	case flag != nil && *flag:
		out.errf("  DETECTOR: the merge_gate FLAG. criterion index %d (#%d as boards number them) carries \"merge_gate\": true — this row is a DECLARED gate, so the refusal is NOT a prose false positive and no wording change will lift it. The lead closes it on merge (--merge-gated, or the close-time autostamp).", idx, idx+1)
	case flag == nil:
		out.errf("  DETECTOR: the PROSE fallback. criterion index %d (#%d as boards number them) carries NO \"merge_gate\" key, so the guard matched the MERGE-GATED / MERGE GATE wording in its text: %q", idx, idx+1, truncateCell(text, 72))
		out.errf("  that row is UNDER-DECLARED, and the refusal is only half the cost: the lead's close-time autostamp keys on the FLAG alone, so a merge will not flip it either — as filed, this criterion can be closed by nobody.")
		out.errf("  patch the shape to match the words (read the list, add the key to entry %d, send it back):", idx)
		out.errf("    bp task get %s -o json | jq '.doc.content.acceptance_criteria'", docID)
		out.errf("    bp doc patch task %s --set 'acceptance_criteria:=<that list, with \"merge_gate\": true on entry %d>'   # a REAL gate: the lead's merge then autostamps it", docID, idx)
		out.errf("    …or \"merge_gate\": false on entry %d if the row merely MENTIONS merge-gating — the guard never asks again, and --met works.", idx)
	default:
		// merge_gate:false is an explicit NOT-A-GATE declaration that
		// merge_gated?/1 honours ahead of the prose, so this refusal cannot have
		// come from the row we just read. Say that rather than name a detector.
		out.errf("  (the row now reads \"merge_gate\": false, which is an explicit NOT-A-GATE — so this refusal did not come from the row as it stands; re-read %s, it may have been patched since the stamp.)", docID)
	}
}

// storedMergeGateFlag reads acceptance_criteria[idx] and reports its
// `merge_gate` key as a THREE-valued answer — true, false, or absent (nil) —
// because absent is the whole diagnosis: it is what selects the prose arm of
// merge_gated?/1 and what the close-time autostamp cannot see. Collapsing it to
// a bool would erase exactly the state this explains. It also returns the
// criterion text, so the refusal can quote the wording that matched.
//
// The decode is local and deliberately minimal: internal/taskboard's
// CriterionItem models the row a BOARD renders and carries no merge_gate field,
// and the flag's tri-state does not survive a bool decode anyway.
func storedMergeGateFlag(c *apiclient.Client, docID string, idx int) (*bool, string, error) {
	if idx < 0 {
		return nil, "", fmt.Errorf("criterion index %d is negative — indices are zero-based", idx)
	}
	rb, err := c.TaskGetContent(docID)
	if err != nil {
		return nil, "", err
	}
	var content struct {
		Criteria []struct {
			Criterion string `json:"criterion"`
			MergeGate *bool  `json:"merge_gate"`
		} `json:"acceptance_criteria"`
	}
	if err := json.Unmarshal(rb.Content, &content); err != nil {
		return nil, "", fmt.Errorf("the store's acceptance_criteria did not decode: %w", err)
	}
	if idx >= len(content.Criteria) {
		return nil, "", fmt.Errorf("the store holds %d acceptance criteria on %s — index %d (0-based) does not exist",
			len(content.Criteria), docID, idx)
	}
	return content.Criteria[idx].MergeGate, content.Criteria[idx].Criterion, nil
}

// ─── THE DISCRIMINATION PRE-CHECK ───────────────────────────────────────────
//
// A GUARD WHOSE EXPECTED VALUE IS READ FROM THE THING IT GUARDS CANNOT FIRE
// (task-33e42f188c491bbe). `--criterion-text` exists to catch an off-by-one:
// the caller names index i and confirms it by quoting the criterion stored at
// i, and the server refuses a mismatch. Every scripted caller measured on this
// campaign produced that confirmation the same way — `crit[i]["criterion"]`,
// read back from the row being stamped — so index and text came from ONE
// expression and agreed BY CONSTRUCTION, for every i. The guard was present,
// was invoked, returned success, and discriminated nothing.
//
// WHAT THIS CAN AND CANNOT DECIDE, stated plainly because the limit is the
// point. Nothing on the wire distinguishes a hand-typed confirmation from a
// copied one: on a row whose criteria are all DISTINCT, a text derived from
// index i is byte-identical to a correct text for index i. A CLI-side
// validation therefore cannot, even in principle, refuse "this was copied".
// It CAN refuse the case where the supplied text is provably incapable of
// naming a criterion: when it byte-matches the stored wording at MORE THAN ONE
// index, the confirmation fits several criteria equally well, so pairing it
// with any one of them asserts nothing the other indices do not also satisfy.
// The server's match-at-index test accepts that text at every one of those
// indices; this refuses it at all of them.
//
// THE RESIDUAL HAZARD IS NAMED, NOT CLOSED. On a distinct-criteria row the
// silent-by-construction case survives this check (see
// TestTaskStampExecute_RotatedIndicesOnDistinctCriteriaStillSilent, which
// EXERCISES that survival rather than asserting it away). Closing it needs a
// confirmation the row cannot supply — an index→prefix pin typed by the author
// BEFORE the row is read, plus an alignment read-back — which is a change to
// what the verb ASKS FOR, not to what it validates, and is not made here.
const criterionTextNotDiscriminatingCode = "criterion_text_not_discriminating"

// refuseNonDiscriminatingCriterionText reads the row's criteria BEFORE the POST
// and refuses a met-stamp whose `--criterion-text` matches more than one of
// them. Returns exitOK to mean "carry on".
//
// Armed for `--met` only, and only when a text was supplied: a miss flips
// nothing, and a stamp with no text is already refused by the server
// (criterion_text_required) with a better message than this one could give.
//
// ADVISORY ON A FAILED READ, BY DESIGN. If the store cannot be reached the
// check says so on stderr and lets the stamp proceed: this is an ADDITIONAL
// refusal layered on a server guard that still runs, so turning an unreachable
// read into a blocked write would trade a narrow false-negative for a broad
// outage. "We could not ask" is reported, never silently treated as a pass.
func refuseNonDiscriminatingCriterionText(out *writer, ctx manifest.Context, sa stampArgs, cmd manifest.Command, forward []string) int {
	if !sa.met || sa.criterion == nil {
		return exitOK
	}
	want := strings.TrimSpace(sa.criterionText)
	if want == "" {
		return exitOK
	}
	req, ok := stampRequestOf(cmd, forward)
	if !ok {
		return exitOK
	}
	texts, err := storedCriterionTexts(taskReadbackClient(ctx), req.docID)
	if err != nil {
		out.errf("(could not read %s back to check that --criterion-text names ONE criterion: %v — the stamp proceeds under the server's guard alone)", req.docID, err)
		return exitOK
	}
	matches := criterionTextMatchIndices(texts, want)
	if len(matches) < 2 {
		return exitOK
	}
	return useError(out, criterionTextNotDiscriminatingCode,
		fmt.Sprintf("refusing this stamp: --criterion-text does not name ONE criterion. The wording you passed byte-matches the stored criterion at %s of %s — so it confirms index %d no more than it confirms the others, and the off-by-one guard it is supposed to be is inert for this row. %s",
			pluralIndexList(matches), pluralCount(len(texts), "criterion", "criteria"), *sa.criterion,
			"Fix the ROW, not the invocation: duplicate criteria are unstampable-with-confidence by anyone, so patch the wording so each criterion says something only it says (`bp task get <id> -o json | jq '.doc.content.acceptance_criteria'`, then `bp doc patch task <id> --set 'acceptance_criteria:=<the corrected list>'`), then stamp again."),
		exitValidation)
}

// criterionTextMatchIndices reports every index whose stored criterion is the
// supplied text, compared on trimmed bytes — the same comparison the read-back
// verdict (stampMismatches) and the server's guard use, so the three can never
// disagree about what "matches" means.
//
// EMPTY STORED SLOTS NEVER MATCH. A row shorter than the indices in play, or a
// criteria list carrying a blank entry, would otherwise collide with every
// other blank and manufacture a refusal out of the row's shape rather than its
// wording. The supplied text is already known non-empty at the call site.
func criterionTextMatchIndices(criteria []string, want string) []int {
	var out []int
	for i, c := range criteria {
		stored := strings.TrimSpace(c)
		if stored == "" {
			continue
		}
		if stored == want {
			out = append(out, i)
		}
	}
	return out
}

// storedCriterionTexts reads the row's acceptance_criteria and returns just the
// wording, positionally. The decode is local and minimal for the same reason
// storedMergeGateFlag's is: internal/taskboard's CriterionItem models the row a
// BOARD renders, and this needs the whole LIST, not one item.
func storedCriterionTexts(c *apiclient.Client, docID string) ([]string, error) {
	rb, err := c.TaskGetContent(docID)
	if err != nil {
		return nil, err
	}
	var content struct {
		Criteria []struct {
			Criterion string `json:"criterion"`
		} `json:"acceptance_criteria"`
	}
	if err := json.Unmarshal(rb.Content, &content); err != nil {
		return nil, fmt.Errorf("the store's acceptance_criteria did not decode: %w", err)
	}
	texts := make([]string, len(content.Criteria))
	for i, item := range content.Criteria {
		texts[i] = item.Criterion
	}
	return texts, nil
}

// pluralIndexList renders "indices 0, 3 and 5" (0-based, as the flag is) with
// the 1-based board positions beside them, because the refusal is ABOUT index
// confusion and a message that speaks only one base would add to it.
func pluralIndexList(idx []int) string {
	parts := make([]string, len(idx))
	for i, n := range idx {
		parts[i] = fmt.Sprintf("index %d (#%d as boards number them)", n, n+1)
	}
	switch len(parts) {
	case 0:
		return "no index"
	case 1:
		return parts[0]
	default:
		return strings.Join(parts[:len(parts)-1], ", ") + " and " + parts[len(parts)-1]
	}
}

// pluralCount renders "4 criteria" / "1 criterion".
func pluralCount(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}
