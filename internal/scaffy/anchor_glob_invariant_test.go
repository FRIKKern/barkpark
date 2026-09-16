package scaffy

// anchor_glob_invariant_test.go — the ANCHOR-GLOB INVARIANT
// (cgsiw-bl-scaffy-anchor-glob-invariant-unguarded).
//
// THE GAP THIS CLOSES. The scaffy anchor-drift gate (doc-gates.yml, step
// s28: `scaffy validate --repo . scaffy/commands/`) re-resolves every
// command's structural anchor against its LIVE target file. It is a real
// gate — but it only ever RUNS on a PR whose changed files match
// doc-gates.yml's own `pull_request: paths:` filter. So the gate's reach is
// bounded by a list it does not read: if a command anchors `IN "x/y.py"`
// and no doc-gates glob matches `.py`, then the PR that MOVES x/y.py
// silently changes an anchor's target with the drift gate never running.
// The corpus was clean when this was filed (0 un-globbed of 38 non-token
// targets) — which is exactly why the durable finding is the MISSING
// INSTRUMENT, not a live gap. A hot corpus reopens it the day a command
// anchors into a new extension.
//
// A PREDICATE, NOT AN ENUMERATION. Nothing here lists extensions or target
// paths. The rule is derived twice from the live artifacts: every
// non-token `IN` target in the live corpus is extracted with the REAL
// parser, and every glob is read out of the REAL workflow. A new target,
// a new glob, or a removed glob all re-derive on the next run. A
// hand-listed set would silently omit the next one.
//
// THE TOKEN CAVEAT, stated honestly. RepoCheck SKIPS token-bearing
// anchors with no --var set (opNeedsVars), so a `{{.TargetFile}}` target
// is both un-globbable AND structurally uncheckable — there is no gate
// behind it to protect, so there is nothing for this invariant to say
// about it. Those targets are counted and excluded, never silently
// dropped. If RepoCheck ever learns to resolve token anchors from a --var
// default, they become live subjects and this test must widen with it.
//
// FAIL CLOSED. A zero-target extraction and a zero-glob read are both
// hard failures: an empty input is the one way a coverage assertion can
// pass having measured nothing.

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// docGatesWorkflow is the workflow whose pull_request paths filter decides
// whether the scaffy anchor-drift gate runs at all. Read in place, like
// the corpus itself (D30) — cwd is the package dir under `go test`.
const docGatesWorkflow = "../../.github/workflows/doc-gates.yml"

// anchorTarget is one non-token `IN` target path, with the command file it
// came from so a failure names the thing to fix.
type anchorTarget struct {
	Path   string
	Source string
	Line   int
}

// scaffyAnchorTargets parses every *.scaffy in dir with the REAL parser and
// returns the distinct non-token `IN` target paths plus the count of
// token-bearing ones skipped. Token-bearing is decided by the same
// tokenRe-on-Path.Value rule RepoCheck uses (repocheck.go opNeedsVars),
// so the skip set here and the skip set there cannot drift apart by
// accident.
func scaffyAnchorTargets(t *testing.T, dir string) (targets []anchorTarget, tokenSkipped int, files int) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read command dir %s: %v", dir, err)
	}
	seen := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".scaffy") {
			continue
		}
		files++
		path := filepath.Join(dir, e.Name())
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		cmd, findings := Parse(path, src)
		if cmd == nil {
			t.Fatalf("%s: parse returned no command (findings: %v)", path, findings)
		}
		for _, op := range cmd.Ops {
			in, ok := op.(*InOp)
			if !ok || in.Path == nil {
				continue
			}
			p := in.Path.Value
			// The RepoCheck skip rule, verbatim in spirit: a token in the
			// PATH makes the target unresolvable without a --var set.
			if tokenRe.MatchString(p) {
				tokenSkipped++
				continue
			}
			if seen[p] {
				continue
			}
			seen[p] = true
			targets = append(targets, anchorTarget{Path: p, Source: e.Name(), Line: in.InPos.Line})
		}
	}
	sort.Slice(targets, func(i, j int) bool { return targets[i].Path < targets[j].Path })
	return targets, tokenSkipped, files
}

