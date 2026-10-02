package scaffy

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// repoRootForTest is the working tree the curated tuples make claims
// about. `go test` runs with the package dir as cwd (corpus_test.go's
// note), so ../.. is the repo root.
const repoRootForTest = "../.."

func catalogFiles(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(corpusDir, "*.scaffy"))
	if err != nil || len(files) == 0 {
		t.Fatalf("catalog glob: %v (%d files)", err, len(files))
	}
	sort.Strings(files)
	return files
}

func repoCheckFile(t *testing.T, path, root string) *RepoCheckResult {
	t.Helper()
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	res, err := RepoCheck(path, src, RepoCheckOptions{RepoRoot: root})
	if err != nil {
		t.Fatalf("RepoCheck %s: %v", path, err)
	}
	return res
}

// tokenBearingOps re-derives, by PREDICATE, how many IN ops of a command
// are substitution-dependent. The census below compares counters against
// this rule rather than against a written-down list of members, so a new
// token-bearing op in the catalog changes the expectation automatically.
func tokenBearingOps(t *testing.T, path string) int {
	t.Helper()
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	cmd, _ := Parse(path, src)
	n := 0
	for _, op := range cmd.Ops {
		if in, ok := op.(*InOp); ok && opNeedsVars(in) {
			n++
		}
	}
	return n
}

// TestCuratedExpansionCoversExactlyTheAllowlist is the QUIET arm: a
// no-var sweep of the whole catalog against the real tree must stay
// finding-free (every curated tuple genuinely resolves on HEAD), and
// expansion must touch the allowlist and NOTHING else — every unlisted
// command's token-bearing ops stay skipped and counted, one for one.
func TestCuratedExpansionCoversExactlyTheAllowlist(t *testing.T) {
	expandedCommands := map[string]bool{}
	for _, f := range catalogFiles(t) {
		stem := commandStem(f)
		res := repoCheckFile(t, f, repoRootForTest)
		tokenOps := tokenBearingOps(t, f)

		if len(res.Findings) != 0 {
			for _, fi := range res.Findings {
				t.Errorf("%s: unexpected finding %s at line %d: %s", stem, fi.Rule, fi.Line, fi.Msg)
			}
		}

		if _, listed := curatedVarSets[stem]; !listed {
			// Unlisted: the pre-existing contract, verbatim.
			if res.AnchorsExpanded != 0 || res.MembersChecked != 0 {
				t.Errorf("%s is NOT on the curated allowlist but was expanded (expanded=%d members=%d)",
					stem, res.AnchorsExpanded, res.MembersChecked)
			}
			if res.SkippedToken != tokenOps {
				t.Errorf("%s: skipped=%d, want %d (every token-bearing op stays skipped-and-counted)",
					stem, res.SkippedToken, tokenOps)
			}
			continue
		}

		expandedCommands[stem] = true
		if res.SkippedToken != 0 {
			t.Errorf("%s is on the curated allowlist but still skipped %d op(s)", stem, res.SkippedToken)
		}
		if res.AnchorsExpanded != tokenOps {
			t.Errorf("%s: expanded=%d, want %d (one per token-bearing op)", stem, res.AnchorsExpanded, tokenOps)
		}
		if want := tokenOps * len(curatedVarSets[stem]); res.MembersChecked != want {
			t.Errorf("%s: members_checked=%d, want %d (ops x tuples)", stem, res.MembersChecked, want)
		}
		// Every member probe must have RESOLVED — that is what curation
		// asserts. AnchorsOK counts them (plus any token-free op).
		if res.AnchorsOK < res.MembersChecked {
			t.Errorf("%s: anchors_ok=%d < members_checked=%d — a curated tuple did not resolve",
				stem, res.AnchorsOK, res.MembersChecked)
		}
	}

	// Coverage is exact in both directions: no allowlist entry names a
	// command the catalog no longer carries.
	for stem := range curatedVarSets {
		if !expandedCommands[stem] {
			t.Errorf("curatedVarSets names %q, which is not a catalog command (or was never expanded)", stem)
		}
	}
}

// TestCuratedExpansionRecoversSomeOfTheSkips pins the direction of the
// change against the pre-change baseline: expansion must strictly REDUCE
// the catalog-wide token-skip total, and the reduction must equal the
// token-bearing ops of the allowlisted commands. Written as a predicate
// so it survives a catalog that grows.
func TestCuratedExpansionRecoversSomeOfTheSkips(t *testing.T) {
	totalSkipped, totalExpanded, allowlistOps := 0, 0, 0
	for _, f := range catalogFiles(t) {
		res := repoCheckFile(t, f, repoRootForTest)
		totalSkipped += res.SkippedToken
		totalExpanded += res.AnchorsExpanded
		if _, listed := curatedVarSets[commandStem(f)]; listed {
			allowlistOps += tokenBearingOps(t, f)
		}
	}
	if totalExpanded == 0 {
		t.Fatal("no anchor was expanded — curated expansion is inert")
	}
	if totalExpanded != allowlistOps {
		t.Errorf("expanded=%d, want %d (the allowlist's token-bearing ops)", totalExpanded, allowlistOps)
	}
	// Pre-change, every token-bearing op in the catalog was skipped.
	// totalSkipped + totalExpanded reconstructs that baseline.
	t.Logf("token-bearing ops: %d skipped + %d recovered = %d total",
		totalSkipped, totalExpanded, totalSkipped+totalExpanded)
}

