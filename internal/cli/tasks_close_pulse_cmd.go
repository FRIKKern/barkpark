package cli

// tasks_close_pulse_cmd.go — the read-back for `bp task close` and
// `bp task pulse`, the two siblings of `bp task stamp` on the same ledger.
//
// Wave 26 gave `stamp` a second read (PDS-D359/D361) and cut the slice at the
// stamp verb. Its two siblings carry the SAME exposure and were left reporting
// success on an exit code alone:
//
//   - close is the SEAL. It writes lifecycle_status and, with
//     `--set 'criteria:=[…]'`, the criteria ledger in one atomic update, and
//     printed whatever the manifest dispatch rendered. A close that half-landed
//     exited 0.
//   - pulse writes the now-line the board renders plus the lease renewal, and
//     printed an epoch it never re-read. A now-line that never reached the board
//     exited 0.
//
// Both follow stamp's shape exactly, so there is one pattern on this ledger and
// not three: hand the real POST to runCommand, then ASK THE STORE and render the
// verdict from what it holds. Both also inherit the draft check — the read-back
// route falls back to the `drafts.` twin, so a close or a pulse can land on a row
// no board will ever show.
//
// THE STATUS CODE CARRIES NO INFORMATION ABOUT WHETHER THE WRITE LANDED. Three
// outcomes are real and this system has produced all three:
//
//	200 + LOST    a normal envelope over a write the store never took
//	500 + LANDED  the transaction commits, then the RESPONSE fails
//	500 + LOST    the ordinary genuine failure
//
// Only the read-back separates them, so both verbs re-read on a 2xx AND on a
// 5xx, and each of the three has an Execute-level test
// (tasks_close_pulse_execute_test.go). A suite that exercised only the happy
// path would re-certify the bug rather than catch it.
//
// A SEALED ROW THAT NAMES A WORKER IS NOT A HALF-LANDED CLOSE. The claim map
// SURVIVES a successful close by design — the server stamps `closed_by` +
// `closed_at` onto it in the same atomic write as the seal and keeps
// `claim.worker` as the attribution — so "the row is sealed but X STILL HOLDS
// the claim" fired on every ordinary close of a claimed task, and told the
// operator to "close again" on a row that would 409 as already-terminal. The
// half-landed test is now the ABSENCE of that close-out stamp, plus one bounded
// re-read before the refusal is printed (closeClaimIsLive / closeClaimNeedsSecondLook).
//
// THE ONE INFERENCE THAT REMAINS, STATED PLAINLY. Every OTHER non-2xx — auth,
// validation, not_found, conflict, rate-limit — returns WITHOUT a second read,
// on the assumption that the server refused BEFORE any commit. That assumption
// holds for those paths as they are implemented today (they are guard-clause
// rejections ahead of the transaction), but it IS an inference from a status
// code, and it is the one place these verbs still make one. If a refusal path
// ever grows a partial write ahead of its rejection, this skip becomes the same
// defect in miniature and the fix is to re-read there too. Re-reading on every
// refusal today would add a round trip and noise on a row nothing touched,
// which is why it is not done — a deliberate trade, recorded rather than
// hidden.

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// ── close ───────────────────────────────────────────────────────────────────

// closeRequest is what the caller ASKED the ledger to seal. Like stampRequest it
// is NEVER the source of the verdict — renderCloseVerdict prints from the STORED
// row and uses these only to say what was expected.
type closeRequest struct {
	docID    string
	worker   string
	wantSeal string
	// reason is the free-text note the close carried (`reason`, the FIFTH
	// positional). It lands in the stored row as `content.close_reason`, which
	// makes it the one field that can identify THIS close among any others —
	// see closeStaleClaimLanded.
	reason string
}