// pullRequestPathGlobs reads the `on: pull_request: paths:` list out of the
// workflow. Deliberately a narrow line reader rather than a YAML dependency:
// the block is a flat sequence of quoted scalars, and the scan is anchored
// on exact indentation so a `paths:` key anywhere else in the file (a job
// step, the push block) cannot be mistaken for this one.
func pullRequestPathGlobs(t *testing.T, workflow string) []string {
	t.Helper()
	raw, err := os.ReadFile(workflow)
	if err != nil {
		t.Fatalf("read workflow %s: %v", workflow, err)
	}
	var globs []string
	inPR, inPaths := false, false
	for _, line := range strings.Split(string(raw), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if line == "  pull_request:" {
			inPR = true
			continue
		}
		if !inPR {
			continue
		}
		// Any key back at 2-space indent (or column 0) closes the block.
		if !strings.HasPrefix(line, "   ") {
			break
		}
		if line == "    paths:" {
			inPaths = true
			continue
		}
		if !inPaths {
			continue
		}
		if !strings.HasPrefix(trimmed, "- ") {
			// A sibling key under pull_request (e.g. `branches:`) ends paths.
			inPaths = false
			continue
		}
		globs = append(globs, strings.Trim(strings.TrimPrefix(trimmed, "- "), `"'`))
	}
	return globs
}

// githubGlobRe translates one GitHub Actions path glob into an anchored
// regexp. `**` spans separators, `*` and `?` do not — that difference IS
// the filter, which is why filepath.Match (which cannot tell the two
// apart) is not used. Mirrors the translation in go-tests.yml's dispatcher
// and scripts/workflow-trigger-coverage.sh.
func githubGlobRe(t *testing.T, glob string) *regexp.Regexp {
	t.Helper()
	var b strings.Builder
	b.WriteString("^")
	for i := 0; i < len(glob); {
		switch {
		case strings.HasPrefix(glob[i:], "**/"):
			b.WriteString("(?:.*/)?")
			i += 3
		case strings.HasPrefix(glob[i:], "**"):
			b.WriteString(".*")
			i += 2
		case glob[i] == '*':
			b.WriteString("[^/]*")
			i++
		case glob[i] == '?':
			b.WriteString("[^/]")
			i++
		default:
			b.WriteString(regexp.QuoteMeta(string(glob[i])))
			i++
		}
	}
	b.WriteString("$")
	re, err := regexp.Compile(b.String())
	if err != nil {
		t.Fatalf("glob %q translated to an invalid regexp %q: %v", glob, b.String(), err)
	}
	return re
}

// uncoveredAnchorTargets returns the targets no glob matches. This is the
// predicate the whole file exists to run; the two callers below feed it the
// LIVE corpus and a PLANTED one.
func uncoveredAnchorTargets(t *testing.T, targets []anchorTarget, globs []string) []anchorTarget {
	t.Helper()
	res := make([]*regexp.Regexp, 0, len(globs))
	for _, g := range globs {
		res = append(res, githubGlobRe(t, g))
	}
	var out []anchorTarget
	for _, tgt := range targets {
		covered := false
		for _, re := range res {
			if re.MatchString(tgt.Path) {
				covered = true
				break
			}
		}
		if !covered {
			out = append(out, tgt)
		}
	}
	return out
}