// writeTree materialises a minimal working tree for a mutation probe.
func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, body := range files {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// TestCuratedExpansionCatchesARenamedLiveAnchor is the RED arm: rename a
// live tier-list opener (`  @element [` -> `  @elements [`) and the
// classify-block-type check must report R-002. Before this change the
// same file greened silently (the anchor is token-bearing, so it was
// skipped) — the CONTROL below proves that, so the test reds if the
// expansion is reverted.
func TestCuratedExpansionCatchesARenamedLiveAnchor(t *testing.T) {
	const cmdPath = corpusDir + "/classify-block-type.scaffy"
	src, err := os.ReadFile(cmdPath)
	if err != nil {
		t.Fatal(err)
	}

	tiersLive, err := os.ReadFile(filepath.Join(repoRootForTest, "api/lib/barkpark/portable_doc/tiers.ex"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(tiersLive), "\n  @element [\n") {
		t.Fatal("precondition: tiers.ex no longer carries the `  @element [` opener the curated tuple names")
	}

	// CONTROL: the unmutated tree is clean AND actually measured — a
	// green with no subject is not a control (AnchorsExpanded > 0).
	clean := writeTree(t, map[string]string{
		"api/lib/barkpark/portable_doc/tiers.ex": string(tiersLive),
	})
	res, err := RepoCheck(cmdPath, src, RepoCheckOptions{RepoRoot: clean})
	if err != nil {
		t.Fatal(err)
	}
	if res.AnchorsExpanded == 0 {
		t.Fatal("control: nothing was expanded — the curated allowlist is not reaching classify-block-type")
	}
	if len(res.Findings) != 0 {
		t.Fatalf("control: unmutated tree reported %d finding(s): %v", len(res.Findings), res.Findings)
	}
	if res.MembersChecked != 2 {
		t.Fatalf("control: members_checked=%d, want 2 (element + widget)", res.MembersChecked)
	}

	// MUTANT: rename the live @element opener.
	mutated := strings.Replace(string(tiersLive), "\n  @element [\n", "\n  @elements [\n", 1)
	if mutated == string(tiersLive) {
		t.Fatal("mutation did not apply")
	}
	mroot := writeTree(t, map[string]string{
		"api/lib/barkpark/portable_doc/tiers.ex": mutated,
	})
	mres, err := RepoCheck(cmdPath, src, RepoCheckOptions{RepoRoot: mroot})
	if err != nil {
		t.Fatal(err)
	}
	got := 0
	for _, f := range mres.Findings {
		if f.Rule == RuleRepoAnchorMissing {
			got++
		}
	}
	if got != 1 {
		t.Fatalf("mutant: want exactly 1 %s finding for the renamed @element opener, got %d (findings=%v)",
			RuleRepoAnchorMissing, got, mres.Findings)
	}
	// The widget member is untouched and must still resolve — a mutation
	// that reds EVERY member proves nothing about which anchor moved.
	if mres.AnchorsOK != 1 {
		t.Fatalf("mutant: anchors_ok=%d, want 1 (the untouched @widget member)", mres.AnchorsOK)
	}
}

// TestDeliberateNonResolversStayOutOfTheAllowlist is the second quiet
// arm: the members that were PROVEN unrecoverable must remain skipped,
// not quietly repaired into false greens. `section` is the standing
// example — @section is still a one-line ~w sigil, so `  @section [`
// must NOT exist, and no curated tuple may name it.
func TestDeliberateNonResolversStayOutOfTheAllowlist(t *testing.T) {
	tiers, err := os.ReadFile(filepath.Join(repoRootForTest, "api/lib/barkpark/portable_doc/tiers.ex"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(tiers), "\n  @section [\n") {
		t.Skip("tiers.ex grew a real @section list opener — re-curate classify-block-type")
	}
	for i, tuple := range curatedVarSets["classify-block-type"] {
		if tuple["Tier"] == "section" {
			t.Errorf("curated tuple %d names the deliberate non-resolver Tier=section", i)
		}
	}

	// The three proven-unrecoverable commands stay off the allowlist and
	// keep reporting their skips.
	for _, stem := range []string{"remove-docs-card", "ensure-import", "add-block-type", "add-schema-type"} {
		if _, listed := curatedVarSets[stem]; listed {
			t.Errorf("%s is on the curated allowlist, but its anchors were PROVEN unrecoverable "+
				"(planted state / unpaired EXAMPLES / anchors carrying the new type)", stem)
		}
		res := repoCheckFile(t, corpusDir+"/"+stem+".scaffy", repoRootForTest)
		if res.SkippedToken == 0 {
			t.Errorf("%s: expected its token-bearing anchors to stay SKIPPED, got skipped=0", stem)
		}
		if len(res.Findings) != 0 {
			t.Errorf("%s: a correct catalog must not red — got %v", stem, res.Findings)
		}
	}
}

// TestCuratedTupleThatNoLongerFitsRedsAsR004 pins the curation tripwire:
// a tuple the command can no longer accept is reported per-command as
// R-004 and DROPPED, while the sibling tuples still run.
func TestCuratedTupleThatNoLongerFitsRedsAsR004(t *testing.T) {
	const stem = "classify-block-type"
	saved := curatedVarSets[stem]
	t.Cleanup(func() { curatedVarSets[stem] = saved })

	curatedVarSets[stem] = []map[string]string{
		{"BlockName": "timeline", "Tier": "element"},
		{"BlockName": "timeline", "Tier": "nosuchtier"}, // falls out of the ONEOF
	}
	res := repoCheckFile(t, corpusDir+"/"+stem+".scaffy", repoRootForTest)
	got := 0
	for _, f := range res.Findings {
		if f.Rule == RuleRepoCuratedInvalid {
			got++
		}
	}
	if got != 1 {
		t.Fatalf("want exactly 1 %s finding, got %d (%v)", RuleRepoCuratedInvalid, got, res.Findings)
	}
	if res.MembersChecked != 1 {
		t.Fatalf("members_checked=%d, want 1 — the surviving tuple must still run", res.MembersChecked)
	}
}
