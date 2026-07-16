package scaffy

// repocheck_test.go — the opt-in repo-aware layer (D5). Every tree lives
// in t.TempDir(); the fixtures reuse apply_test.go's seedWidgetTree, which
// plants the exact anchors the add-widget command targets, so a clean
// RepoCheck resolves the token-free anchors and skips the {{.token}}-bearing
// one. Both drift directions are proven: a mutated tree reds (R-001/R-002/
// R-003) and the occurrence-count rule fires only where exactly-once is
// required (REPLACE/REMOVE), never on INSERT's FIRST/LAST pin.

import (
	"errors"
	"os"
	"testing"
)

// fixtureSrc reads the add-widget fixture bytes (the RepoCheck subject).
func fixtureSrc(t *testing.T) []byte {
	t.Helper()
	src, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	return src
}

func repoCheck(t *testing.T, root string, vars map[string]string) *RepoCheckResult {
	t.Helper()
	res, err := RepoCheck(fixturePath, fixtureSrc(t), RepoCheckOptions{RepoRoot: root, Vars: vars})
	if err != nil {
		t.Fatalf("RepoCheck: %v", err)
	}
	return res
}

// hasFinding reports whether any finding carries the given rule ID.
func hasFinding(res *RepoCheckResult, rule string) bool {
	for _, f := range res.Findings {
		if f.Rule == rule {
			return true
		}
	}
	return false
}

// TestRepoCheckCleanSkipsTokenAnchors: on the pristine seeded tree with NO
// vars, the three token-free anchors (registry INSERT, css INSERT, config
// REPLACE) resolve cleanly and the one {{.CountBefore}}-bearing REPLACE is
// skipped and COUNTED — never a silent green.
func TestRepoCheckCleanSkipsTokenAnchors(t *testing.T) {
	root := seedWidgetTree(t)
	res := repoCheck(t, root, nil)
	if len(res.Findings) != 0 {
		t.Fatalf("clean tree produced findings: %v", res.Findings)
	}
	if res.AnchorsOK != 3 {
		t.Errorf("AnchorsOK = %d, want 3 (the token-free anchors)", res.AnchorsOK)
	}
	if res.SkippedToken != 1 {
		t.Errorf("SkippedToken = %d, want 1 (the {{.CountBefore}} anchor)", res.SkippedToken)
	}
}

// TestRepoCheckWithVarsChecksTokenAnchors: supplying the full --var set
// resolves the token-bearing REPLACE too — all four anchors verified,
// nothing skipped.
func TestRepoCheckWithVarsChecksTokenAnchors(t *testing.T) {
	root := seedWidgetTree(t)
	res := repoCheck(t, root, widgetVars("Timeline", "20260716100000", "42", "43"))
	if len(res.Findings) != 0 {
		t.Fatalf("clean tree with vars produced findings: %v", res.Findings)
	}
	if res.AnchorsOK != 4 {
		t.Errorf("AnchorsOK = %d, want 4 (all anchors)", res.AnchorsOK)
	}
	if res.SkippedToken != 0 {
		t.Errorf("SkippedToken = %d, want 0 (vars resolve every token)", res.SkippedToken)
	}
}

// TestRepoCheckMissingFile: an IN-op target absent from the tree reds
// R-001 and no anchor check runs for it.
func TestRepoCheckMissingFile(t *testing.T) {
	root := seedWidgetTree(t)
	if err := os.Remove(root + "/web/widgets/index.css"); err != nil {
		t.Fatal(err)
	}
	res := repoCheck(t, root, nil)
	if !hasFinding(res, RuleRepoMissingFile) {
		t.Fatalf("want R-001 for the removed css file; findings: %v", res.Findings)
	}
	// The other two token-free anchors still resolve.
	if res.AnchorsOK != 2 {
		t.Errorf("AnchorsOK = %d, want 2", res.AnchorsOK)
	}
}

// TestRepoCheckAnchorNotFound: a token-free REPLACE anchor whose fenced
// bytes have drifted out of the file reds R-002.
func TestRepoCheckAnchorNotFound(t *testing.T) {
	root := seedWidgetTree(t)
	// Overwrite config.exs without the cron tuple the REPLACE anchors on.
	writeTreeFile(t, root, "api/config/config.exs", "import Config\n\nconfig :barkpark, Oban, crontab: []\n")
	res := repoCheck(t, root, nil)
	if !hasFinding(res, RuleRepoAnchorMissing) {
		t.Fatalf("want R-002 for the drifted config anchor; findings: %v", res.Findings)
	}
}

// TestRepoCheckAmbiguousReplace: a DUPLICATED REPLACE anchor reds R-003 —
// the occurrence-count check demanded by the task (exactly-once, D20).
func TestRepoCheckAmbiguousReplace(t *testing.T) {
	root := seedWidgetTree(t)
	dup := "import Config\n\nconfig :barkpark, Oban,\n  crontab: [\n" +
		"       {\"* * * * *\", Barkpark.Workers.Tail}\n" +
		"       {\"* * * * *\", Barkpark.Workers.Tail}\n" +
		"  ]\n"
	writeTreeFile(t, root, "api/config/config.exs", dup)
	res := repoCheck(t, root, nil)
	if !hasFinding(res, RuleRepoAnchorAmbig) {
		t.Fatalf("want R-003 for the duplicated REPLACE anchor; findings: %v", res.Findings)
	}
}

// TestRepoCheckInsertDuplicateNotAmbiguous: a duplicated INSERT AFTER FIRST
// anchor is NOT ambiguous — FIRST pins one occurrence, so no R-003 fires
// (the occurrence-count rule is scoped to the exactly-once verbs).
func TestRepoCheckInsertDuplicateNotAmbiguous(t *testing.T) {
	root := seedWidgetTree(t)
	dup := registrySeed + "\nfunc more() {\n\tregistry[\"heading\"] = headingWidget{}\n}\n"
	writeTreeFile(t, root, "internal/widgets/registry.go", dup)
	res := repoCheck(t, root, nil)
	if hasFinding(res, RuleRepoAnchorAmbig) {
		t.Fatalf("INSERT AFTER FIRST must not red R-003 on a repeated anchor; findings: %v", res.Findings)
	}
	if len(res.Findings) != 0 {
		t.Fatalf("unexpected findings: %v", res.Findings)
	}
}

// TestRepoCheckBadVarsSurfacesVarError: a --var set that violates the D37
// contract (unknown key) is the engine's *VarError — the CLI maps it to a
// usage error, exactly as run does.
func TestRepoCheckBadVarsSurfacesVarError(t *testing.T) {
	root := seedWidgetTree(t)
	_, err := RepoCheck(fixturePath, fixtureSrc(t), RepoCheckOptions{
		RepoRoot: root,
		Vars:     map[string]string{"NotADeclaredVar": "x"},
	})
	var varErr *VarError
	if !errors.As(err, &varErr) {
		t.Fatalf("err = %v, want *VarError", err)
	}
}

// TestRepoCheckRequiresRoot: an empty RepoRoot is a usage-class error.
func TestRepoCheckRequiresRoot(t *testing.T) {
	_, err := RepoCheck(fixturePath, fixtureSrc(t), RepoCheckOptions{})
	if err == nil {
		t.Fatal("want an error for an empty RepoRoot")
	}
}