// runTaskClose wraps the manifest `task close` verb with the read-back. The POST
// itself is untouched — every dispatch, render and guard stays shared with the
// generic path.
func runTaskClose(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	// THE SEAL SLOT IS NOT A REASON SLOT, and this is refused BEFORE the POST.
	// See refuseCloseSealSentence for why the refusal is local and why it does
	// not coerce.
	if code, refused := refuseCloseSealSentence(out, cmd, tail); refused {
		return code
	}

	rc := runCommand(out, g, ctx, m, cmd, tail)

	// Same skip rule as stamp: --dry-run sent nothing, and every non-2xx other
	// than a 5xx is the server refusing BEFORE any commit. A 5xx IS re-read —
	// "a 500 can hide a write that landed" — so an 8 is never taken as proof
	// the seal is absent.
	if g.dryRun || (rc != exitOK && rc != exitServer) {
		// A `stale_claim` 409 CAN SIT ON TOP OF A WRITE THAT LANDED. Measured on
		// five closes (lead-triage-o, 2026-09): the row stored, with its own
		// reason verbatim, nobody else involved, and the CLI still exited 6.
		// The natural recovery — re-claim and retry — then 409s `not_ready`
		// because the row is already closed, so a correctly closed row reports
		// as uncloseable and the operator is left believing their work is not
		// on the ledger.
		//
		// This is the same "the status code carries no information about
		// whether the write landed" fault the 5xx arm above exists for, wearing
		// a 409. So it gets the same remedy and the SAME read-back: ask the
		// store, and only then report. The skip documented at the top of this
		// file ("every OTHER non-2xx returns WITHOUT a second read") is
		// narrowed by exactly this one code — the one measured to break it.
		if !g.dryRun && rc == exitConflict && out.lastErrorCode == "stale_claim" {
			if req, ok := closeRequestOf(cmd, tail); ok {
				if code, landed := closeLandedDespiteStaleClaim(out, ctx, req, rc); landed {
					return code
				}
			}
		}
		// Same fenced_off explanation the stamp path gets: a close refused on a
		// stale epoch is a pulse's doing, and the 409 alone never says so
		// (explainStaleEpoch, tasks_lease.go).
		if rc == exitConflict && staleEpochReasons[out.lastErrorCode] {
			if req, ok := closeRequestOf(cmd, tail); ok {
				explainStaleEpoch(out, ctx, req.docID, req.worker)
			}
		}
		return rc
	}
	req, ok := closeRequestOf(cmd, tail)
	if !ok {
		return rc
	}
	if rc == exitServer {
		out.errf("the close POST answered a server error (exit %d) — checking the store before trusting that as \"nothing landed\" (a 5xx can hide a write that already committed)", rc)
	}

	stored, readback, err := taskboard.FetchSeal(taskReadbackClient(ctx), req.docID)
	if err != nil {
		// ONE BOUNDED SECOND LOOK, the twin of stamp's
		// (stampReadbackRetryDelay). A read-back that lost a single race under
		// load is not a store with no answer, and close had no retry here at
		// all: a lone unlucky GET turned an ordinary close into a hedge.
		time.Sleep(closeReadbackRetryDelay)
		stored, readback, err = taskboard.FetchSeal(taskReadbackClient(ctx), req.docID)
	}
	if err != nil {
		// NOT "the seal may or may not have landed". The store is what "landed"
		// means and it did not answer, twice, so the only honest word is
		// UNVERIFIED — and the receipt has to NAME the thing it could not read
		// rather than imply a verdict it never earned.
		//
		// The remedy differs from stamp's on purpose. A stamp is idempotent, so
		// stamp says "re-stamp, it costs nothing". A CLOSE IS NOT: a second
		// close of a sealed row 409s `not_ready`, which is exactly what makes a
		// correctly closed row read as uncloseable. So this says READ, then
		// decide — never "close again".
		out.userErr("close UNVERIFIED — the POST was accepted but the store could not be re-read, twice: %v", err)
		out.errf("  nothing here says the seal landed and nothing here says it did not: no row was read, so this receipt makes NO claim about %s", req.docID)
		out.errf("  read the row before acting: `bp task get %s -o json` — if it shows lifecycle_status=%s the close IS on the ledger and you are done", req.docID, req.wantSeal)
		out.errf("  do NOT simply close again on that reading: a second close of a sealed row 409s `not_ready`, and that refusal reads as an uncloseable task")
		if rc != exitOK {
			return rc
		}
		return exitGeneric
	}
	// THE ONE BOUNDED SECOND LOOK. The seal is there and the ONLY thing wrong is
	// a claim that still reads live. That is the one mismatch a read can invent
	// out of timing rather than out of state — every other one (a missing seal,
	// the wrong seal, a draft row) is a fact the store will keep repeating. Ask
	// once more, briefly, and only then call it half-landed: a refusal that
	// tells an operator to "close again" on a row the store already sealed
	// sends them into a 409, so this message has to earn itself twice.
	if closeClaimNeedsSecondLook(req, stored, readback) {
		time.Sleep(closeClaimRecheckDelay)
		if s2, rb2, err2 := taskboard.FetchSeal(taskReadbackClient(ctx), req.docID); err2 == nil {
			stored, readback = s2, rb2
		}
	}
	return renderCloseVerdict(out, req, stored, readback, rc)
}

