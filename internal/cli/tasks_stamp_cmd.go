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
//  2. MERGE-GATE TRIPWIRE — refuse a `--met` whose `--criterion-text` carries
//     the MERGE-GATED marker unless the caller passes the CLI-only
//     `--merge-gated` override. That one flip is the only mis-index that
//     corrupts a lead's merge decision, so it earns an explicit door.
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
// The base is deliberately NOT flipped to 1-based: that is a breaking change
// for every existing script AND for the MCP tools (mcp_tasks.go) that already
// pass 0-based indices, and the D56 text-match guard makes a silent misroute
// impossible anyway. Documented-0-based + a translating echo is the
// least-surprise, fully-backward-compatible fix.
func runTaskStamp(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	sa, forward := parseStampArgs(tail)

	// MERGE-GATED tripwire: a met-flip on a lead-owned row without the explicit
	// override is refused, and NOTHING is sent to the server.
	if stampMergeGateBlocked(sa) {
		return useError(out, "merge_gated_criterion",
			"refusing to stamp a MERGE-GATED criterion met: --criterion-text carries the MERGE-GATED marker, and that row is the lead's to close (a builder flipping it fabricates a done before the PR exists). Pass --merge-gated to override only if you are the lead closing the gate.",
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
	// stamp the store did not hold. So after a successful POST, ASK THE STORE
	// what the row holds and render the verdict from THAT. --dry-run sent
	// nothing, and a non-zero POST already reported its own failure, so both
	// skip straight through.
	if rc != exitOK || g.dryRun {
		return rc
	}
	req, ok := stampRequestOf(cmd, forward)
	if !ok {
		// No usable --criterion index (the manifest dispatch has already
		// reported whatever was wrong with the invocation): there is no
		// specific row to re-read, so claim nothing extra about one.
		return rc
	}
	return confirmStampLanded(out, ctx, req)
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
	}, true
}

// confirmStampLanded performs the second read and renders its verdict. A
// read-back that cannot reach the store is reported as UNCONFIRMED and exits
// non-zero: "we could not ask" is not "it landed", and this verb's whole job
// this wave is to stop claiming the difference away.
func confirmStampLanded(out *writer, ctx manifest.Context, req stampRequest) int {
	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
		// Perspective is inert for this call: GET /v1/tasks/:doc_id is the flat,
		// token-scoped task route and carries no perspective query param. It is
		// set only so this client is constructed identically to every other one
		// in the CLI — the read-back always sees the row `bp task stamp` wrote,
		// which is the PUBLISHED one (PDS-D360).
		Perspective: "drafts",
	})
	stored, err := taskboard.FetchCriterion(client, req.docID, req.index)
	if err != nil {
		out.userErr("stamp sent but NOT confirmed — the read-back of %s criterion index %d failed: %v",
			req.docID, req.index, err)
		out.errf("  the write may or may not have landed; re-read with `bp task get %s` before trusting it", req.docID)
		return exitGeneric
	}
	return renderStampVerdict(out, req, stored)
}

// renderStampVerdict is the stamp's receipt, and it is PURE: given the request
// and the row the store handed back, it prints the verdict and returns the exit
// code. Every claim it makes is read off `stored` — the requested values appear
// only as the "expected" half of a contradiction, never as the answer. Hand it a
// row that disagrees and the receipt says so and exits non-zero.
//
// The receipt rides progressf: stdout in the human view, stderr under -o
// json/yaml so the dispatch's envelope stays the single parseable document on
// stdout. The exit code carries the verdict in both.
func renderStampVerdict(out *writer, req stampRequest, stored taskboard.CriterionItem) int {
	mismatches := stampMismatches(req, stored)
	if len(mismatches) == 0 {
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
	return s
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
	return out
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
	mergeGated    bool
}

// parseStampArgs pulls the criterion index, criterion-text, the met/miss
// outcome and the CLI-only --merge-gated override out of the stamp tail. It
// returns the parsed view AND a forward slice with --merge-gated removed —
// every OTHER token, order preserved, passes to the manifest dispatch verbatim,
// so the CLI never re-indexes --criterion (the index the builder types is the
// index the server receives). Both `--flag value` and `--flag=value` spellings
// are recognized. Parsing here is advisory only.
func parseStampArgs(tail []string) (stampArgs, []string) {
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
			continue // CLI-only: never forwarded to the server.
		case "--met":
			sa.met = true
		case "--miss":
			sa.miss = true
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

// stampMergeGateBlocked is the MERGE-GATED tripwire predicate: a --met whose
// --criterion-text carries the MERGE-GATED marker, with no --merge-gated
// override. --criterion-text is REQUIRED on every --met (D56), so this guard
// always has the text to inspect and needs no network round-trip. A --miss
// flips nothing and is never blocked.
func stampMergeGateBlocked(sa stampArgs) bool {
	return sa.met && !sa.mergeGated && isMergeGatedText(sa.criterionText)
}

// isMergeGatedText reports whether a criterion's wording carries the
// MERGE-GATED marker (the standard "[MERGE-GATED — the lead closes this]"
// row), case-insensitively and tolerant of a hyphen or space between the words.
func isMergeGatedText(s string) bool {
	u := strings.ToUpper(s)
	return strings.Contains(u, "MERGE-GATED") || strings.Contains(u, "MERGE GATED")
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
	}
	line := fmt.Sprintf("→ criterion index %d (0-based) = criterion #%d as boards/rubric number them → %s", idx, idx+1, outcome)
	if t := strings.TrimSpace(sa.criterionText); t != "" {
		line += fmt.Sprintf(": %q", truncateCell(t, 72))
	}
	return line
}
