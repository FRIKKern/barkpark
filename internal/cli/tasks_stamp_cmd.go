package cli

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
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
// 0-vs-1 base is still a trap. This wrapper does two CLI-only things the
// generic manifest dispatch cannot, then hands the actual POST to runCommand
// (so ALL of the dispatch/render/guard plumbing stays shared — zero drift):
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
	return runCommand(out, g, ctx, m, cmd, forward)
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