// closeClaimRecheckDelay is the whole budget of the second look — short enough
// that an operator never notices it and a genuine half-landed close is still
// reported in the same breath, long enough to outlast a read that overtook a
// write. A var so tests can drive both arms without sleeping.
var closeClaimRecheckDelay = 400 * time.Millisecond

// closeReadbackRetryDelay is the budget of the read-back's OWN second look —
// the one spent when the store did not answer at all, rather than answered
// something unwelcome. Same size and same reasoning as
// stampReadbackRetryDelay: long enough to outlast a lost race, short enough
// that nobody waits on it. A var so tests drive both arms without sleeping.
var closeReadbackRetryDelay = 400 * time.Millisecond

// closeClaimNeedsSecondLook reports whether the ONLY complaint against the
// stored row is a claim that still looks live. Anything else — an absent seal,
// the wrong seal, a draft row — is state, not timing, and is refused on the
// first read.
func closeClaimNeedsSecondLook(req closeRequest, stored taskboard.SealRow, readback apiclient.TaskReadback) bool {
	if readback.IsDraft() {
		return false
	}
	return len(closeSealMismatches(req, stored)) == 0 &&
		closeClaimIsLive(req, stored, readback)
}

// closeRequestOf re-resolves the close invocation through the SAME splitArgs +
// bindArgs the dispatch used, so the row the read-back targets can never drift
// from the one the POST carried.
func closeRequestOf(cmd manifest.Command, forward []string) (closeRequest, bool) {
	pos, _, err := splitArgs(cmd, forward)
	if err != nil {
		return closeRequest{}, false
	}
	argMap, err := bindArgs(cmd, pos)
	if err != nil {
		return closeRequest{}, false
	}
	docID := strings.TrimSpace(argMap["doc_id"])
	if docID == "" {
		return closeRequest{}, false
	}
	// The manifest documents lifecycle_status as optional, "defaults to done
	// when omitted" — mirror that default rather than leaving the expected seal
	// empty, or an omitted status would make every close unfalsifiable.
	seal := strings.TrimSpace(argMap["lifecycle_status"])
	if seal == "" {
		seal = "done"
	}
	return closeRequest{
		docID:    docID,
		worker:   strings.TrimSpace(argMap["worker_id"]),
		wantSeal: seal,
		reason:   strings.TrimSpace(argMap["reason"]),
	}, true
}

// ── the seal slot ───────────────────────────────────────────────────────────

// closeLifecycleStatuses is the legal set for `bp task close`'s
// lifecycle_status, and it is the ONE place this CLI states it: the MCP
// task_close JSON Schema splices closeLifecycleStatusEnumJSON rather than
// carrying its own copy, so the guard below and the schema an agent reads can
// never disagree (mcp_tasks.go). It mirrors the server's own transition table
// (Tasks.Close, `invalid_lifecycle`).
var closeLifecycleStatuses = []string{"done", "cancelled", "blocked"}

// closeLifecycleStatusEnumJSON is closeLifecycleStatuses as a JSON array,
// spliced into the MCP task_close schema.
var closeLifecycleStatusEnumJSON = func() string {
	b, err := json.Marshal(closeLifecycleStatuses)
	if err != nil {
		// Unreachable for a []string; a panic here would be a build-time typo,
		// not a runtime condition.
		return `["done", "cancelled", "blocked"]`
	}
	return string(b)
}()

// isCloseLifecycleStatus reports whether s is a status a close may name.
func isCloseLifecycleStatus(s string) bool {
	for _, ok := range closeLifecycleStatuses {
		if s == ok {
			return true
		}
	}
	return false
}

