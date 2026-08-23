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

import (
	"fmt"
	"strings"

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
}

// runTaskClose wraps the manifest `task close` verb with the read-back. The POST
// itself is untouched — every dispatch, render and guard stays shared with the
// generic path.
func runTaskClose(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	rc := runCommand(out, g, ctx, m, cmd, tail)

	// Same skip rule as stamp: --dry-run sent nothing, and every non-2xx other
	// than a 5xx is the server refusing BEFORE any commit. A 5xx IS re-read —
	// "a 500 can hide a write that landed" — so an 8 is never taken as proof
	// the seal is absent.
	if g.dryRun || (rc != exitOK && rc != exitServer) {
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
		out.userErr("close sent but NOT confirmed — the read-back of %s failed: %v", req.docID, err)
		out.errf("  the seal may or may not have landed; re-read with `bp task get %s` before trusting it", req.docID)
		if rc != exitOK {
			return rc
		}
		return exitGeneric
	}
	return renderCloseVerdict(out, req, stored, readback, rc)
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
	}, true
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

	mismatches := closeMismatches(req, stored)
	if len(mismatches) == 0 {
		if origRC == exitServer {
			out.progressf("✓ the store holds the seal despite the POST answering a server error (exit %d) — a 5xx can commit the write before the response fails; the read-back is the truth here, not the transport error", origRC)
		}
		out.progressf("✓ the store holds it — %s", storedSealSummary(stored))
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
func closeMismatches(req closeRequest, stored taskboard.SealRow) []string {
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
	// A live claim under a sealed row is a half-landed close: the seal took and
	// the lease release did not, so the board shows a closed task somebody still
	// holds.
	if stored.ClaimWorker != "" && stored.LifecycleStatus == req.wantSeal {
		out = append(out, fmt.Sprintf("the row is sealed but %s STILL HOLDS the claim — the close half-landed", stored.ClaimWorker))
	}
	return out
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
