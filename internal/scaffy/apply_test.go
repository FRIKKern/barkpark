package scaffy

// apply_test.go — conformance tests for the engine forward path over
// testdata/green/add-widget.scaffy (the D37 conformance vehicle: it
// inherits ZERO protection from corpus_test.go) plus synthetic
// commands for the fail-loud paths. All trees live in t.TempDir().

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const fixturePath = "testdata/green/add-widget.scaffy"

const registrySeed = `package widgets

type widget interface{}

type headingWidget struct{}

type timelineWidget struct{}

type beaconWidget struct{}

type compassWidget struct{}

var registry = map[string]widget{}

func init() {
	registry["heading"] = headingWidget{}
}
`

const configSeed = `import Config

config :barkpark, Oban,
  crontab: [
       {"* * * * *", Barkpark.Workers.Tail}
  ]
`

const jsSeed = "test(\"cases\", () => {\n  expect(cases).toHaveLength(42)\n})\n"

func writeTreeFile(t *testing.T, root, rel, content string) {
	t.Helper()
	abs := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(abs, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readTreeFile(t *testing.T, root, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(b)
}

// seedWidgetTree builds the minimal real-shaped tree the add-widget
// fixture targets — a compilable Go module so the fixture's LOCAL
// ASSERT CMD (go build) genuinely passes.
func seedWidgetTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writeTreeFile(t, root, "go.mod", "module scaffytest\n\ngo 1.25.0\n")
	writeTreeFile(t, root, "internal/widgets/registry.go", registrySeed)
	writeTreeFile(t, root, "web/widgets/index.css", ".bp-heading { display: block; }\n")
	writeTreeFile(t, root, "api/config/config.exs", configSeed)
	writeTreeFile(t, root, "js/widgets/widgets.test.ts", jsSeed)
	return root
}

func widgetVars(name, ts, before, after string) map[string]string {
	return map[string]string{"WidgetName": name, "Ts": ts, "CountBefore": before, "CountAfter": after}
}

func runFixture(t *testing.T, root string, vars map[string]string) *RunReport {
	t.Helper()
	rep, err := Run(RunOptions{CommandPath: fixturePath, Vars: vars, RepoRoot: root})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return rep
}

// snapshotTree captures every file under root (path → bytes) so
// byte-identity across a no-op re-run is checkable.
func snapshotTree(t *testing.T, root string) map[string]string {
	t.Helper()
	snap, err := walkSnapshot(root)
	if err != nil {
		t.Fatal(err)
	}
	return snap
}

// walkSnapshot is snapshotTree's body, error-returning so
// TestSnapshotSkipsGitStore can assert on a walk FAILURE instead of
// being aborted by t.Fatal.
//
// The fixture root's own .git/ is skipped, and that narrowing is
// deliberate. These snapshots exist to assert byte-equality of the
// WORKING TREE across a run→remove cycle; git's private store was
// never part of that claim, and git is free to rewrite it at any
// moment — `git commit` spawns a DETACHED `git maintenance run
// --auto`, which creates and unlinks .git/objects/maintenance.lock
// underneath a concurrent walk. On CI that produced two failure shapes
// from this one cause: the walk's lstat racing the unlink
// (`lstat …/.git/objects/maintenance.lock: no such file or directory`,
// go-tests run 32355132650 on main) and a before-snapshot that caught
// the lock meeting an after-snapshot that did not (`after remove: file
// .git/objects/maintenance.lock vanished`, run 32314845330).
//
// Git STATE is still gated, and gated better, by
// TestRemoveFullCycleByteClean's literal D34 arm: `git diff --stat`
// EMPTY plus a `git status --porcelain` residue check, both of which
// re-derive git's view rather than diffing its object files.
//
// The skip is EXACTLY the root .git and nothing else: no fs.ErrNotExist
// is tolerated anywhere in the walk, so a file that vanishes elsewhere
// still fails hard — catching precisely that is what the remove suite
// is for. TestSnapshotSkipsGitStore pins both halves.
func walkSnapshot(root string) (map[string]string, error) {
	gitDir := filepath.Join(root, ".git")
	snap := map[string]string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if path == gitDir {
			if info.IsDir() {
				return filepath.SkipDir
			}
			return nil // a gitfile (worktree/submodule pointer)
		}
		if info.IsDir() {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		snap[rel] = string(b)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return snap, nil
}

func TestApplyAddWidgetFixture(t *testing.T) {
	root := seedWidgetTree(t)
	rep := runFixture(t, root, widgetVars("Timeline", "20260716100000", "42", "43"))

	if !rep.Ok {
		t.Fatalf("report not ok: %+v", rep.Asserts)
	}
	if !rep.Mutated {
		t.Fatal("first run must mutate")
	}
	if rep.Direction != "add" {
		t.Fatalf("direction: got %q", rep.Direction)
	}

	// Files created, spelling-as-transform applied.
	mod := readTreeFile(t, root, "internal/widgets/timeline.go")
	if !strings.Contains(mod, "type Timeline struct{}") || !strings.Contains(mod, "the timeline widget") {
		t.Fatalf("module file wrong:\n%s", mod)
	}
	// SNIPPET/USE resolved to substituted bytes.
	if got := readTreeFile(t, root, "web/widgets/timeline.html"); got != "<div class=\"bp-timeline\"></div>\n" {
		t.Fatalf("USE payload bytes: %q", got)
	}
	// OPAQUE Ts verbatim in the path.
	mig := readTreeFile(t, root, "api/priv/repo/migrations/20260716100000_add_timeline.exs")
	if !strings.Contains(mig, "Migrations.AddTimeline") {
		t.Fatalf("migration wrong:\n%s", mig)
	}

	// Marks planted.
	reg := readTreeFile(t, root, "internal/widgets/registry.go")
	if !strings.Contains(reg, "MARK:registry-timeline") ||
		!strings.Contains(reg, "\tregistry[\"timeline\"] = timelineWidget{}") {
		t.Fatalf("registry injection wrong:\n%s", reg)
	}
	if !strings.Contains(readTreeFile(t, root, "web/widgets/index.css"), "MARK:css-timeline") {
		t.Fatal("css mark not planted")
	}
	cfg := readTreeFile(t, root, "api/config/config.exs")
	if !strings.Contains(cfg, "Barkpark.Workers.Tail},") || !strings.Contains(cfg, "MARK:cron-timeline") {
		t.Fatalf("cron replace wrong:\n%s", cfg)
	}
	// SUCCESSOR pair applied: 42 → 43.
	js := readTreeFile(t, root, "js/widgets/widgets.test.ts")
	if !strings.Contains(js, "toHaveLength(43)") || strings.Contains(js, "toHaveLength(42)") {
		t.Fatalf("count bump wrong:\n%s", js)
	}

	// Asserts: 3 FILE checks evaluated, LOCAL CMD executed, ci deferred.
	if len(rep.Asserts) != 5 {
		t.Fatalf("want 5 asserts, got %d", len(rep.Asserts))
	}
	for i := 0; i < 3; i++ {
		if rep.Asserts[i].Status != AssertPass {
			t.Fatalf("FILE assert %d: %+v", i, rep.Asserts[i])
		}
	}
	if a := rep.Asserts[3]; a.Kind != "cmd" || a.Tier != "" || a.Status != AssertPass {
		t.Fatalf("LOCAL go-build assert must execute and pass: %+v", a)
	}
	if a := rep.Asserts[4]; a.Tier != "ci" || a.Status != AssertDeferred {
		t.Fatalf("TIER ci assert must be deferred, never executed: %+v", a)
	}

	// Receipt persisted.
	if rep.Receipt == "" {
		t.Fatal("mutating run must persist a receipt")
	}
	receiptBytes, err := os.ReadFile(rep.Receipt)
	if err != nil {
		t.Fatalf("receipt unreadable: %v", err)
	}

	// Idempotent re-run: every op skips, nothing mutates, the receipt
	// is not clobbered, the tree is byte-identical.
	before := snapshotTree(t, root)
	rep2 := runFixture(t, root, widgetVars("Timeline", "20260716100000", "42", "43"))
	if rep2.Mutated {
		t.Fatal("re-run with the same vars must be a full no-op")
	}
	for _, op := range rep2.Ops {
		if op.Status != OpSkipped {
			t.Fatalf("re-run op %d not skipped: %+v", op.Index, op)
		}
	}
	if rep2.Receipt != "" {
		t.Fatalf("no-op re-run must not write a receipt, got %q", rep2.Receipt)
	}
	if !rep2.Ok {
		t.Fatalf("re-run asserts must still pass: %+v", rep2.Asserts)
	}
	after := snapshotTree(t, root)
	if len(before) != len(after) {
		t.Fatalf("re-run changed the file set: %d → %d", len(before), len(after))
	}
	for rel, b := range before {
		if after[rel] != b {
			t.Fatalf("re-run changed %s", rel)
		}
	}
	if got, _ := os.ReadFile(rep.Receipt); string(got) != string(receiptBytes) {
		t.Fatal("no-op re-run clobbered the receipt")
	}
}

// TestD26EmptyFenceZeroByteFile — the named D26 test: an empty fence
// is 0 payload lines is a 0-byte file, and CREATE implies mkdir -p.
func TestD26EmptyFenceZeroByteFile(t *testing.T) {
	root := seedWidgetTree(t)
	runFixture(t, root, widgetVars("Timeline", "20260716100000", "42", "43"))
	info, err := os.Stat(filepath.Join(root, "internal", "widgets", "timeline", ".gitkeep"))
	if err != nil {
		t.Fatalf("empty-fence CREATE must mkdir -p and write the file: %v", err)
	}
	if info.Size() != 0 {
		t.Fatalf(".gitkeep must be 0 bytes, got %d", info.Size())
	}
}

// TestReanchorStaticK — D21/D33: three runs with different vars
// accrete FORWARD at the mark-family tail; every prior sibling is
// comma-d in place, the list-last element stays bare; each run-≥2
// receipt records the PRIOR SIBLING block as its pre-image (D35 fat).
func TestReanchorStaticK(t *testing.T) {
	root := seedWidgetTree(t)
	runFixture(t, root, widgetVars("Timeline", "20260716100000", "42", "43"))
	rep2 := runFixture(t, root, widgetVars("Beacon", "20260716110000", "43", "44"))
	rep3 := runFixture(t, root, widgetVars("Compass", "20260716120000", "44", "45"))

	cfg := readTreeFile(t, root, "api/config/config.exs")

	// Forward order: Tail, Timeline, Beacon, Compass.
	idx := func(s string) int { return strings.Index(cfg, s) }
	tail, tl, bc, cp := idx("Workers.Tail"), idx("Workers.Timeline"), idx("Workers.Beacon"), idx("Workers.Compass")
	if tail < 0 || tl < 0 || bc < 0 || cp < 0 || !(tail < tl && tl < bc && bc < cp) {
		t.Fatalf("family order not forward (Tail %d, Timeline %d, Beacon %d, Compass %d):\n%s", tail, tl, bc, cp, cfg)
	}
	// Prior siblings comma-d in place; the list-last element bare.
	for _, s := range []string{"Workers.Tail},", "Workers.Timeline},", "Workers.Beacon},"} {
		if !strings.Contains(cfg, s) {
			t.Fatalf("prior sibling not comma-d: want %q in\n%s", s, cfg)
		}
	}
	if !strings.Contains(cfg, "Workers.Compass}\n") || strings.Contains(cfg, "Workers.Compass},") {
		t.Fatalf("list-last element must stay bare:\n%s", cfg)
	}
	// Each mark planted exactly once.
	for _, m := range []string{"MARK:cron-timeline", "MARK:cron-beacon", "MARK:cron-compass"} {
		if strings.Count(cfg, m) != 1 {
			t.Fatalf("mark %s planted %d times", m, strings.Count(cfg, m))
		}
	}

	// The cron op reanchored on runs 2 and 3.
	cronOp := func(rep *RunReport) OpResult {
		for _, op := range rep.Ops {
			if op.Path == "api/config/config.exs" {
				return op
			}
		}
		t.Fatal("cron op missing from report")
		return OpResult{}
	}
	if op := cronOp(rep2); !op.Reanchored || op.Status != OpReplaced {
		t.Fatalf("run 2 cron op must reanchor: %+v", op)
	}
	if op := cronOp(rep3); !op.Reanchored {
		t.Fatalf("run 3 cron op must reanchor: %+v", op)
	}

	// D35 fat: run-N pre-image is the PRIOR sibling's planted block.
	preOf := func(rep *RunReport) string {
		t.Helper()
		r, err := ReadReceipt(rep.Receipt)
		if err != nil {
			t.Fatal(err)
		}
		for _, op := range r.Ops {
			if op.Reanchored {
				return string(op.PreImage)
			}
		}
		t.Fatal("no reanchored op in receipt")
		return ""
	}
	wantPre2 := "       # scaffy:add-widget Timeline MARK:cron-timeline\n" +
		"       {\"0 * * * *\", Barkpark.Workers.Timeline}\n"
	if got := preOf(rep2); got != wantPre2 {
		t.Fatalf("run 2 pre-image:\ngot  %q\nwant %q", got, wantPre2)
	}
	wantPre3 := "       # scaffy:add-widget Beacon MARK:cron-beacon\n" +
		"       {\"0 * * * *\", Barkpark.Workers.Beacon}\n"
	if got := preOf(rep3); got != wantPre3 {
		t.Fatalf("run 3 pre-image:\ngot  %q\nwant %q", got, wantPre3)
	}

	// The count chain kept parsing: 42 → 45 across three bumps.
	if js := readTreeFile(t, root, "js/widgets/widgets.test.ts"); !strings.Contains(js, "toHaveLength(45)") {
		t.Fatalf("count chain broken:\n%s", js)
	}
}

// TestReanchorTailDesyncFailsLoud — D33: the engine asserts the prior
// block's tail-line shape before splicing and refuses on drift.
func TestReanchorTailDesyncFailsLoud(t *testing.T) {
	root := seedWidgetTree(t)
	runFixture(t, root, widgetVars("Timeline", "20260716100000", "42", "43"))

	// Corrupt the family tail: a stray trailing comma (the exact class
	// a parse-only gate waves through, D34).
	rel := "api/config/config.exs"
	cfg := readTreeFile(t, root, rel)
	writeTreeFile(t, root, rel, strings.Replace(cfg, "Workers.Timeline}\n", "Workers.Timeline},\n", 1))

	_, err := Run(RunOptions{CommandPath: fixturePath, Vars: widgetVars("Beacon", "20260716110000", "43", "44"), RepoRoot: root})
	var ae *ApplyError
	if !errors.As(err, &ae) || !strings.Contains(err.Error(), "desync") {
		t.Fatalf("want ApplyError mentioning desync, got %v", err)
	}
	// Fail-loud means nothing was written — the run aborted pre-flush.
	if strings.Contains(readTreeFile(t, root, rel), "Beacon") {
		t.Fatal("desync run must not write")
	}
}

// writeCommand drops a synthetic .scaffy source into the tree and
// pre-checks it against the validator so a lint drift fails HERE, not
// as a confusing Run error.
func writeCommand(t *testing.T, root, name, src string) string {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	if findings := ValidateFile(path, []byte(src)); len(findings) > 0 {
		t.Fatalf("synthetic command not validator-clean: %v", findings)
	}
	return path
}

const swapFlagSrc = `COMMAND "swap-flag" DESCRIPTION "Swap a settings flag." CONCEPT "flag" DIRECTION "add"

VARIABLE 1 "FlagName" TITLE "Flag" DESCRIPTION "Name of the flag." EXAMPLES "Fast"

IN "conf/settings.txt"
REPLACE
::: old flag line :::
flag = off
::: old flag line :::
WITH
::: new flag line :::
flag = on # MARK:flag-{{.flag-name}}
::: new flag line :::
MARK "flag-{{.flag-name}}"
ASLONG FILE DONT CONTAIN "MARK:flag-{{.flag-name}}"
`

// TestReplaceAnchorExactlyOnce — D20: zero and multiple anchor
// occurrences both fail loud; exactly one applies.
func TestReplaceAnchorExactlyOnce(t *testing.T) {
	vars := map[string]string{"FlagName": "Fast"}

	run := func(settings string) (*RunReport, string, error) {
		root := t.TempDir()
		cmdPath := writeCommand(t, root, "swap-flag.scaffy", swapFlagSrc)
		writeTreeFile(t, root, "conf/settings.txt", settings)
		rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: vars, RepoRoot: root})
		return rep, root, err
	}

	// Twice: fail loud.
	_, _, err := run("flag = off\nflag = off\n")
	var ae *ApplyError
	if !errors.As(err, &ae) || !strings.Contains(err.Error(), "2 times") {
		t.Fatalf("double anchor must fail loud with the count, got %v", err)
	}
	// Zero: fail loud.
	_, _, err = run("nothing here\n")
	if !errors.As(err, &ae) || !strings.Contains(err.Error(), "0 times") {
		t.Fatalf("missing anchor must fail loud, got %v", err)
	}
	// Exactly once: applied, byte-exact swap of only those bytes.
	rep, root, err := run("before\nflag = off\nafter\n")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Ops[0].Status != OpReplaced {
		t.Fatalf("op: %+v", rep.Ops[0])
	}
	if got := readTreeFile(t, root, "conf/settings.txt"); got != "before\nflag = on # MARK:flag-fast\nafter\n" {
		t.Fatalf("swap wrong: %q", got)
	}
}