// refuseCloseSealSentence catches the most common way this verb is mistyped:
// the positional shape is
//
//	bp task close <id> <worker> <epoch> <lifecycle_status> [reason]
//
// and the reason is the FIFTH positional, so
//
//	bp task close task-x w1 7 "the fix merged in #123"
//
// binds that sentence to lifecycle_status. Left alone it is POSTed, and the
// server answers `invalid_lifecycle:the fix merged in #123` — a refusal that
// names the sentence but never says the slot was wrong.
//
// It refuses LOCALLY, before the request, so the operator gets the whole
// diagnosis in one round trip and nothing is written. And it refuses rather
// than COERCING the sentence into a `done` close: a seal this CLI invented on
// the operator's behalf is a seal nobody asked for, and `done` is not
// recoverable from — it would fabricate the very thing the ledger exists to
// record. Exit is exitValidation, the SAME code the server's
// `invalid_lifecycle` carries (errors.go), so a retry wrapper reads the local
// refusal exactly as it reads the remote one: the request is wrong, re-sending
// it cannot help.
//
// An invocation splitArgs/bindArgs cannot resolve is NOT this bug — the
// dispatch's own usage error is the better message — so it falls through.
func refuseCloseSealSentence(out *writer, cmd manifest.Command, tail []string) (int, bool) {
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return 0, false
	}
	argMap, err := bindArgs(cmd, pos)
	if err != nil {
		return 0, false
	}
	seal := strings.TrimSpace(argMap["lifecycle_status"])
	// An OMITTED status is legal — the server defaults it to done.
	if seal == "" || isCloseLifecycleStatus(seal) {
		return 0, false
	}
	docID := strings.TrimSpace(argMap["doc_id"])
	worker := strings.TrimSpace(argMap["worker_id"])
	epoch := strings.TrimSpace(argMap["observed_epoch"])
	reason := strings.TrimSpace(argMap["reason"])

	out.userErr("close REFUSED before it was sent — %q is not a lifecycle_status", seal)
	out.errf("  the 4th positional is the SEAL, not the reason. Legal values: %s.", strings.Join(closeLifecycleStatuses, ", "))
	if reason == "" {
		out.errf("  you typed:   bp task close %s %s %s %q", docID, worker, epoch, seal)
		out.errf("  you meant:   bp task close %s %s %s done %q", docID, worker, epoch, seal)
		out.errf("  the reason is the FIFTH positional — it goes AFTER the seal.")
	} else {
		out.errf("  you typed:   bp task close %s %s %s %q %q", docID, worker, epoch, seal, reason)
		out.errf("  you meant:   bp task close %s %s %s done %q", docID, worker, epoch, reason)
		out.errf("  two reasons were passed where a seal and a reason belong — keep ONE, in the 5th slot.")
	}
	out.errf("  nothing was sent: the server would have answered `invalid_lifecycle:%s` (exit %d) and written nothing.", seal, exitValidation)
	out.errf("  refusing rather than assuming `done` — a seal this CLI invented is a seal nobody asked for.")
	return exitValidation, true
}

// ── a stale_claim that landed ───────────────────────────────────────────────

// closeLandedDespiteStaleClaim performs the ONE extra read the `stale_claim`
// arm buys, and reports (exit code, true) only when the store proves this
// close is on the ledger. It returns false — leaving the 409 to stand exactly
// as reported — for every other outcome, including a read it could not make:
// "we could not ask" is never "it landed".
func closeLandedDespiteStaleClaim(out *writer, ctx manifest.Context, req closeRequest, origRC int) (int, bool) {
	stored, readback, err := taskboard.FetchSeal(taskReadbackClient(ctx), req.docID)
	if err != nil {
		out.errf("  the store could not be re-read (%v), so the `stale_claim` above stands as reported", err)
		return 0, false
	}
	if readback.IsDraft() {
		return 0, false
	}
	if !closeStaleClaimLanded(req, stored, readback) {
		out.errf("  the store was re-read and the close is genuinely ABSENT — it holds %s", storedSealSummary(stored))
		out.errf("  re-claim it (`bp task next` / `bp task claim`) for a fresh epoch and close again")
		return 0, false
	}
	out.progressf("✓ the close LANDED despite the server answering `stale_claim` (exit %d) — the store was re-read and holds THIS close, reason and all; the 409 described the lease, not the write", origRC)
	out.progressf("✓ the store holds it — %s", storedSealSummary(stored))
	out.progressf("  do NOT re-claim and retry: a second close of a sealed row 409s `not_ready`, which is what makes this failure read as an uncloseable task")
	return exitOK, true
}

