package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runTaskLanded is the client-side wrapper around the manifest `task landed`
// verb. The POST rides runCommand UNCHANGED; this only RESOLVES the one value a
// caller cannot be trusted to type — the merge sha — and refuses rather than
// guessing when it cannot.
//
// WHY A RESOLVER AT ALL. `content.landed` is the structured row-to-PR link
// (`prs`, `commits`, and the paired `landings`), and the close artifact gate
// now reads it off the row instead of demanding it be retyped into prose. That
// makes the SHA the load-bearing half: a wrong one turns a machine-readable
// merge record into a machine-readable lie, and nothing downstream can tell.
// `.github/workflows/landed-mark.yml` never has this problem because it runs on
// the push and `GITHUB_SHA` IS the merge commit. Every OTHER caller — an
// operator repairing a merge CI missed, a lead crediting a sibling row — is
// typing a sha by hand off a terminal, and the sha that is on screen is almost
// always the BRANCH TIP.
//
// AND THE BRANCH TIP IS NEVER THE ANSWER IN THIS REPO, because it squash-merges.
// Measured on PR #17098 (branch cli/close-time-children), 2026-09-10:
//
//	$ gh api repos/FRIKKern/barkpark/compare/022dc4c44...main --jq .status
//	diverged                     # the branch TIP
//	$ gh api repos/FRIKKern/barkpark/compare/29b6c3e66...main --jq .status
//	ahead                        # mergeCommit.oid
//	$ git merge-base --is-ancestor 022dc4c44 origin/main ; echo $?
//	1
//	$ git merge-base --is-ancestor 29b6c3e66 origin/main ; echo $?
//	0
//
// A squash writes a NEW commit onto main; the branch's own head is on no branch
// anyone keeps, so it is not an ancestor of main and never becomes one. Recorded
// as the landing sha it produces a `content.landed` entry that cannot be
// ancestor-checked by any later reader — the exact "reconstruct it by hand next
// wave" cost the structured field exists to end.
//
// SO: `--pr N` WITHOUT `--commit` resolves N to `mergeCommit.oid` and says on
// stderr that it did. `--commit` given explicitly is passed through untouched —
// this wrapper never overrides a value a caller typed, because the repair cases
// include ones `gh` cannot answer (a PR from a fork whose merge this operator is
// crediting to a different row).
//
// EVERY FAILURE IS A REFUSAL, NEVER A FALLBACK. An unmerged PR, a `gh` that is
// absent or unauthenticated, a PR number that does not resolve — each returns
// exitUsage naming what happened. The tempting fallback (use `headRefOid`, it is
// right there in the same response) is precisely the defect: it would write the
// diverged sha silently, which is worse than writing nothing.
func runTaskLanded(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	pos, flags, err := splitArgs(cmd, tail)
	if err != nil {
		// Let the shared dispatch produce the canonical usage error — one
		// message for a malformed invocation, not two spellings of it.
		return runCommand(out, g, ctx, m, cmd, tail)
	}
	pr := lastFlagValue(flags, "pr")
	commit := lastFlagValue(flags, "commit")

	if pr != "" && commit == "" {
		sha, rerr := resolveMergeCommitOID(pr)
		if rerr != nil {
			return useError(out, "usage", rerr.Error(), exitUsage)
		}

		out.errf("note: PR #%s merged as %s — recording mergeCommit.oid, NOT the branch tip (a squash leaves the tip diverged from main forever).", pr, sha)
		tail = append(append([]string{}, tail...), "--commit", sha)
	}

	return landWithResolvedCriterion(out, g, ctx, m, cmd, tail, pos, flags)
}

// lastFlagValue reads the value splitArgs bound for a flag. Last wins, matching
// the request builder, so the wrapper and the POST can never disagree about
// which value was sent.
func lastFlagValue(flags map[string][]string, name string) string {
	vals := flags[name]
	if len(vals) == 0 {
		return ""
	}
	return strings.TrimSpace(vals[len(vals)-1])
}

// ghPRView is the seam the tests replace. Production runs `gh`; a test hands
// back a canned payload, so the resolution logic is exercised without a network
// or a GitHub token.
var ghPRView = func(pr string) ([]byte, error) {
	c, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(c, "gh", "pr", "view", pr, "--json", "number,state,mergedAt,mergeCommit,headRefName,headRefOid")
	return cmd.Output()
}