const twoNotesSrc = `COMMAND "add-two-notes" DESCRIPTION "Two independent note lines." CONCEPT "notes" DIRECTION "add"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name of the note." EXAMPLES "Alpha"

IN "docs/notes-a.txt"
INSERT AFTER FIRST
::: notes-a head :::
alpha-anchor
::: notes-a head :::
WITH
::: notes-a note :::
note-a {{.note-name}} MARK:note-a-{{.note-name}}
::: notes-a note :::
MARK "note-a-{{.note-name}}"

IN "docs/notes-b.txt"
INSERT AFTER FIRST
::: notes-b head :::
beta-anchor
::: notes-b head :::
WITH
::: notes-b note :::
note-b {{.note-name}} MARK:note-b-{{.note-name}}
::: notes-b note :::
MARK "note-b-{{.note-name}}"
`

// TestGuardSkipNeverAbortsSiblings: op 0 skips on its implicit
// planted-MARK guard, op 1 still applies.
func TestGuardSkipNeverAbortsSiblings(t *testing.T) {
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "add-two-notes.scaffy", twoNotesSrc)
	writeTreeFile(t, root, "docs/notes-a.txt", "alpha-anchor\nnote-a alpha MARK:note-a-alpha\n")
	writeTreeFile(t, root, "docs/notes-b.txt", "beta-anchor\n")

	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"NoteName": "Alpha"}, RepoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if op := rep.Ops[0]; op.Status != OpSkipped || !strings.Contains(op.Reason, "MARK:note-a-alpha") {
		t.Fatalf("op 0 must skip on the implicit planted-MARK guard: %+v", op)
	}
	if op := rep.Ops[1]; op.Status != OpInjected {
		t.Fatalf("a sibling skip must not abort op 1: %+v", op)
	}
	if got := readTreeFile(t, root, "docs/notes-b.txt"); got != "beta-anchor\nnote-b alpha MARK:note-b-alpha\n" {
		t.Fatalf("op 1 output: %q", got)
	}
	if !rep.Mutated {
		t.Fatal("run with one applied op must count as mutated")
	}
}

