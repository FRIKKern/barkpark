package scaffy

// repocheck.go — the opt-in repo-aware layer behind `bp scaffy validate
// --repo <root>` (charter D5, the piece D27 cut from W2's pure-text
// validate). Default validate stays text-level; RepoCheck adds the
// checks D5 promises as prose: once a command validates text-clean, every
// IN-op's target FILE must exist under the root and every structural
// anchor must RESOLVE in that file — present, and UNIQUELY present where
// the op's matcher demands exactly-once (REPLACE/REMOVE, D20). Anchor
// drift is reported as Findings with distinct repo rule IDs (R-001
// missing-file / R-002 anchor-not-found / R-003 anchor-ambiguous).
//
// One matcher, shared — NOT forked. The target bytes are produced by the
// SAME path apply.go's applyInOp uses: sub.fencedBytes for a resolvable
// anchor, the verbatim Fenced.Bytes for a token-free one; the occurrence
// policy mirrors applyInOp exactly — INSERT AFTER|BEFORE FIRST/LAST pin
// a repeated anchor (at-least-once suffices), REPLACE and REMOVE are
// byte-exact exactly-once (D20). On a clean tree no mark family is
// planted, so a REANCHOR REPLACE is checked at its run-1 structural
// target — precisely the "FIRST-run target must exist today" D5 asks for.
//
// Anchors (or paths) whose fenced bytes carry {{.tokens}} are
// substitution-dependent: they are checked only when the full --var set
// is supplied (the same D37 contract `run` enforces — newSubstituter
// validates it). Without vars they are SKIPPED and COUNTED, never
// silently passed — the summary always names the skipped total.

import (
	"bytes"
	"fmt"
	"path/filepath"
	"strings"
)

// Repo-aware rule IDs. These live OUTSIDE the frozen text-level catalog
// (doc.go's Rules / D28) because the whole layer is opt-in via --repo;
// RepoRules is their machine-readable index.
const (
	RuleRepoMissingFile   = "R-001" // IN-op target file absent from the tree
	RuleRepoAnchorMissing = "R-002" // structural anchor not found in the target file
	RuleRepoAnchorAmbig   = "R-003" // anchor occurs >1× where exactly-once is required (D20)
)

// RepoRules is the repo-aware catalog, in ID order. Every repo-check
// Finding.Rule is one of these IDs.
var RepoRules = []RuleInfo{
	{RuleRepoMissingFile, SeverityError, "IN-op target file missing from the tree"},
	{RuleRepoAnchorMissing, SeverityError, "structural anchor not found in the target file"},
	{RuleRepoAnchorAmbig, SeverityError, "anchor occurs more than once where exactly-once is required"},
	{RuleRepoCuratedInvalid, SeverityError, "curated example tuple no longer satisfies the command's declared VARIABLES"},
}

// RepoCheckOptions configures one repo-aware validation pass.
type RepoCheckOptions struct {
	RepoRoot string            // the working tree every IN path resolves against
	Vars     map[string]string // optional; empty ⇒ token-bearing anchors are skipped, not guessed
}

// RepoCheckResult carries the drift findings plus the honesty counters:
// AnchorsOK anchors resolved cleanly and SkippedToken anchors (or paths)
// skipped because they carry {{.tokens}} and no --var set was supplied.
//
// AnchorsExpanded / MembersChecked mirror SkippedToken for the curated
// half: AnchorsExpanded counts the token-bearing ops that were RECOVERED
// by curated-tuple expansion instead of skipped, and MembersChecked the
// (op x tuple) anchor probes that expansion actually ran. Together the
// three say exactly how much of a no-var pass was measured — a rise in
// SkippedToken with AnchorsExpanded flat means new uncheckable surface.
type RepoCheckResult struct {
	Findings        []Finding
	AnchorsOK       int
	SkippedToken    int
	AnchorsExpanded int
	MembersChecked  int
}

// RepoCheck runs the repo-aware anchor checks for ONE already-text-valid
// command against the working tree. The CLI gates on ValidateFile == 0
// findings before calling (D5 — anchors on a malformed AST are noise).
// A bad --var set (missing/unknown/newline/shape/successor) surfaces as
// the engine's *VarError, which the CLI maps to a usage error (exit 2) —
// the same contract `run` enforces (D37).
func RepoCheck(path string, src []byte, opts RepoCheckOptions) (*RepoCheckResult, error) {
	if opts.RepoRoot == "" {
		return nil, varErrorf("RepoCheck requires a RepoRoot")
	}
	cmd, _ := Parse(path, src)

	// Build the substituter only when vars are supplied — and then under
	// the full D37 contract (every declared VARIABLE required). With no
	// vars we never build one; token-bearing anchors are skipped below.
	var sub *substituter
	if len(opts.Vars) > 0 {
		s, err := newSubstituter(cmd, opts.Vars)
		if err != nil {
			return nil, err
		}
		sub = s
	}

	tr := newTree(opts.RepoRoot)
	res := &RepoCheckResult{}

	// With no --var set, a token-bearing op is expanded ONLY if this
	// command is on the curated allowlist (repocheck_curated.go). An
	// unlisted command keeps the skip-and-count contract verbatim.
	var curated []*substituter
	if sub == nil {
		curated = curatedSubstituters(cmd, path, res)
	}

	for _, op := range cmd.Ops {
		in, ok := op.(*InOp)
		if !ok {
			continue // CREATE/DELETE own their file's existence — no pre-existing anchor
		}
		if sub != nil || !opNeedsVars(in) {
			checkInOp(cmd, sub, tr, in, res)
			continue
		}
		if len(curated) == 0 {
			res.SkippedToken++
			continue
		}
		res.AnchorsExpanded++
		for _, cs := range curated {
			res.MembersChecked++
			checkInOp(cmd, cs, tr, in, res)
		}
	}
	return res, nil
}