type ghPR struct {
	Number      int    `json:"number"`
	State       string `json:"state"`
	MergedAt    string `json:"mergedAt"`
	HeadRefName string `json:"headRefName"`
	HeadRefOid  string `json:"headRefOid"`
	MergeCommit *struct {
		OID string `json:"oid"`
	} `json:"mergeCommit"`
}

// resolveMergeCommitOID answers ONE question — which commit on main paid this
// PR — and answers it only when GitHub states the fact outright.
func resolveMergeCommitOID(pr string) (string, error) {
	raw, err := ghPRView(pr)
	if err != nil {
		return "", fmt.Errorf("could not read PR #%s through `gh pr view` (%v) — pass --commit <merge sha> explicitly, or run this where `gh` is installed and authenticated. A landing sha is never guessed", pr, err)
	}

	var p ghPR
	if jerr := json.Unmarshal(raw, &p); jerr != nil {
		return "", fmt.Errorf("could not parse `gh pr view %s --json ...` output (%v) — pass --commit <merge sha> explicitly", pr, jerr)
	}

	if p.MergeCommit == nil || strings.TrimSpace(p.MergeCommit.OID) == "" {
		// NAME THE TIP AND REFUSE IT IN THE SAME BREATH. The operator is
		// looking at that sha; saying "not merged" without saying which sha is
		// NOT the answer invites them to paste it into --commit by hand.
		tip := p.HeadRefOid
		if len(tip) > 10 {
			tip = tip[:10]
		}
		return "", fmt.Errorf("PR #%s has no mergeCommit — it is %s, not merged, so there is no landing sha to record. Its branch tip (%s on %s) is NOT one: a squash never puts the tip on main, so recording it would write a sha no reader can ancestor-check", pr, strings.ToLower(nonEmpty(p.State, "unmerged")), nonEmpty(tip, "unknown"), nonEmpty(p.HeadRefName, "its branch"))
	}

	return strings.TrimSpace(p.MergeCommit.OID), nil
}

func nonEmpty(s, fallback string) string {
	if strings.TrimSpace(s) == "" {
		return fallback
	}
	return s
}

// errGHUnavailable is the sentinel the unavailable-`gh` test injects.
var errGHUnavailable = fmt.Errorf("exec: \"gh\": executable file not found in $PATH")