func TestInOpMissingTargetFile(t *testing.T) {
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "add-two-notes.scaffy", twoNotesSrc)
	_, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"NoteName": "Alpha"}, RepoRoot: root})
	var pe *PathMissingError
	if !errors.As(err, &pe) || pe.Path != "docs/notes-a.txt" {
		t.Fatalf("want PathMissingError for docs/notes-a.txt, got %v", err)
	}
}

// TestDryRun — D39: computes everything, writes and executes nothing,
// emits -/+ line diffs; LOCAL CMDs listed as would-run, ci deferred;
// FILE asserts evaluated against the computed post-state.
func TestDryRun(t *testing.T) {
	root := seedWidgetTree(t)
	before := snapshotTree(t, root)

	rep, err := Run(RunOptions{
		CommandPath: fixturePath,
		Vars:        widgetVars("Timeline", "20260716100000", "42", "43"),
		DryRun:      true,
		RepoRoot:    root,
	})
	if err != nil {
		t.Fatal(err)
	}

	// Nothing written: tree byte-identical, no receipt, no .scaffy/.
	after := snapshotTree(t, root)
	if len(before) != len(after) {
		t.Fatalf("dry-run changed the file set: %d → %d", len(before), len(after))
	}
	for rel, b := range before {
		if after[rel] != b {
			t.Fatalf("dry-run changed %s", rel)
		}
	}
	if rep.Receipt != "" {
		t.Fatalf("dry-run must not write a receipt, got %q", rep.Receipt)
	}
	if _, err := os.Stat(filepath.Join(root, ".scaffy")); !os.IsNotExist(err) {
		t.Fatal("dry-run must not create .scaffy/")
	}

	// Diffs computed for every would-touch file.
	if len(rep.Diffs) == 0 {
		t.Fatal("dry-run must emit diffs")
	}
	var regDiff *FileDiff
	for i := range rep.Diffs {
		if rep.Diffs[i].Path == "internal/widgets/registry.go" {
			regDiff = &rep.Diffs[i]
		}
	}
	if regDiff == nil {
		t.Fatal("registry.go diff missing")
	}
	found := false
	for _, l := range regDiff.Lines {
		if strings.HasPrefix(l, "+") && strings.Contains(l, `registry["timeline"]`) {
			found = true
		}
	}
	if !found {
		t.Fatalf("registry diff lacks the + injection line: %v", regDiff.Lines)
	}

	// Asserts: FILE checks pass against the virtual tree; the LOCAL CMD
	// is listed would-run (never executed); ci stays deferred.
	for i := 0; i < 3; i++ {
		if rep.Asserts[i].Status != AssertPass {
			t.Fatalf("dry-run FILE assert %d must evaluate against the computed state: %+v", i, rep.Asserts[i])
		}
	}
	if rep.Asserts[3].Status != AssertWouldRun {
		t.Fatalf("dry-run LOCAL CMD must be would-run: %+v", rep.Asserts[3])
	}
	if rep.Asserts[4].Status != AssertDeferred {
		t.Fatalf("ci CMD must stay deferred in dry-run: %+v", rep.Asserts[4])
	}
}