// closeStaleClaimLanded is the pure test behind that verdict, and it is
// deliberately narrow — a false SUCCESS here would tell an operator their work
// is sealed when it is not, which is strictly worse than the bug it fixes.
//
// Two facts must BOTH hold:
//
//  1. the stored lifecycle_status is a legal close seal AND is the exact one
//     this invocation asked for. A terminal row carrying somebody else's seal
//     is not this close landing.
//  2. the row carries THIS close's fingerprint. When a reason was sent, the
//     stored `content.close_reason` must match it verbatim — the reason is
//     free text the caller authored, so a match is as close to an identity as
//     this ledger offers. When NO reason was sent there is nothing to match,
//     so it falls back to the close-out stamp the server writes in the same
//     atomic update (closeClaimIsSettled), which names the worker THIS close
//     was made with.
func closeStaleClaimLanded(req closeRequest, stored taskboard.SealRow, readback apiclient.TaskReadback) bool {
	if !isCloseLifecycleStatus(stored.LifecycleStatus) || stored.LifecycleStatus != req.wantSeal {
		return false
	}
	if req.reason != "" {
		return strings.TrimSpace(storedCloseReason(readback)) == req.reason
	}
	return closeClaimIsSettled(req, readback)
}

// storedCloseReason reads `content.close_reason` off the read-back — the field
// the server writes the close's reason into (Tasks.Close.apply_close_update).
// It is decoded here rather than added to taskboard.SealRow because only this
// one comparison needs it.
func storedCloseReason(readback apiclient.TaskReadback) string {
	if len(readback.Content) == 0 {
		return ""
	}
	var content struct {
		CloseReason string `json:"close_reason"`
	}
	if json.Unmarshal(readback.Content, &content) != nil {
		return ""
	}
	return content.CloseReason
}

// renderCloseVerdict is the close's receipt, and it is PURE: given the request
// and the row the store handed back, it prints the verdict and returns the exit
// code. Every claim it makes is read off `stored`; the requested seal appears
// only as the "expected" half of a contradiction, never as the answer.
func renderCloseVerdict(out *writer, req closeRequest, stored taskboard.SealRow, readback apiclient.TaskReadback, origRC int) int {
	if readback.IsDraft() {
		out.userErr("close landed on a DRAFT, not the board — %s answered this read-back", readbackRowLabel(readback))
		out.errf("  `%s` has no published row, so no board will ever show this seal", req.docID)
		out.errf("  the draft holds: %s", storedSealSummary(stored))
		return exitConflict
	}

	mismatches := closeMismatches(req, stored, readback)
	if len(mismatches) == 0 {
		if origRC == exitServer {
			out.progressf("✓ the store holds the seal despite the POST answering a server error (exit %d) — a 5xx can commit the write before the response fails; the read-back is the truth here, not the transport error", origRC)
		}
		out.progressf("✓ the store holds it — %s", storedSealSummary(stored))
		reportCloseReasonReplaced(out, req, readback)
		return exitOK
	}
	out.userErr("close NOT confirmed by the store — the seal did not land as asked")
	out.errf("  expected lifecycle_status: %q", req.wantSeal)
	out.errf("  the store holds:           %s", storedSealSummary(stored))
	for _, m := range mismatches {
		out.errf("  ✗ %s", m)
	}
	out.errf("  a close is only real once the store holds it — re-read with `bp task get %s` and close again", req.docID)
	return exitConflict
}