// ─── THE CRITERION INDEX, RESOLVED CLIENT-SIDE ──────────────────────────────
//
// THE MEASURED DEFECT (task-4dca6c8453fb1f7c). `bp task landed` writes a
// `landed:pr-NNNNN@sha` label and a `content.landed` digest onto a row whose
// `acceptance_criteria` are left untouched, so the ledger ends up asserting two
// contradictory things about the same row: the label says this shipped in an
// ancestor of main, every criterion still reads `met:false`. Measured against
// guerrilla on 2026-09-05: 21 of 1,658 `bp task ready` rows carried a
// `landed:pr-*` label and NINE of them were at ZERO criteria met — the shape a
// lead reads as untouched work and dispatches, and a builder returns
// "already fixed" from.
//
// THE SERVER HALF ALREADY EXISTS AND NOTHING DRIVES IT. The filing's clause
// "no acceptance_criteria reconciliation in landed.ex" is FALSE on origin/main:
// `Barkpark.Tasks.Landed.criterion_update/5` flips exactly one criterion and
// fences it four ways — index out of range, already met (a landing notice never
// overwrites somebody's proof), not merge-shaped, and merge-shaped-but-demands-
// a-demonstration — plus the `files_overlap` guard. All of it is opt-in behind a
// `criterion` index, and this client never computed or sent one. The door was
// built; no caller ever knocked.
//
// SO THIS RESOLVES THE INDEX AND ADDS NO AUTHORITY. The permit is still the
// server's: every guard above stays exactly where it is, and a refusal is
// reported rather than worked around. What the client contributes is the one
// thing it is in a position to know cheaply — WHICH index, if any, is the
// unambiguous candidate — using the same tri-state the stamp path already reads
// (`storedMergeGateFlag`: true / false / absent, where absent is the state that
// selects the prose arm).
//
// THE ARITY RULE IS THE WHOLE SAFETY ARGUMENT:
//
//   - exactly ONE unmet merge-shaped criterion → send it. The flip is
//     unambiguous, and a wrong one cannot be produced by a choice nobody made.
//   - ZERO → land without one and SAY SO. Silence here would read as "the
//     criteria were considered and left alone", which is the same collapse the
//     row is about.
//   - MORE THAN ONE → send NONE and name them with the flag to type. Picking
//     the first would be the client adjudicating, which is precisely what
//     `tasks_landed_cmd_test.go` records as the mistake this wrapper must not
//     make.
//
// A caller who typed `--criterion` is passed through UNTOUCHED, the same rule
// `--commit` follows above: this wrapper never overrides a value a human chose.
// And with no `--note` nothing is resolved at all — the note IS the evidence the
// server writes onto the criterion, and it is required with `--criterion`.
//
// WHEN THE SERVER DECLINES, THE LANDING STILL LANDS. `criterion_update/5` runs
// inside the same `with` as the content write, so a refused criterion aborts the
// WHOLE landing — a resolution that guessed wrong would turn a working landing
// into a 409 that records nothing. So the criterion-carrying attempt is captured
// (stdout and stderr both, `stampCapture`'s trick), and on any of the five
// criterion-caused refusals the envelope is replaced by a readable line naming
// the guard and the landing is re-sent WITHOUT the index. Exit 0 then means what
// it says: the landing was recorded. Any other failure — auth, transport, a row
// that does not resolve — is the landing failing on its own terms, so its
// envelope is replayed verbatim and its exit code stands.
func landWithResolvedCriterion(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, pos []string, flags map[string][]string) int {
	// A typed --criterion is the caller's, not ours.
	if len(flags["criterion"]) > 0 {
		return runCommand(out, g, ctx, m, cmd, tail)
	}

	docID := ""
	if len(pos) > 0 {
		docID = strings.TrimSpace(pos[0])
	}
	// No note, no evidence, no flip. The server requires --note with
	// --criterion, so resolving an index here could only produce a refusal.
	if docID == "" || lastFlagValue(flags, "note") == "" {
		return runCommand(out, g, ctx, m, cmd, tail)
	}

	cands, err := resolveLandedCriteria(taskReadbackClient(ctx), docID)
	if err != nil {
		out.errf("note: could not read %s's acceptance_criteria to resolve a merge-shaped criterion (%v) — recording the landing alone, criteria unchanged. Pass --criterion N to flip one explicitly.", docID, err)
		return runCommand(out, g, ctx, m, cmd, tail)
	}

	switch {
	case len(cands) == 0:
		out.errf("note: %s has no UNMET merge-shaped acceptance criterion, so this landing flips nothing — the sentence is recorded and the criteria are unchanged. (A criterion is merge-shaped when it carries \"merge_gate\": true, or its wording says MERGE-GATED / MERGE GATE / PR merged / merged to main, and its text does not demand a demonstration.)", docID)
		return runCommand(out, g, ctx, m, cmd, tail)

	case len(cands) > 1:
		out.errf("note: %s has %d unmet merge-shaped criteria, so this landing sends NONE — choosing between them is the lead's call, not the client's. Re-run with the one you mean:", docID, len(cands))
		for _, c := range cands {
			out.errf("    --criterion %d   (#%d as boards number them)  %q", c.index, c.index+1, truncateCell(c.text, 72))
		}
		return runCommand(out, g, ctx, m, cmd, tail)
	}

	c := cands[0]
	out.errf("note: criterion index %d (#%d as boards number them) is the ONE unmet merge-shaped criterion on %s — sending it with this landing so the label and the criteria stop disagreeing: %q", c.index, c.index+1, docID, truncateCell(c.text, 72))

	withIndex := append(append([]string{}, tail...), "--criterion", strconv.Itoa(c.index))
	rc, buffered := runLandingCaptured(out, g, ctx, m, cmd, withIndex)

	if rc == exitOK {
		buffered.replay(out)
		out.errf("note: criterion index %d is now met=true with the landing note as its evidence.", c.index)
		return rc
	}

	code := out.lastErrorCode
	why, isGuard := landedCriterionGuard(code)
	if !isGuard {
		// Not a criterion refusal: the landing failed on its own terms
		// (transport, auth, an id that does not resolve). The server's own
		// envelope is the honest answer, so it is replayed untouched and its
		// exit code stands — retrying without the index would only fail twice.
		buffered.replay(out)
		return rc
	}

	// The criterion aborted the whole write, so NOTHING was recorded. Say which
	// guard fired, drop the attempt's envelope (it would read as a failed
	// landing, and the landing is about to succeed), and re-send without it.
	out.errf("note: the server DECLINED the criterion flip — %s: %s. The criterion write and the landing share one transaction, so nothing was recorded; re-sending the landing WITHOUT the criterion. The criteria stay as they are.", nonEmpty(code, "refused"), why)
	out.lastErrorCode = ""
	out.lastErrorArm = ""
	return runCommand(out, g, ctx, m, cmd, tail)
}