const checkEnvSrc = `COMMAND "check-env" DESCRIPTION "D38 assert exec probes." CONCEPT "probe" DIRECTION "add"

VARIABLE 1 "ProofName" TITLE "Proof" DESCRIPTION "Stem of the cd proof file." EXAMPLES "cd-proof"

ASSERT CMD "cd sub && printf ok > {{.proof-name}}.txt"
ASSERT CMD "printenv CC > cc-env.txt"
ASSERT CMD "CC=/custom/cc printenv CC > cc-inline.txt"
ASSERT CMD "printf x > ci-proof.txt" TIER ci
`

// TestAssertCmdD38 — sh -c verbatim from RepoRoot (strings carry their
// own cd), CC=/usr/bin/clang appended to the env, inline prefixes
// honored by the shell, tokens substituted, TIER ci never executed.
//
// The CC arm asserted here is the ABSENT-CC default, so this test must
// PIN the ambient CC to absent rather than inherit whatever the operator
// exported. D101 amended D38 to preserve a stranger's CC verbatim (see
// TestAssertCmdD101CCWhenUnset, which covers both arms), and that
// amendment silently made this assertion environment-dependent: it reds
// under the CC=/usr/bin/cc every contributor to this repo must export
// for CGO. The product behaviour is right; reading the ambient value
// instead of declaring it was the defect.
func TestAssertCmdD38(t *testing.T) {
	if old, ok := os.LookupEnv("CC"); ok {
		os.Unsetenv("CC")
		t.Cleanup(func() { os.Setenv("CC", old) })
	}
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "check-env.scaffy", checkEnvSrc)
	if err := os.Mkdir(filepath.Join(root, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}

	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"ProofName": "cd-proof"}, RepoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if !rep.Ok {
		t.Fatalf("asserts failed: %+v", rep.Asserts)
	}

	// cd-chain executed from RepoRoot, token substituted into the cmd.
	if got := readTreeFile(t, root, "sub/cd-proof.txt"); got != "ok" {
		t.Fatalf("cd-chained CMD wrote %q", got)
	}
	// Env carries the appended CC (D38).
	if got := readTreeFile(t, root, "cc-env.txt"); got != "/usr/bin/clang\n" {
		t.Fatalf("CC env: %q, want /usr/bin/clang", got)
	}
	// An inline CC= prefix wins over the appended env — shell
	// semantics, the reason argv-splitting mis-executes (D38).
	if got := readTreeFile(t, root, "cc-inline.txt"); got != "/custom/cc\n" {
		t.Fatalf("inline CC: %q, want /custom/cc", got)
	}
	// TIER ci: deferred, never executed — its side effect must not exist.
	if rep.Asserts[3].Status != AssertDeferred {
		t.Fatalf("ci assert: %+v", rep.Asserts[3])
	}
	if _, err := os.Stat(filepath.Join(root, "ci-proof.txt")); !os.IsNotExist(err) {
		t.Fatal("TIER ci command was executed — it must never run locally (D38)")
	}
}