// commandStem is the allowlist key: the command file's basename without
// its .scaffy extension (scaffy/commands/<stem>.scaffy).
func commandStem(path string) string {
	return strings.TrimSuffix(filepath.Base(path), ".scaffy")
}

// curatedSubstituters builds one substituter per curated tuple for this
// command, or nil when the command is unlisted. A tuple the command can
// no longer accept is reported as R-004 and DROPPED — the remaining
// tuples still run, so one stale tuple never blinds the whole command.
func curatedSubstituters(cmd *Command, path string, res *RepoCheckResult) []*substituter {
	tuples := curatedVarSets[commandStem(path)]
	if len(tuples) == 0 {
		return nil
	}
	out := make([]*substituter, 0, len(tuples))
	for i, vars := range tuples {
		s, err := newSubstituter(cmd, vars)
		if err != nil {
			res.Findings = append(res.Findings, Finding{
				File: cmd.SourceFile, Line: 1, Rule: RuleRepoCuratedInvalid,
				Msg: fmt.Sprintf("curated example tuple %d for %q no longer satisfies the declared VARIABLES: %v",
					i, commandStem(path), err),
				Hint: "re-curate the tuple in internal/scaffy/repocheck_curated.go, or drop it if the command was re-pointed",
			})
			continue
		}
		out = append(out, s)
	}
	return out
}

// opNeedsVars reports whether an IN op is substitution-dependent — a
// {{.token}} in its PATH or anywhere in its fenced anchor. These are the
// ops that are skipped without a var set and expanded with one.
func opNeedsVars(o *InOp) bool {
	return tokenRe.MatchString(o.Path.Value) || fencedHasToken(o.Target)
}

// checkInOp verifies one IN op's file + structural anchor against the
// tree, appending drift findings and advancing the honesty counters.
func checkInOp(cmd *Command, sub *substituter, tr *tree, o *InOp, res *RepoCheckResult) {
	srcFile := cmd.SourceFile

	// The target PATH is substitution-dependent too — a token in it needs
	// the var set exactly as a token in the anchor does.
	if sub == nil && tokenRe.MatchString(o.Path.Value) {
		res.SkippedToken++
		return
	}
	rel := o.Path.Value
	if sub != nil {
		r, err := sub.text(o.Path.Value, srcFile, o.InPos.Line)
		if err != nil {
			// Unreachable on a text-clean command under a full var set; treat
			// as skip rather than fabricate a path.
			res.SkippedToken++
			return
		}
		rel = r
	}

	content, exists, err := tr.read(rel)
	if err != nil || !exists {
		res.Findings = append(res.Findings, Finding{
			File: srcFile, Line: o.InPos.Line, Rule: RuleRepoMissingFile,
			Msg:  fmt.Sprintf("IN target file %q is missing from the tree at %q", rel, tr.root),
			Hint: "correct the IN path, or plant the file first (a CREATE op or a prior command)",
		})
		return
	}

	// The ANCHOR's fenced bytes. Token-bearing without a var set is
	// substitution-dependent — skip and count, never guess a match.
	if sub == nil && fencedHasToken(o.Target) {
		res.SkippedToken++
		return
	}
	var target []byte
	if sub != nil {
		target, err = sub.fencedBytes(o.Target, srcFile)
		if err != nil {
			res.SkippedToken++
			return
		}
	} else {
		target = o.Target.Bytes()
	}
	if len(target) == 0 {
		return // an empty target fence is an E-002/parse concern, not repo drift
	}

	// Occurrence policy, mirroring applyInOp (apply.go): INSERT pins a
	// repeated anchor (FIRST/LAST), REPLACE/REMOVE demand exactly-once.
	n := bytes.Count(content, target)
	switch {
	case n == 0:
		res.Findings = append(res.Findings, Finding{
			File: srcFile, Line: o.Target.Pos.Line, Rule: RuleRepoAnchorMissing,
			Msg:  fmt.Sprintf("%s anchor not found in %q — the fenced bytes have drifted from the file", o.Verb, rel),
			Hint: "re-sync the fenced anchor with the current file, or re-point the op",
		})
	case requiresUniqueAnchor(o.Verb) && n > 1:
		res.Findings = append(res.Findings, Finding{
			File: srcFile, Line: o.Target.Pos.Line, Rule: RuleRepoAnchorAmbig,
			Msg:  fmt.Sprintf("%s anchor occurs %d times in %q — exactly-once required (D20)", o.Verb, n, rel),
			Hint: "extend the fenced anchor until it selects a single occurrence",
		})
	default:
		res.AnchorsOK++
	}
}

// fencedHasToken reports whether any line of a fenced anchor carries a
// {{.token}} — i.e. whether it is substitution-dependent.
func fencedHasToken(f *Fenced) bool {
	if f == nil {
		return false
	}
	for _, ln := range f.Lines {
		if tokenRe.MatchString(ln) {
			return true
		}
	}
	return false
}

// requiresUniqueAnchor is the exactly-once half of applyInOp's occurrence
// policy: REPLACE and REMOVE are byte-exact exactly-once (D20); INSERT
// AFTER FIRST/LAST resolve a repeated anchor by position.
func requiresUniqueAnchor(v InOpVerb) bool {
	return v == Replace || v == RemoveVerb
}