// TestScaffyAnchorTargetsRideADocGatesGlob is the invariant: every
// non-token `IN` target in the live corpus must match at least one
// doc-gates pull_request glob, or the anchor-drift gate cannot run on the
// PR that breaks that anchor.
func TestScaffyAnchorTargetsRideADocGatesGlob(t *testing.T) {
	globs := pullRequestPathGlobs(t, docGatesWorkflow)
	// FAIL CLOSED #1: a mis-parse of the workflow yields an empty glob set,
	// under which EVERY target reads as uncovered — loud, not silent. The
	// inverse (a glob set that silently shrank to nothing while the block
	// still exists) is what this floor catches.
	if len(globs) == 0 {
		t.Fatalf("extracted ZERO pull_request path globs from %s — the workflow shape changed under this reader; a coverage verdict from an empty filter measures nothing", docGatesWorkflow)
	}

	targets, tokenSkipped, files := scaffyAnchorTargets(t, corpusDir)
	// FAIL CLOSED #2: a zero-target extraction is the one way "all targets
	// covered" passes having measured nothing.
	if len(targets) == 0 {
		t.Fatalf("extracted ZERO non-token IN targets from %s (%d files, %d token-bearing skipped) — the extraction broke, so 'all covered' would be vacuous", corpusDir, files, tokenSkipped)
	}
	// A FLOOR, not an equality: corpus_test.go already freezes the exact
	// count (corpusFileCount), and a new command is the normal case this
	// guard exists to measure — an equality here would red on the very PR
	// it is supposed to judge, with the WRONG message. Below the floor
	// means a half-globbed read, which is the vacuity this catches.
	if files < corpusFileCount {
		t.Fatalf("read only %d .scaffy files from %s, below the frozen floor of %d (corpusFileCount) — the directory read is half-globbed, so any coverage verdict is partial", files, corpusDir, corpusFileCount)
	}

	uncovered := uncoveredAnchorTargets(t, targets, globs)
	for _, u := range uncovered {
		t.Errorf("UN-GLOBBED ANCHOR TARGET %s (anchored by %s:%d) matches none of the %d doc-gates pull_request globs. The scaffy anchor-drift gate will NOT run on a PR that moves this file, so the anchor can drift silently. Fix: add a glob covering it to the `pull_request: paths:` block of %s (and the mirrored `push:` block).", u.Path, u.Source, u.Line, len(globs), docGatesWorkflow)
	}

	// THE SAFE COUNT, reported on success — not only on failure. A guard
	// that prints nothing when it passes cannot be told apart from a guard
	// that did not run.
	t.Logf("anchor-glob invariant: %d .scaffy files, %d distinct non-token IN targets, %d covered, %d un-globbed, %d token-bearing IN ops skipped (structurally uncheckable by RepoCheck without a --var set), against %d doc-gates pull_request globs",
		files, len(targets), len(targets)-len(uncovered), len(uncovered), tokenSkipped, len(globs))
}