const ccProbeSrc = `COMMAND "cc-probe" DESCRIPTION "D101 CC-when-unset probe." CONCEPT "probe" DIRECTION "add"

ASSERT CMD "printf '%s' \"$CC\" > cc-probe.txt"
`

// TestAssertCmdD101CCWhenUnset — D101 (amends D38): the assert env
// defaults CC=/usr/bin/clang ONLY when the ambient env carries no CC.
// Both branches run through the real assert-exec path (sh -c echoing
// $CC): a stranger's ambient CC survives verbatim; an absent CC yields
// the /usr/bin/clang default. The "preserved" branch FAILS against the
// old unconditional append (which clobbered any ambient CC).
func TestAssertCmdD101CCWhenUnset(t *testing.T) {
	t.Run("ambient CC preserved verbatim", func(t *testing.T) {
		t.Setenv("CC", "sentinel-cc-9f")
		root := t.TempDir()
		cmdPath := writeCommand(t, root, "cc-probe.scaffy", ccProbeSrc)
		rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: nil, RepoRoot: root})
		if err != nil {
			t.Fatal(err)
		}
		if !rep.Ok {
			t.Fatalf("asserts failed: %+v", rep.Asserts)
		}
		if got := readTreeFile(t, root, "cc-probe.txt"); got != "sentinel-cc-9f" {
			t.Fatalf("ambient CC clobbered: got %q, want sentinel-cc-9f", got)
		}
	})

	t.Run("absent CC defaults to clang", func(t *testing.T) {
		if old, ok := os.LookupEnv("CC"); ok {
			os.Unsetenv("CC")
			t.Cleanup(func() { os.Setenv("CC", old) })
		}
		root := t.TempDir()
		cmdPath := writeCommand(t, root, "cc-probe.scaffy", ccProbeSrc)
		rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: nil, RepoRoot: root})
		if err != nil {
			t.Fatal(err)
		}
		if !rep.Ok {
			t.Fatalf("asserts failed: %+v", rep.Asserts)
		}
		if got := readTreeFile(t, root, "cc-probe.txt"); got != "/usr/bin/clang" {
			t.Fatalf("absent-CC default: got %q, want /usr/bin/clang", got)
		}
	})
}

