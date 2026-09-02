package cli

import (
	"fmt"
	"strconv"
	"strings"

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
		return rc
	}
	req, ok := stampRequestOf(cmd, forward)
	if !ok {
		// No usable --criterion index (the manifest dispatch has already
		// reported whatever was wrong with the invocation): there is no
		// specific row to re-read, so claim nothing extra about one.
		return rc
	}
	if rc == exitServer {
		out.errf("the stamp POST answered a server error (exit %d) — checking the store before trusting that as \"nothing landed\" (a 5xx can hide a write that already committed)", rc)
	}
	return confirmStampLanded(out, ctx, req, rc)
}

// stampRequest is what the caller ASKED the ledger to write. It is the request
// half of the receipt and is NEVER the source of the verdict — renderStampVerdict
// prints from the STORED row and uses these fields only to say what was expected.
type stampRequest struct {
	docID    string
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
func confirmStampLanded(out *writer, ctx manifest.Context, req stampRequest, origRC int) int {
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
		out.userErr("stamp sent but NOT confirmed — the read-back of %s criterion index %d failed: %v",
			req.docID, req.index, err)
		out.errf("  the write may or may not have landed; re-read with `bp task get %s` before trusting it", req.docID)
		if origRC != exitOK {
			return origRC
		}
		return exitGeneric
	}
	return renderStampVerdict(out, req, stored, readback, origRC)
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
	out.errf("  a stamp is only real once the store holds it — re-read with `bp task get %s` and stamp again", req.docID)
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