// reportCloseReasonReplaced is the ONE remaining way a 2xx close can be
// accepted-but-not-persisted on today's server, and it is named rather than
// papered over.
//
// `Tasks.Close.close_with_receipt/3` has an idempotent-replay arm
// (api/lib/barkpark/tasks/close.ex:441, `{:already_closed, doc}`), reached when
// the row is ALREADY terminal and `idempotent_replay?/3` (close.ex:565) says
// yes. That predicate compares exactly two things — `claim.closed_by == worker`
// and `lifecycle_status == new_status` — and NOTHING ELSE. The reason is not in
// it. So a second close by the same worker to the same seal with a DIFFERENT
// reason gets a 200 and the server writes nothing: the stored row keeps the
// FIRST close's `content.close_reason`, byte-identical, by design
// (close.ex:428-433).
//
// The seal itself is genuinely on the ledger, so this is NOT a refusal: exiting
// non-zero here would send the operator into a re-close that 409s `not_ready`
// on an already-terminal row — the exact failure the replay arm exists to
// prevent. What it IS is a receipt that must not let the caller read their own
// sentence back out of a row that does not hold it. So the ✓ stands for the
// seal, and this line names the divergence beside it.
//
// Silent when no reason was sent (nothing to diverge), when the row carries no
// close_reason to compare, or when they match.
func reportCloseReasonReplaced(out *writer, req closeRequest, readback apiclient.TaskReadback) {
	if req.reason == "" {
		return
	}
	storedReason := strings.TrimSpace(storedCloseReason(readback))
	if storedReason == "" || storedReason == req.reason {
		return
	}
	out.errf("! the SEAL landed but YOUR REASON DID NOT — the store holds another close's reason on this row")
	out.errf("  you sent:        %q", req.reason)
	out.errf("  the store holds: %q", storedReason)
	out.errf("  this is the server's idempotent-replay arm: a row already closed by %s to %s answers 200 and writes NOTHING, keeping the first close's reason", req.worker, req.wantSeal)
	out.errf("  the task IS closed — do NOT close again (a second close of a sealed row 409s `not_ready`). To change the note, patch the row rather than re-closing it.")
}

// storedSealSummary describes the row AS STORED. The criteria count rides along
// because close writes criteria in the same atomic update, so a seal that landed
// while the criteria did not is visible rather than merely possible.
func storedSealSummary(stored taskboard.SealRow) string {
	seal := stored.LifecycleStatus
	if seal == "" {
		seal = "<the server named no lifecycle_status>"
	}
	s := fmt.Sprintf("lifecycle_status=%s  criteria %d/%d met", seal, stored.Met, stored.Total)
	if stored.ClaimWorker != "" {
		s += fmt.Sprintf("  claim still held by %s", stored.ClaimWorker)
	}
	return s
}

// closeMismatches is the pure comparison behind the verdict: every way the
// stored row fails to be the close that was asked for. An empty result means the
// store genuinely holds the seal.
func closeMismatches(req closeRequest, stored taskboard.SealRow, readback apiclient.TaskReadback) []string {
	out := closeSealMismatches(req, stored)
	if closeClaimIsLive(req, stored, readback) {
		out = append(out, fmt.Sprintf("the row is sealed but %s STILL HOLDS the claim — the close half-landed", stored.ClaimWorker))
	}
	return out
}

// closeSealMismatches is the SEAL half of the comparison — the part that is pure
// state and never worth a second read.
func closeSealMismatches(req closeRequest, stored taskboard.SealRow) []string {
	var out []string
	switch {
	case stored.LifecycleStatus == "":
		// Not a mismatch we can assert either way — say so rather than call a
		// silent server a failed close.
		out = append(out, "the read-back carried NO lifecycle_status, so the seal could not be confirmed — this is an unchecked close, not a landed one")
	case stored.LifecycleStatus != req.wantSeal:
		out = append(out, fmt.Sprintf("lifecycle_status is %q in the store, not the %q that was asked for — the close did not land",
			stored.LifecycleStatus, req.wantSeal))
	}
	return out
}

