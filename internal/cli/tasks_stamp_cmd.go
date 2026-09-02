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
//  3. READ-BACK (PDS-D359/D361, wave 26) — after a 2xx, RE-READ the criterion
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
	declared := commandDeclaresFlag(cmd, "merge-gated")
	sa, forward := parseStampArgs(tail, declared)

	// LEGACY-SERVER FALLBACK ONLY. When the server declares --merge-gated it
	// owns the verdict (it can read the stored `merge_gate` field; we cannot),
	// and the flag rides the POST. Against an older manifest the flag is not
	// declared — forwarding it would fail splitArgs as an unknown flag — so we
	// strip it and run the historical text-only tripwire, which is wrong at the
	// edges but strictly better than shipping the met-flip unguarded.
	if !declared && stampMergeGateFallback(sa) {
		return useError(out, "merge_gated_criterion",
			"refusing to stamp a MERGE-GATED criterion met: --criterion-text carries the MERGE-GATED marker, and that row is the lead's to close (a builder flipping it fabricates a done before the PR exists). Pass --merge-gated to override only if you are the lead closing the gate. (This server is too old to declare --merge-gated, so the match is on the TEXT you passed and may be a false positive on a criterion that merely MENTIONS merge-gating.)",
			exitValidation)
	}

	// Echo the translated target so a 0-vs-1 base slip is visible immediately —
	// stderr, so a scripted caller's stdout stays byte-identical to the bare
	// manifest path (mirrors emitHelpHints).
	if line := stampEchoLine(sa); line != "" {
		out.errf("%s", line)
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

	// Hand the real POST to the shared dispatch, with the CLI-only
	// --merge-gated stripped (the server does not declare that flag, so an
	// un-stripped token would fail splitArgs with "unknown flag").
	rc := runCommand(out, g, ctx, m, cmd, forward)

	// THE READ-BACK (PDS-D359/D361). A 2xx is not a landed write: the epic has
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
		return cap.flush(out, rc, nil)
	}
	req, ok := stampRequestOf(cmd, forward)
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
		return exitConflict
	}

	mismatches := stampMismatches(req, stored)
	if len(mismatches) == 0 {
		if origRC == exitServer {
			out.progressf("✓ the store holds it despite the POST answering a server error (exit %d) — a 5xx can commit the write before the response fails; the read-back is the truth here, not the transport error", origRC)
		}
		out.progressf("✓ the store holds it — criterion index %d (#%d as boards number them): %s",
			req.index, req.index+1, storedCriterionSummary(stored))
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
	out.errf("  ✗ NOT stored — stamp again (re-read with `bp task get %s` first if the criteria list may have moved). A stamp is only real once the store holds it.", req.docID)
	return exitConflict
}

// storedCriterionSummary describes the row AS STORED: its wording, its met
// lock, how much evidence it carries and how many honest attempts are recorded.
// Evidence is reported by LENGTH as well as text so a truncated write (the
// transport-ceiling class) is visible rather than merely plausible.
func storedCriterionSummary(stored taskboard.CriterionItem) string {
	ev := "evidence <empty>"
	if stored.Evidence != "" {
		ev = fmt.Sprintf("evidence %d bytes %q", len(stored.Evidence), truncateCell(stored.Evidence, 48))
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
	mergeGated    bool
}

// parseStampArgs pulls the criterion index, criterion-text, the met/miss
// outcome and the --merge-gated override out of the stamp tail. It returns the
// parsed view AND the forward slice for the manifest dispatch: every token,
// order preserved, so the CLI never re-indexes --criterion (the index the
// builder types is the index the server receives).
//
// `mergeGatedDeclared` says whether the SERVER declares --merge-gated. When it
// does the flag is forwarded like any other (the server enforces the gate and
// needs to see the override); when it does not, the flag is stripped, because
// an undeclared token fails splitArgs with "unknown flag" — that is the
// pre-existing behaviour, kept only for older servers. Both `--flag value` and
// `--flag=value` spellings are recognized. Parsing here is advisory only.
func parseStampArgs(tail []string, mergeGatedDeclared bool) (stampArgs, []string) {
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
			if !mergeGatedDeclared {
				continue // legacy server: undeclared flag, never forwarded.
			}
		case "--met":
			sa.met = true
		case "--miss":
			sa.miss = true
		case "--withdraw":
			sa.withdraw = true
		case "--criterion":
			if n, err := strconv.Atoi(strings.TrimSpace(spaceVal())); err == nil {
				sa.criterion = &n
			}
		case "--criterion-text":
			sa.criterionText = spaceVal()
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
	for _, f := range cmd.Flags {
		if f.Name == name {
			return true
		}
	}
	return false
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
		outcome = "miss (attempt)"
	case sa.withdraw:
		// Spelled out because a withdrawal is the one outcome that makes the
		// board's number go DOWN, and an operator who typed the wrong index
		// should see that before the write, not after.
		outcome = "WITHDRAW (met → false; the evidence is kept, the lock is lowered)"
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