// landedCriterionGuard maps the server's refusal code to a readable sentence,
// and reports whether the refusal came from the CRITERION arm at all. The five
// codes are `Tasks.Landed.criterion_update/5`'s four guards plus the overlap
// check it wraps (`files_overlap/3`), which can only fire when a criterion rides
// the request. Anything else is not this wrapper's business.
func landedCriterionGuard(code string) (string, bool) {
	switch strings.TrimSpace(code) {
	case "criteria_index_out_of_range":
		return "the index does not resolve to a criterion on that row", true
	case "criterion_already_met":
		return "that criterion is already met, and a landing notice never overwrites somebody's proof", true
	case "criterion_not_merge_shaped":
		return "the server does not read that criterion as merge-shaped (an explicit \"merge_gate\": false vetoes the wording)", true
	case "criterion_demands_demonstration":
		return "its own text demands a demonstration, so a merge cannot discharge it — the lead closes that one", true
	case "landing_files_outside_row":
		return "the paths this PR changed share nothing with the paths the row names, so the merge sealing it would be sealing someone else's work", true
	default:
		return "", false
	}
}

// ─── THE CANDIDATE READ ─────────────────────────────────────────────────────

// landedCriterion is one acceptance_criteria entry as the RESOLUTION needs it:
// its index, its stored text, whether it is already met, and BOTH merge keys as
// tri-states. Absent is not false in either: for `merge_gate` absent selects the
// prose arm, and for `merge_discharges` absent selects the demonstration veto.
// Collapsing either to a bool erases the state that decides the answer — the
// same reason `storedMergeGateFlag` returns a *bool.
type landedCriterion struct {
	index           int
	text            string
	met             bool
	mergeGate       *bool
	mergeDischarges *bool
}

// resolveLandedCriteria reads the row and returns every criterion the server
// would PERMIT this verb to flip: unmet, merge-shaped, and not vetoed by the
// demonstration wording.
//
// It mirrors `Tasks.Landed.merge_shaped?/1` and `merge_discharges?/1` rather
// than inventing a predicate, and the mirroring is allowed to be imperfect in
// exactly one direction without harm: the server re-evaluates both on the stored
// row under the write lock, so a client false NEGATIVE costs a flip that has to
// be typed by hand, and a client false POSITIVE costs a 409 this wrapper already
// reports and recovers from. Neither can fabricate a met.
func resolveLandedCriteria(c *apiclient.Client, docID string) ([]landedCriterion, error) {
	rb, err := c.TaskGetContent(docID)
	if err != nil {
		return nil, err
	}
	var content struct {
		Criteria []struct {
			Criterion       string `json:"criterion"`
			Met             bool   `json:"met"`
			MergeGate       *bool  `json:"merge_gate"`
			MergeDischarges *bool  `json:"merge_discharges"`
		} `json:"acceptance_criteria"`
	}
	if err := json.Unmarshal(rb.Content, &content); err != nil {
		return nil, fmt.Errorf("the store's acceptance_criteria did not decode: %w", err)
	}

	var out []landedCriterion
	for i, raw := range content.Criteria {
		lc := landedCriterion{
			index:           i,
			text:            raw.Criterion,
			met:             raw.Met,
			mergeGate:       raw.MergeGate,
			mergeDischarges: raw.MergeDischarges,
		}
		if lc.met {
			continue
		}
		if !landedMergeShaped(lc) || !landedMergeDischarges(lc) {
			continue
		}
		out = append(out, lc)
	}
	return out, nil
}