// closeClaimIsLive is the CLAIM half: a live claim under a sealed row is a
// half-landed close — the seal took and the lease release did not, so the board
// shows a closed task somebody still holds.
//
// A NAMED WORKER IS NOT A LIVE LEASE, and reading it as one is how this check
// spent its first life crying wolf on every ordinary close. The server does not
// delete `content.claim` when it seals a row: `Tasks.Close.apply_close_update/9`
// KEEPS the map and stamps `closed_by` + `closed_at` onto it in the SAME atomic
// write as `lifecycle_status`, deliberately, so a closed row still says who did
// the work and when. `claim.worker` therefore survives every successful close —
// a sealed row that names a worker is the NORMAL shape, not a broken one. Only
// a claim with NO close-out stamp is a lease the close failed to settle, and
// that is the row this refuses.
func closeClaimIsLive(req closeRequest, stored taskboard.SealRow, readback apiclient.TaskReadback) bool {
	if stored.ClaimWorker == "" || stored.LifecycleStatus != req.wantSeal {
		return false
	}
	return !closeClaimIsSettled(req, readback)
}

// closeClaimIsSettled decodes the close-out stamp off the raw `doc.claim` the
// read-back carried. It reads the RAW claim rather than taskboard.SealRow
// because the stamp is the server's own record of THIS close: `closed_by` is the
// worker id the close was made with, written in the same rev-CAS update as the
// seal, so a stamp naming this worker cannot be present unless the close landed
// whole.
//
// `closed_at` alone also settles it — a server that stamped the timestamp and
// not the id has still recorded a close-out, and inventing a half-landed close
// out of a missing id would be the same false red in a smaller costume.
func closeClaimIsSettled(req closeRequest, readback apiclient.TaskReadback) bool {
	if len(readback.Claim) == 0 {
		return false
	}
	var claim struct {
		ClosedBy string `json:"closed_by"`
		ClosedAt string `json:"closed_at"`
	}
	if json.Unmarshal(readback.Claim, &claim) != nil {
		return false
	}
	closedBy := strings.TrimSpace(claim.ClosedBy)
	if closedBy != "" {
		// When the close named a worker, the stamp has to name the SAME one —
		// an older close-out stamp left by somebody else settles nothing about
		// this one.
		if w := strings.TrimSpace(req.worker); w != "" {
			return closedBy == w
		}
		return true
	}
	return strings.TrimSpace(claim.ClosedAt) != ""
}

// ── pulse ───────────────────────────────────────────────────────────────────

// pulseRequest is what the caller ASKED the ledger to write.
type pulseRequest struct {
	docID   string
	worker  string
	wantNow string
}

// runTaskPulse wraps the manifest `task pulse` verb with the read-back.
func runTaskPulse(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	rc := runCommand(out, g, ctx, m, cmd, tail)

	if g.dryRun || (rc != exitOK && rc != exitServer) {
		return rc
	}
	req, ok := pulseRequestOf(cmd, tail)
	if !ok {
		return rc
	}
	if rc == exitServer {
		out.errf("the pulse POST answered a server error (exit %d) — checking the store before trusting that as \"nothing landed\" (a 5xx can hide a write that already committed)", rc)
	}

	stored, readback, err := taskboard.FetchPulse(taskReadbackClient(ctx), req.docID)
	if err != nil {
		out.userErr("pulse sent but NOT confirmed — the read-back of %s failed: %v", req.docID, err)
		out.errf("  the now-line may or may not have landed; re-read with `bp task get %s` before trusting it", req.docID)
		if rc != exitOK {
			return rc
		}
		return exitGeneric
	}
	return renderPulseVerdict(out, req, stored, readback, rc)
}

// pulseRequestOf re-resolves the pulse invocation through the SAME splitArgs +
// bindArgs the dispatch used.
func pulseRequestOf(cmd manifest.Command, forward []string) (pulseRequest, bool) {
	pos, flags, err := splitArgs(cmd, forward)
	if err != nil {
		return pulseRequest{}, false
	}
	argMap, err := bindArgs(cmd, pos)
	if err != nil {
		return pulseRequest{}, false
	}
	docID := strings.TrimSpace(argMap["doc_id"])
	if docID == "" {
		return pulseRequest{}, false
	}
	now := ""
	if v := flags["now"]; len(v) > 0 {
		now = v[len(v)-1]
	}
	if strings.TrimSpace(now) == "" {
		// No now-line was sent, so there is no specific line to confirm. The
		// dispatch has already reported whatever was wrong with the invocation.
		return pulseRequest{}, false
	}
	return pulseRequest{
		docID:   docID,
		worker:  strings.TrimSpace(argMap["worker_id"]),
		wantNow: now,
	}, true
}