// TestScaffyAnchorGlobInvariantDetectsAPlantedTarget is the RED arm: the
// same predicate, over a PLANTED corpus whose one command anchors into an
// extension no doc-gates glob covers. It uses the LIVE glob list, so the
// day someone adds `**/*.py` this arm fails loudly rather than rotting
// into a false green — at which point pick another un-globbed extension,
// do not delete the arm.
func TestScaffyAnchorGlobInvariantDetectsAPlantedTarget(t *testing.T) {
	globs := pullRequestPathGlobs(t, docGatesWorkflow)
	if len(globs) == 0 {
		t.Fatalf("extracted ZERO pull_request path globs from %s", docGatesWorkflow)
	}

	dir := t.TempDir()
	// Two commands: one anchoring a COVERED target (**/*.go), one anchoring
	// an UN-GLOBBED one. The pair is the point — a detector that reds on
	// everything is not a detector.
	write := func(name, target string) {
		t.Helper()
		src := strings.Join([]string{
			`COMMAND "Anchor glob invariant fixture" DESCRIPTION "A planted command used only by the anchor-glob invariant test: it anchors into a target path so the coverage predicate has something to resolve. Plants nothing in the real tree." LAST_UPDATED "16-09-2026-00-00-00" DOMAIN "barkpark" TAGS "scaffy" CONCEPT "anchor-glob-fixture" VARIANT "text" DIRECTION "add" VARIABLES`,
			``,
			`IN "` + target + `"`,
			`### anchor into the fixture target`,
			`INSERT AFTER FIRST`,
			`::: fixture anchor :::`,
			`first real line`,
			`::: fixture anchor :::`,
			`WITH`,
			`::: fixture injected block :::`,
			`planted MARK:anchor-glob-fixture-block`,
			`::: fixture injected block :::`,
			`MARK "anchor-glob-fixture-block"`,
			`ASLONG FILE DONT CONTAIN "planted MARK:anchor-glob-fixture-block"`,
			``,
		}, "\n")
		if err := os.WriteFile(filepath.Join(dir, name), []byte(src), 0o644); err != nil {
			t.Fatalf("plant %s: %v", name, err)
		}
	}
	const covered = "internal/scaffy/planted_fixture.go"
	const unglobbed = "tooling/planted/anchor_glob_fixture.py"
	write("covered.scaffy", covered)
	write("unglobbed.scaffy", unglobbed)

	targets, _, files := scaffyAnchorTargets(t, dir)
	// Precondition, asserted rather than assumed: the planted corpus really
	// produced BOTH targets. A parse failure here would otherwise make the
	// "detected" verdict below a statement about an empty set.
	if files != 2 || len(targets) != 2 {
		t.Fatalf("planted corpus did not parse as expected: %d files, %d targets %v (want 2 and 2)", files, len(targets), targets)
	}

	uncovered := uncoveredAnchorTargets(t, targets, globs)
	var got []string
	for _, u := range uncovered {
		got = append(got, u.Path)
	}

	// QUIET ARM: the .go target rides `**/*.go` and must NOT be reported.
	for _, p := range got {
		if p == covered {
			t.Errorf("FALSE POSITIVE: %s rides the live `**/*.go` glob but the predicate called it un-globbed. A detector that reds on a covered target cannot be trusted when it reds on an un-covered one.", covered)
		}
	}
	// RED ARM: the .py target rides nothing and MUST be reported.
	if len(got) != 1 || got[0] != unglobbed {
		t.Errorf("RED ARM FAILED: planted un-globbed target %s was not the sole finding; got %v. Either the predicate stopped detecting un-globbed targets, or a doc-gates glob now covers .py — if the latter, repoint this fixture at another un-globbed extension rather than deleting the arm.", unglobbed, got)
	}
}

// TestGitHubGlobTranslationSeparatorFidelity pins the one property the
// coverage predicate rests on: `*` must NOT span a path separator while
// `**` must. Widen `*` to `.*` and the predicate starts calling
// un-globbed targets covered — a FALSE GREEN on the live corpus that no
// current target happens to expose, so it needs its own arm rather than
// riding the corpus's luck.
func TestGitHubGlobTranslationSeparatorFidelity(t *testing.T) {
	cases := []struct {
		glob, path string
		want       bool
	}{
		// `*` stops at the separator.
		{"api/*.ex", "api/foo.ex", true},
		{"api/*.ex", "api/lib/foo.ex", false},
		// `**/` spans any number of segments, including none.
		{"**/*.ex", "foo.ex", true},
		{"**/*.ex", "api/lib/deep/foo.ex", true},
		{"**/*.ex", "api/lib/foo.exs", false},
		// A trailing `**` sweeps the subtree.
		{"scaffy/commands/**", "scaffy/commands/a/b.scaffy", true},
		{"scaffy/commands/**", "scaffy/other.scaffy", false},
		// Anchored at both ends — no substring matches.
		{"go.mod", "api/go.mod", false},
		{"go.mod", "go.mod", true},
		// A dot is literal, not "any char".
		{"**/*.go", "internal/scaffyXgo", false},
	}
	for _, c := range cases {
		if got := githubGlobRe(t, c.glob).MatchString(c.path); got != c.want {
			t.Errorf("glob %q vs path %q: got %v, want %v", c.glob, c.path, got, c.want)
		}
	}
}