// landedMergeShaped answers the SHAPE question — is this the row a merge seals?
// The author's explicit `merge_gate` decides in BOTH directions and prose
// decides only its absence, which is `Tasks.Landed.merge_shaped?/1` exactly: an
// explicit `false` VETOES wording that would otherwise match.
func landedMergeShaped(c landedCriterion) bool {
	if c.mergeGate != nil {
		return *c.mergeGate
	}
	return mergeGateWordedRe.MatchString(c.text) || landingWordedRe.MatchString(c.text)
}

// landedMergeDischarges answers the OTHER question `merge_gate` was never
// asking: does a MERGE, BY ITSELF, discharge this? An explicit
// `merge_discharges` decides; absent, text that demands a demonstration, a live
// read or an operator action says a merge did not produce the thing it asks for.
// It only ever SUBTRACTS from the merge-shaped set — it is ANDed with it, never
// ORed, so it cannot widen the permit.
func landedMergeDischarges(c landedCriterion) bool {
	if c.mergeDischarges != nil {
		return *c.mergeDischarges
	}
	return !demonstrationWordedRe.MatchString(c.text)
}

var (
	// mergeGateWordedRe mirrors Barkpark.Tasks.Criteria's @merge_gate_worded.
	mergeGateWordedRe = regexp.MustCompile(`(?i)MERGE[-\s]GATED|MERGE[-\s]GATE\b`)
	// landingWordedRe mirrors Barkpark.Tasks.Landed's @landing_worded — the
	// three spellings a merge-sealed final criterion is actually written in that
	// the MERGE-GATE marker does not catch.
	landingWordedRe = regexp.MustCompile(`(?i)pr\s+merged|merged\s+to\s+main|merged\s+into\s+main`)
	// demonstrationWordedRe mirrors Barkpark.Tasks.Landed's
	// @demonstration_worded, the veto.
	demonstrationWordedRe = regexp.MustCompile(`(?i)\bdemo(s|ed|nstrat\w*)?\b|\bthe\s+run\s+(shown|is\s+shown)\b|\bwith\s+the\s+run\b|\brun\s+it\s+live\b|\bscreen\s?shots?\b|\brecordings?\b|\bwalk\s?through\b|\blive\s+(read|run|session)\b|\bin\s+production\b|\bon\s+the\s+box\b|\bagainst\s+prod(uction)?\b|\ban?\s+operator\b|\bby\s+hand\b|\bmanually\b|\ba\s+human\b`)
)

// ─── THE CAPTURED ATTEMPT ───────────────────────────────────────────────────

// landedBuffers holds the criterion-carrying attempt's output while its outcome
// is unknown. Both streams are buffered, not just stdout (which is all
// `stampCapture` needs): the thing being suppressed on the recovery path is an
// ERROR envelope, and those are written to stderr.
type landedBuffers struct {
	stdout bytes.Buffer
	stderr bytes.Buffer
	orig   struct {
		stdout io.Writer
		stderr io.Writer
	}
}

// replay writes the captured bytes through to the real streams, byte for byte.
// Used on every path that keeps the attempt's verdict, so a `-o json` caller
// parses exactly the document the dispatch produced.
func (b *landedBuffers) replay(out *writer) {
	if b == nil {
		return
	}
	if b.stdout.Len() > 0 {
		_, _ = out.stdout.Write(b.stdout.Bytes())
	}
	if b.stderr.Len() > 0 {
		_, _ = out.stderr.Write(b.stderr.Bytes())
	}
}

// runLandingCaptured dispatches with the criterion index while holding both
// streams, and restores them before returning — every exit path goes through the
// same restore, so a return that skipped it could not swallow the envelope.
func runLandingCaptured(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) (int, *landedBuffers) {
	b := &landedBuffers{}
	b.orig.stdout, b.orig.stderr = out.stdout, out.stderr
	out.stdout, out.stderr = &b.stdout, &b.stderr
	rc := runCommand(out, g, ctx, m, cmd, tail)
	out.stdout, out.stderr = b.orig.stdout, b.orig.stderr
	return rc, b
}
