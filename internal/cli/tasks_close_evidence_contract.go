package cli

// tasks_close_evidence_contract.go — THE CLOSE-PROSE CONTRACT.
//
// (search vocabulary: close-prose contract, uncheckable close, anchorless close,
//  close evidence anchor, what a close must name, unfalsifiable close. NOT stamped
//  @canonical: every entry point here is package-private, and docs-anchors-check.sh
//  section 8 requires a marker to sit above a PUBLIC one.)
//
// WHY THIS FILE EXISTS. scripts/closed-row-tree-disagreement-sweep.mjs asks one
// question of a CLOSED row: does its close_reason assert a change origin/main
// does not carry? It can only ask that of a reason that NAMES something the
// tree can be queried for. A reason that names nothing is not scored AGREE and
// is not scored DISAGREE — it is scored UNCHECKABLE, and it is the single
// largest bucket in the closed population.
//
//	A CLOSE WHOSE EVIDENCE NAMES NOTHING CAN NEVER BE CONTRADICTED BY THE TREE.
//
// That is not a tooling gap. No instrument can ever close it, because there is
// nothing in the prose to resolve. It is a contract question about what a close
// must WRITE DOWN, and this file is the ruling. Filed as
// task-dfa5723c433382b3.
//
// ── THE RULING (2026-09-13) ────────────────────────────────────────────────
//
// 1. CHECKABLE means the reason names at least ONE tree-resolvable anchor:
//
//      a REPO PATH    a repo-relative file path with a known extension and no
//                     elided segment — `api/lib/barkpark/tasks/close.ex`, never
//                     `api/lib/.../close.ex` (an elided path drops exactly the
//                     segments that would resolve it);
//      a SYMBOL       an Elixir MFA (`Barkpark.Tasks.Criteria.merge_gated?/1`)
//                     or a backticked identifier of 4+ characters that is not a
//                     ubiquitous callback (`id`, `init`, `run` discriminate
//                     nothing and cannot support a verdict either way);
//      a COMMIT SHA   a 7-40 hex token carrying at least one letter AND one
//                     digit, which is an ancestor of main.
//
//    Any one of the three is enough. All three are what the sweep's three arms
//    read, so this definition and that instrument are the same definition.
//
// 2. NAMING NOTHING IS NOT AN ERROR, IT IS AN UNFALSIFIABLE CLOSE. A reason
//    like "closed as duplicate of the earlier row, nothing shipped" may be
//    perfectly true. What it cannot ever be is CHECKED. The cost is paid later,
//    by whoever needs to know whether the defect the row described is still
//    live, and finds a record that says it was handled and nothing that can
//    disagree.
//
// 3. THE ROWS ALREADY CLOSED WITHOUT AN ANCHOR ARE RECORDED AS PERMANENTLY
//    UNCHECKABLE. They are NOT migrated and NOT re-checked by proxy. An anchor
//    back-filled today is authored by the READER, not by the closer: it records
//    what a later reader believes the close meant, and the sweep would then
//    score it AGREE — converting an honest, visible blind spot into a false
//    green. The count is re-derived by the sweep on every run and printed as
//    its named blind spot; THAT PRINTED NUMBER IS THE RECORD, and it re-derives
//    itself rather than rotting in a doc.
//
// 4. THE CONTRACT BINDS BY ADVISORY, NOT BY REFUSAL. Every close that lands
//    today keeps its exit code; an anchorless reason earns a stderr note beside
//    the ✓ and nothing more. A caller that wants the refusal opts in with
//    BARKPARK_CLOSE_REQUIRE_ANCHOR=1, which refuses BEFORE the POST — the same
//    staged shape `--expect` shipped opt-in on `bp task stamp`. Shipping a
//    mandatory refusal in the same breath as the ruling would break every
//    existing scripted caller for a rule none of them has read yet.
//
// ── END RULING ─────────────────────────────────────────────────────────────