// renderPulseVerdict is the pulse's receipt, and it is PURE. The claim to be
// backed is narrow and exact: the now-line the store holds is the one just
// written. A pulse that renewed a lease but left a stale now-line on the board
// is the failure this reads for.
func renderPulseVerdict(out *writer, req pulseRequest, stored taskboard.PulseRow, readback apiclient.TaskReadback, origRC int) int {
	if readback.IsDraft() {
		out.userErr("pulse landed on a DRAFT, not the board — %s answered this read-back", readbackRowLabel(readback))
		out.errf("  `%s` has no published row, so no board will ever show this now-line", req.docID)
		out.errf("  the draft holds: %s", storedPulseSummary(stored))
		return exitConflict
	}

	mismatches := pulseMismatches(req, stored)
	if len(mismatches) == 0 {
		if origRC == exitServer {
			out.progressf("✓ the store holds the now-line despite the POST answering a server error (exit %d) — a 5xx can commit the write before the response fails; the read-back is the truth here, not the transport error", origRC)
		}
		out.progressf("✓ the store holds it — %s", storedPulseSummary(stored))
		// THE NEW EPOCH, said out loud. storedPulseSummary already carried it
		// inside a claim summary, where it read as a description of the lease
		// rather than as the number the next stamp/close must pass — and a
		// builder holding the epoch it was handed at claim time has no cue that
		// its own heartbeat just invalidated it.
		if stored.ClaimEpoch > 0 {
			out.progressf("  the pulse ADVANCED the claim epoch to %d — pass %d to the next `bp task stamp` / `bp task close`; the epoch you were given at claim time is now stale",
				stored.ClaimEpoch, stored.ClaimEpoch)
		}
		return exitOK
	}
	out.userErr("pulse NOT confirmed by the store — the now-line did not land as asked")
	out.errf("  expected now-line: %q", truncateCell(req.wantNow, 72))
	out.errf("  the store holds:   %s", storedPulseSummary(stored))
	for _, m := range mismatches {
		out.errf("  ✗ %s", m)
	}
	out.errf("  a pulse is only real once the board can read it — re-read with `bp task get %s` and pulse again", req.docID)
	return exitConflict
}

// storedPulseSummary describes the claim AS STORED.
func storedPulseSummary(stored taskboard.PulseRow) string {
	now := "now-line <none>"
	if stored.Now != nil {
		now = fmt.Sprintf("now-line %q", truncateCell(stored.Now.Text, 48))
	}
	s := now
	if stored.ClaimWorker != "" {
		s += fmt.Sprintf("  claim %s epoch=%d", stored.ClaimWorker, stored.ClaimEpoch)
	}
	return s
}

// pulseMismatches is the pure comparison behind the verdict.
func pulseMismatches(req pulseRequest, stored taskboard.PulseRow) []string {
	var out []string
	switch {
	case stored.Now == nil:
		out = append(out, "the store holds NO now-line on that claim — the pulse did not land")
	case strings.TrimSpace(stored.Now.Text) != strings.TrimSpace(req.wantNow):
		out = append(out, fmt.Sprintf("the stored now-line is a DIFFERENT line than the one sent (%d bytes stored vs %d sent) — the board is showing someone else's pulse, or an older one",
			len(stored.Now.Text), len(req.wantNow)))
	}
	if w := strings.TrimSpace(req.worker); w != "" && stored.ClaimWorker != "" && stored.ClaimWorker != w {
		out = append(out, fmt.Sprintf("the claim is held by %s, not %s — the lease this pulse thought it renewed belongs to someone else", stored.ClaimWorker, w))
	}
	return out
}

// taskReadbackClient builds the client the task read-backs share, constructed
// identically to every other one in the CLI. Perspective is inert for these
// calls — GET /v1/tasks/:doc_id is the flat, token-scoped task route and carries
// no perspective query param; the `drafts.` fallback is a SERVER behaviour on
// that route, not something this field selects (see renderStampVerdict).
func taskReadbackClient(ctx manifest.Context) *apiclient.Client {
	return apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: "drafts",
	})
}