const failCmdSrc = `COMMAND "check-fail" DESCRIPTION "Failing assert probe." CONCEPT "probe" DIRECTION "add"

ASSERT CMD "printf boom && exit 3"
`

func TestAssertCmdFailure(t *testing.T) {
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "check-fail.scaffy", failCmdSrc)
	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: nil, RepoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if rep.Ok {
		t.Fatal("failing assert must flip Ok")
	}
	if a := rep.Asserts[0]; a.Status != AssertFail || !strings.Contains(a.Detail, "boom") {
		t.Fatalf("failure detail must carry the output: %+v", a)
	}
}

const sleepCmdSrc = `COMMAND "check-sleep" DESCRIPTION "Timeout probe." CONCEPT "probe" DIRECTION "add"

ASSERT CMD "sleep 5"
`

func TestAssertCmdTimeout(t *testing.T) {
	saved := assertCmdTimeout
	assertCmdTimeout = 200 * time.Millisecond
	defer func() { assertCmdTimeout = saved }()

	root := t.TempDir()
	cmdPath := writeCommand(t, root, "check-sleep.scaffy", sleepCmdSrc)
	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: nil, RepoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if a := rep.Asserts[0]; a.Status != AssertFail || !strings.Contains(a.Detail, "timeout") {
		t.Fatalf("timed-out CMD must fail with a timeout detail: %+v", a)
	}
}