import (
	"os"
	"regexp"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// closeContractRuling is the ruling as the operator sees it — ONE source of
// text for `bp task close --help` and for the advisory printed beside a ✓. Two
// copies of a rule drift; this one cannot.
var closeContractRuling = []string{
	"THE CLOSE-PROSE CONTRACT — what a close must NAME to be checkable",
	"",
	"  A close whose reason names nothing can never be contradicted by the tree.",
	"  scripts/closed-row-tree-disagreement-sweep.mjs scores it UNCHECKABLE: not",
	"  AGREE, not DISAGREE — unfalsifiable.",
	"",
	"  A reason is CHECKABLE when it names at least ONE of:",
	"    a REPO PATH   api/lib/barkpark/tasks/close.ex   (never api/lib/.../close.ex —",
	"                  an elided path drops the segments that would resolve it)",
	"    a SYMBOL      Barkpark.Tasks.Criteria.merge_gated?/1, or `merge_gated?` —",
	"                  4+ chars and not a ubiquitous callback (`id`, `init`, `run`)",
	"    a COMMIT SHA  7-40 hex with a letter AND a digit, an ancestor of main",
	"",
	"  Rows already closed without an anchor are PERMANENTLY UNCHECKABLE. They are",
	"  not migrated and not re-checked by proxy: an anchor back-filled today is",
	"  authored by the reader, not the closer, and would turn an honest blind spot",
	"  into a false AGREE. The sweep re-derives and prints that count on every run;",
	"  that printed number is the record.",
	"",
	"  This binds by ADVISORY, not refusal — your exit code is unchanged. Set",
	"  BARKPARK_CLOSE_REQUIRE_ANCHOR=1 to opt into the refusal instead.",
}

// ── the anchor detector, mirroring the sweep's three arms ───────────────────

var (
	reCloseAnchorPath     = regexp.MustCompile(`(?:\.?[A-Za-z0-9_.\-]+/)+[A-Za-z0-9_.\-]+\.(?:go|ex|exs|heex|sh|mjs|js|ts|tsx|json|yml|yaml|md|sql)\b`)
	reCloseAnchorMFA      = regexp.MustCompile(`\b[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*\.([a-z_][A-Za-z0-9_?!]*)/\d\b`)
	reCloseAnchorBacktick = regexp.MustCompile("`([A-Za-z_][A-Za-z0-9_.?!]{3,})`")
	reCloseAnchorHex      = regexp.MustCompile(`\b[0-9a-f]{7,40}\b`)
	reCloseAnchorElided   = regexp.MustCompile(`^\.{2,}$`)
)

// closeAnchorArtifactSegments are directories the repo never commits, so a path
// rooted in one names nothing the tree can be asked for.
var closeAnchorArtifactSegments = map[string]bool{
	"node_modules": true, "dist": true, "_build": true, "deps": true,
	"coverage": true, "build": true, ".turbo": true,
}

// closeAnchorGenericSymbols is the sweep's denylist verbatim: a name this
// ubiquitous matches everything or nothing, so it cannot support a verdict in
// either direction and is not an anchor.
var closeAnchorGenericSymbols = map[string]bool{
	"id": true, "get": true, "put": true, "new": true, "run": true, "call": true,
	"init": true, "key": true, "all": true, "one": true, "add": true, "set": true,
	"map": true, "url": true, "ok": true, "do": true, "up": true, "down": true,
	"start": true, "stop": true, "name": true, "type": true, "list": true,
	"show": true, "main": true, "test": true, "path": true, "text": true, "data": true,
}

// closeAnchorIsElidedPath reports whether a path token abbreviates its own
// middle (`api/lib/.../close.ex`). Such a token is UNCHECKABLE BY CONSTRUCTION.
func closeAnchorIsElidedPath(p string) bool {
	for _, seg := range strings.Split(p, "/") {
		if reCloseAnchorElided.MatchString(seg) {
			return true
		}
	}
	return false
}

// closeAnchorIsGenericSymbol mirrors isGenericSymbol in the sweep.
func closeAnchorIsGenericSymbol(s string) bool {
	t := strings.TrimSpace(s)
	return len(t) < 4 || closeAnchorGenericSymbols[strings.ToLower(t)]
}

func closeAnchorLooksLikeSha(tok string) bool {
	if len(tok) < 7 || len(tok) > 40 {
		return false
	}
	return strings.ContainsAny(tok, "abcdef") && strings.ContainsAny(tok, "0123456789")
}

// closeReasonAnchors returns every tree-resolvable anchor the reason names, in
// arm order (paths, then symbols, then shas). EMPTY means the close is
// UNCHECKABLE under the ruling above.
func closeReasonAnchors(reason string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(s string) {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, p := range reCloseAnchorPath.FindAllString(reason, -1) {
		if closeAnchorIsElidedPath(p) {
			continue
		}
		bad := false
		for _, seg := range strings.Split(p, "/") {
			if closeAnchorArtifactSegments[seg] {
				bad = true
			}
		}
		if !bad {
			add(p)
		}
	}
	for _, m := range reCloseAnchorMFA.FindAllStringSubmatch(reason, -1) {
		if !closeAnchorIsGenericSymbol(m[1]) {
			add(m[1])
		}
	}
	for _, m := range reCloseAnchorBacktick.FindAllStringSubmatch(reason, -1) {
		s := m[1]
		if strings.Contains(s, "/") {
			continue
		}
		if !closeAnchorIsGenericSymbol(s) {
			add(s)
		}
	}
	for _, s := range reCloseAnchorHex.FindAllString(reason, -1) {
		if closeAnchorLooksLikeSha(s) {
			add(s)
		}
	}
	return out
}

// closeReasonIsCheckable is the contract's predicate, stated once.
func closeReasonIsCheckable(reason string) bool {
	return len(closeReasonAnchors(reason)) > 0
}

// ── the two surfaces the next writer of a close actually hits ───────────────

// printCloseEvidenceContract appends the ruling to `bp task close --help`. The
// manifest renders the verb's arguments; this renders what the reason has to
// say to remain checkable, which no manifest carries.
func printCloseEvidenceContract(out *writer) {
	out.errf("")
	for _, line := range closeContractRuling {
		out.errf("%s", line)
	}
}

// reportUncheckableCloseReason is the advisory beside the ✓. It NEVER changes
// the exit code (see ruling §4): the seal landed, and a rule the caller has not
// read yet is not grounds to fail their close.
func reportUncheckableCloseReason(out *writer, req closeRequest) {
	if strings.TrimSpace(req.reason) == "" {
		return
	}
	if closeReasonIsCheckable(req.reason) {
		return
	}
	out.errf("! this close is UNCHECKABLE — its reason names no file path, no symbol and no commit sha")
	out.errf("  scripts/closed-row-tree-disagreement-sweep.mjs cannot ever contradict it: there is nothing in the prose to resolve against the tree")
	out.errf("  the seal landed and this changes nothing about it — see `bp task close --help` for the close-prose contract")
	out.errf("  next time, name one: a repo path, an MFA or backticked symbol, or a merged commit sha")
}

// closeAnchorRequired reports whether this caller opted into the REFUSAL arm
// (ruling §4). Default is off, and stays off: the advisory is the default
// because every existing scripted caller predates the contract.
func closeAnchorRequired() bool {
	v := strings.TrimSpace(os.Getenv("BARKPARK_CLOSE_REQUIRE_ANCHOR"))
	return v == "1" || strings.EqualFold(v, "true") || strings.EqualFold(v, "yes")
}

// refuseAnchorlessCloseReason is the opt-in refusal. It runs BEFORE the POST,
// in the same slot and the same shape as refuseBlankCancelReason, so an opted-in
// caller never writes a row it will be told off for afterwards.
func refuseAnchorlessCloseReason(out *writer, cmd manifest.Command, tail []string) (int, bool) {
	if !closeAnchorRequired() {
		return 0, false
	}
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return 0, false
	}
	argMap, err := bindArgs(cmd, pos)
	if err != nil {
		return 0, false
	}
	reason := strings.TrimSpace(argMap["reason"])
	if reason == "" || closeReasonIsCheckable(reason) {
		return 0, false
	}
	out.userErr("close REFUSED before it was sent — BARKPARK_CLOSE_REQUIRE_ANCHOR=1 and this reason names nothing the tree can be asked for")
	out.errf("  you sent: %q", reason)
	for _, line := range closeContractRuling {
		out.errf("  %s", line)
	}
	out.errf("  nothing was sent: the row is untouched.")
	return exitValidation, true
}