// TestMidOpFailureWritesNothing — the overlay abort invariant: when an
// op FAILS mid-run (here the registry INSERT, after four CREATEs
// already mutated the overlay), the run aborts with NOTHING on disk —
// no earlier op's file, no receipt (fail-loud writes nothing).
func TestMidOpFailureWritesNothing(t *testing.T) {
	root := seedWidgetTree(t)
	// Remove the registry anchor so op 4 fails after ops 0–3 succeeded
	// in the overlay.
	writeTreeFile(t, root, "internal/widgets/registry.go", "package widgets\n")
	_, err := Run(RunOptions{CommandPath: fixturePath, Vars: widgetVars("Timeline", "20260716100000", "42", "43"), RepoRoot: root})
	var ae *ApplyError
	if !errors.As(err, &ae) {
		t.Fatalf("want ApplyError from the missing anchor, got %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(root, "internal", "widgets", "timeline.go")); !os.IsNotExist(statErr) {
		t.Fatal("mid-op failure leaked an earlier CREATE to disk")
	}
	if _, statErr := os.Stat(filepath.Join(root, ".scaffy")); !os.IsNotExist(statErr) {
		t.Fatal("mid-op failure persisted a receipt")
	}
}

const partialFlushSrc = `COMMAND "two-dir-notes" DESCRIPTION "Two notes in different directories." CONCEPT "notes" DIRECTION "add"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name of the note." EXAMPLES "Alpha"

CREATE FILE IF ABSENT "docs/a/notes-a.txt"
::: notes-a body :::
note-a {{.note-name}}
::: notes-a body :::

CREATE FILE IF ABSENT "docs/locked/notes-b.txt"
::: notes-b body :::
note-b {{.note-name}}
::: notes-b body :::
`

// TestFlushPartialFailureLeavesFirstFileUntouched — the all-or-nothing
// guarantee stated at apply.go:6-8: op 0 CREATEs a file in a normal
// writable directory, op 1 CREATEs a file in a directory with no write
// permission. Both CREATEs need to add a brand-new directory entry, so
// the SAME permission wall fails op 1 under either write strategy —
// but op 0's file must come out the other side non-existent here: no
// scaffy temp file left behind, and no receipt written. This reds
// against the pre-fix per-file os.WriteFile loop, which committed op
// 0 straight to its real path before ever reaching op 1's failure —
// see the MUTATION PROOF recorded against this task's acceptance
// criteria for the reverted-fix failure output.
func TestFlushPartialFailureLeavesFirstFileUntouched(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: a read-only directory is still writable, so this arm cannot be exercised")
	}
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "two-dir-notes.scaffy", partialFlushSrc)

	lockedDir := filepath.Join(root, "docs", "locked")
	if err := os.MkdirAll(lockedDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(lockedDir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(lockedDir, 0o755) })

	// Probe: confirm this sandbox actually enforces the permission
	// before trusting a pass born from a lock nobody honors.
	if probe, err := os.CreateTemp(lockedDir, "probe-*"); err == nil {
		probe.Close()
		os.Remove(probe.Name())
		t.Skip("this sandbox does not enforce directory write permissions; the permission arm is unreachable here")
	}

	aPath := filepath.Join(root, "docs", "a", "notes-a.txt")

	_, runErr := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"NoteName": "Alpha"}, RepoRoot: root})
	if runErr == nil {
		t.Fatal("want an error from the locked second directory, got nil")
	}
	t.Logf("flush error (expected): %v", runErr)

	// Op 0's file must not exist at all — a partial write must not
	// survive op 1's failure, even though op 0 staged/wrote cleanly.
	if _, statErr := os.Stat(aPath); !os.IsNotExist(statErr) {
		t.Fatalf("op 0's file exists despite op 1 failing — partial write leaked to disk (stat err: %v)", statErr)
	}

	// No scaffy temp file left behind in EITHER directory.
	for _, dir := range []string{filepath.Join(root, "docs", "a"), lockedDir} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			if os.IsNotExist(err) {
				continue // docs/a itself never got created under the fix
			}
			t.Fatal(err)
		}
		for _, e := range entries {
			if strings.Contains(e.Name(), "scaffy-tmp") {
				t.Fatalf("temp file left behind in %s: %s", dir, e.Name())
			}
		}
	}

	// No receipt persisted — the run never mutated successfully.
	if _, err := os.Stat(filepath.Join(root, ".scaffy")); !os.IsNotExist(err) {
		t.Fatal("a failed flush must not leave a receipt behind")
	}
}

// TestFlushPreservesExistingFileMode — the fix must not trade byte
// atomicity for mode loss: REPLACE overwrites an existing file through
// a temp-file rename, and the temp file's mode is explicitly carried
// over from the file it replaces rather than os.CreateTemp's 0600.
func TestFlushPreservesExistingFileMode(t *testing.T) {
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "swap-flag.scaffy", swapFlagSrc)
	settingsPath := filepath.Join(root, "conf", "settings.txt")
	writeTreeFile(t, root, "conf/settings.txt", "before\nflag = off\nafter\n")
	if err := os.Chmod(settingsPath, 0o640); err != nil {
		t.Fatal(err)
	}

	if _, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"FlagName": "Fast"}, RepoRoot: root}); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(settingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("overwrite must preserve the existing file's mode: got %o, want %o", info.Mode().Perm(), 0o640)
	}
}

// TestValidateFilePreGate: a command with findings never reaches the
// applier (D37 — ValidateFile, not bare Parse).
func TestValidateFilePreGate(t *testing.T) {
	root := t.TempDir()
	// Missing DIRECTION (E-020) — parseable, lint-red.
	src := `COMMAND "bad" DESCRIPTION "Missing direction." CONCEPT "bad"

CREATE FILE IF ABSENT "docs/x.txt"
::: x body :::
x
::: x body :::
`
	path := filepath.Join(root, "bad.scaffy")
	if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Run(RunOptions{CommandPath: path, Vars: nil, RepoRoot: root})
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("want ValidationError from the pre-gate, got %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(root, "docs", "x.txt")); !os.IsNotExist(statErr) {
		t.Fatal("a red command must apply nothing")
	}
}

// TestPathEscapeRefused: a substituted path may not leave the repo root.
func TestPathEscapeRefused(t *testing.T) {
	root := t.TempDir()
	src := `COMMAND "escape" DESCRIPTION "Escape probe." CONCEPT "escape" DIRECTION "add"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name." EXAMPLES "Alpha"

CREATE FILE IF ABSENT "docs/{{.note-name}}.txt"
::: escape body :::
note MARK:esc-{{.note-name}}
::: escape body :::
`
	cmdPath := writeCommand(t, root, "escape.scaffy", src)
	_, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"NoteName": "../../evil"}, RepoRoot: root})
	if err == nil || !strings.Contains(err.Error(), "escape") {
		t.Fatalf("path escape must refuse, got %v", err)
	}
}
