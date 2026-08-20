package scaffy

// remove_test.go — protective tests for the D36 receipt-replay reverse
// path. THE gate is byte-clean (D34): whole-tree byte equality between
// the pre-apply tree and the post-remove tree (receipts excluded — the
// .scaffy/ store is gitignored and intentionally survives a remove so a
// second remove skips clean), plus a literal `git diff --stat` EMPTY
// proof on the full fixture cycle. Parse-only gates are proven vacuous
// (Elixir parses stray trailing commas) and appear nowhere here.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// snapshotSansReceipts is snapshotTree minus the .scaffy/ store: the
// receipt intentionally persists across a remove (idempotent second
// remove) and is gitignored, so byte-clean is judged without it.
func snapshotSansReceipts(t *testing.T, root string) map[string]string {
	t.Helper()
	snap := snapshotTree(t, root)
	for rel := range snap {
		if strings.HasPrefix(filepath.ToSlash(rel), ".scaffy/") {
			delete(snap, rel)
		}
	}
	return snap
}

// churnGitMaintenanceLock models git's DETACHED background
// auto-maintenance: `git commit` spawns `git maintenance run --auto`,
// which creates and unlinks .git/objects/maintenance.lock while the
// test's own snapshot walk is in flight. Churning the exact path in a
// tight loop turns that rare CI race into a reliable one, so the guard
// below is provable rather than merely quiet.
func churnGitMaintenanceLock(t *testing.T, root string) func() {
	t.Helper()
	objs := filepath.Join(root, ".git", "objects")
	if err := os.MkdirAll(objs, 0o755); err != nil {
		t.Fatal(err)
	}
	lock := filepath.Join(objs, "maintenance.lock")
	var stop atomic.Bool
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for !stop.Load() {
			_ = os.WriteFile(lock, []byte("pid\n"), 0o644)
			_ = os.Remove(lock)
		}
	}()
	return func() {
		stop.Store(true)
		wg.Wait()
		_ = os.Remove(lock)
	}
}

// TestSnapshotSkipsGitStore — the guard behind TestRemoveFullCycleByteClean.
//
// That test git-inits its fixture root, so before this guard the
// byte-equality snapshot walked .git/ too and raced git's background
// maintenance lock, producing two failure shapes on CI from one cause:
// `lstat …/.git/objects/maintenance.lock: no such file or directory`
// (run 32355132650, main) and `after remove: file
// .git/objects/maintenance.lock vanished` (run 32314845330, main).
//
// Both halves of the narrowing are pinned here, because a guard that
// fixed the flake by swallowing missing files would also blind the
// remove suite to the removal defects it exists to catch:
//
//	(1) under lock churn the walk neither errors nor captures .git/;
//	(2) the skip is .git/ ALONE — ordinary files are still captured,
//	    lookalike names are not exempt, and a file that disappears
//	    outside .git/ is still visible to assertTreesEqual.
func TestSnapshotSkipsGitStore(t *testing.T) {
	seed := func(t *testing.T) string {
		t.Helper()
		root := t.TempDir()
		for _, rel := range []string{"go.mod", "a/b.txt", "a/c.txt", "d/e.txt", ".gitignore", ".git-not-the-store/keep.txt"} {
			writeTreeFile(t, root, rel, "x\n")
		}
		for _, rel := range []string{".git/HEAD", ".git/objects/aa/1", ".git/objects/bb/2"} {
			writeTreeFile(t, root, rel, "o\n")
		}
		return root
	}

	t.Run("survives maintenance-lock churn", func(t *testing.T) {
		root := seed(t)
		stop := churnGitMaintenanceLock(t, root)
		defer stop()

		// 200 walks: against the unguarded walk this reproduces at
		// roughly one failure every other iteration, so a clean batch
		// is evidence rather than luck.
		const walks = 200
		for i := 0; i < walks; i++ {
			snap, err := walkSnapshot(root)
			if err != nil {
				t.Fatalf("walk %d raced git maintenance: %v", i, err)
			}
			for rel := range snap {
				if strings.HasPrefix(filepath.ToSlash(rel), ".git/") {
					t.Fatalf("walk %d captured a git-internal path: %s", i, rel)
				}
			}
		}
	})

	t.Run("skips the git store alone", func(t *testing.T) {
		root := seed(t)
		snap, err := walkSnapshot(root)
		if err != nil {
			t.Fatal(err)
		}
		// Everything outside the store is captured, .gitignore and a
		// .git-prefixed LOOKALIKE directory included.
		for _, rel := range []string{"go.mod", "a/b.txt", "a/c.txt", "d/e.txt", ".gitignore", ".git-not-the-store/keep.txt"} {
			if _, ok := snap[filepath.FromSlash(rel)]; !ok {
				t.Errorf("snapshot dropped %s — the skip must be the git store alone", rel)
			}
		}
		// The store itself is absent, though it is right there on disk.
		if _, err := os.Stat(filepath.Join(root, ".git", "HEAD")); err != nil {
			t.Fatalf("test setup: the git store must exist on disk: %v", err)
		}
		for rel := range snap {
			if filepath.ToSlash(rel) == ".git" || strings.HasPrefix(filepath.ToSlash(rel), ".git/") {
				t.Errorf("snapshot captured git internals: %s", rel)
			}
		}
	})

	t.Run("a removal outside the store is still caught", func(t *testing.T) {
		// The non-swallow arm: no fs.ErrNotExist tolerance was added,
		// so a real disappearance is still a visible difference — which
		// is exactly what assertTreesEqual reports as "vanished".
		root := seed(t)
		before, err := walkSnapshot(root)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(filepath.Join(root, "a", "b.txt")); err != nil {
			t.Fatal(err)
		}
		after, err := walkSnapshot(root)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := before[filepath.FromSlash("a/b.txt")]; !ok {
			t.Fatal("test setup: a/b.txt must be in the before snapshot")
		}
		if _, ok := after[filepath.FromSlash("a/b.txt")]; ok {
			t.Fatal("a deleted file must vanish from the snapshot — the guard must not swallow it")
		}
	})
}

func assertTreesEqual(t *testing.T, phase string, want, got map[string]string) {
	t.Helper()
	for rel, b := range want {
		g, ok := got[rel]
		if !ok {
			t.Fatalf("%s: file %s vanished", phase, rel)
		}
		if g != b {
			t.Fatalf("%s: %s not byte-identical\nwant %q\ngot  %q", phase, rel, b, g)
		}
	}
	for rel := range got {
		if _, ok := want[rel]; !ok {
			t.Fatalf("%s: unexpected file %s", phase, rel)
		}
	}
}

func removeFixture(t *testing.T, root string, vars map[string]string) *RunReport {
	t.Helper()
	rep, err := Remove(RemoveOptions{CommandPath: fixturePath, Vars: vars, RepoRoot: root})
	if err != nil {
		t.Fatalf("Remove: %v", err)
	}
	return rep
}

// TestRemoveFullCycleByteClean — the north-star cycle on the full
// add-widget fixture: run → remove → byte-clean, proven BOTH by
// whole-tree byte equality and by the charter's literal D34 gate,
// `git diff --stat` EMPTY over a real git repo.
func TestRemoveFullCycleByteClean(t *testing.T) {
	root := seedWidgetTree(t)

	git := func(args ...string) string {
		t.Helper()
		// gc.auto/maintenance.auto off: `git commit` otherwise spawns a
		// DETACHED `git maintenance run --auto` that keeps writing into
		// this t.TempDir after the test returns. walkSnapshot already
		// skips .git/ so the byte-equality arm no longer races it, but a
		// background process outliving the fixture can still lose the
		// TempDir cleanup a race; leave it unstarted.
		full := append([]string{"-C", root, "-c", "user.email=scaffy@test", "-c", "user.name=scaffy", "-c", "commit.gpgsign=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false"}, args...)
		out, err := exec.Command("git", full...).CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
		return string(out)
	}
	if _, err := exec.LookPath("git"); err != nil {
		t.Fatal("git required for the D34 gate")
	}
	git("init", "-q")
	git("add", "-A")
	git("commit", "-qm", "seed")

	before := snapshotSansReceipts(t, root)
	vars := widgetVars("Timeline", "20260716100000", "42", "43")
	runFixture(t, root, vars)

	rep := removeFixture(t, root, vars)
	if !rep.Ok {
		t.Fatalf("remove not ok: %+v", rep)
	}
	if !rep.Mutated {
		t.Fatal("a real remove must mutate")
	}
	if rep.Receipt == "" {
		t.Fatal("report must name the replayed receipt")
	}

	// Per-kind inversion statuses, in replay (reverse-receipt) order.
	statusByKind := map[string][]string{}
	for _, op := range rep.Ops {
		statusByKind[op.Kind] = append(statusByKind[op.Kind], op.Status)
	}
	for _, want := range []struct {
		kind, status string
		n            int
	}{
		{"create", OpDeleted, 4},
		{"insert-after-first", OpRemoved, 1},
		{"insert-after-last", OpRemoved, 1},
		{"replace", OpRestored, 2},
	} {
		got := statusByKind[want.kind]
		if len(got) != want.n {
			t.Fatalf("%s: want %d ops, got %v", want.kind, want.n, got)
		}
		for _, s := range got {
			if s != want.status {
				t.Fatalf("%s: want status %s, got %v", want.kind, want.status, got)
			}
		}
	}

	// Byte-clean, gate 1: whole-tree byte equality (D34).
	assertTreesEqual(t, "after remove", before, snapshotSansReceipts(t, root))

	// Byte-clean, gate 2: the literal charter gate — git diff --stat
	// EMPTY. Untracked residue must be the gitignored .scaffy/ store
	// alone.
	if diff := strings.TrimSpace(git("diff", "--stat")); diff != "" {
		t.Fatalf("git diff --stat not empty after run→remove:\n%s", diff)
	}
	status := strings.TrimSpace(git("status", "--porcelain"))
	t.Logf("D34 gate: git diff --stat = EMPTY; git status --porcelain = %q", status)
	for _, ln := range strings.Split(status, "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasSuffix(ln, ".scaffy/") {
			continue
		}
		t.Fatalf("unexpected git residue after run→remove: %q", ln)
	}

	// The receipt persists — the seam a second remove replays.
	if _, err := os.Stat(rep.Receipt); err != nil {
		t.Fatalf("receipt must survive a successful remove: %v", err)
	}
}

const comboSrc = `COMMAND "add-combo" DESCRIPTION "One of each mutating op kind." CONCEPT "combo" DIRECTION "add"

VARIABLE 1 "ComboName" TITLE "Combo" DESCRIPTION "Name of the combo." EXAMPLES "Alpha"

CREATE FILE IF ABSENT "docs/{{.combo-name}}.txt"
::: combo file :::
combo {{.combo-name}}
::: combo file :::

IN "docs/list.txt"
INSERT AFTER FIRST
::: list head :::
head-anchor
::: list head :::
WITH
::: combo entry :::
entry {{.combo-name}} MARK:combo-entry-{{.combo-name}}
::: combo entry :::
MARK "combo-entry-{{.combo-name}}"

IN "docs/flag.txt"
REPLACE
::: flag off :::
flag = off
::: flag off :::
WITH
::: flag on :::
flag = on # MARK:combo-flag-{{.combo-name}}
::: flag on :::
MARK "combo-flag-{{.combo-name}}"
ASLONG FILE DONT CONTAIN "MARK:combo-flag-{{.combo-name}}"
`

func seedComboTree(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "add-combo.scaffy", comboSrc)
	writeTreeFile(t, root, "docs/list.txt", "head-anchor\ntail\n")
	writeTreeFile(t, root, "docs/flag.txt", "before\nflag = off\nafter\n")
	return root, cmdPath
}

var comboVars = map[string]string{"ComboName": "Alpha"}

// TestRemovePerOpRoundTrip — apply→remove byte-clean per op kind:
// CREATE deleted, INSERT excised, REPLACE pre-image restored (the comma
// and every other byte restored implicitly by the image swap).
func TestRemovePerOpRoundTrip(t *testing.T) {
	root, cmdPath := seedComboTree(t)
	before := snapshotSansReceipts(t, root)

	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: comboVars, RepoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if !rep.Mutated {
		t.Fatal("apply must mutate")
	}

	rrep, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: comboVars, RepoRoot: root})
	if err != nil {
		t.Fatalf("Remove: %v", err)
	}
	// Replay order is reverse-receipt: replace, insert, create.
	wantStatuses := []string{OpRestored, OpRemoved, OpDeleted}
	if len(rrep.Ops) != len(wantStatuses) {
		t.Fatalf("want %d ops, got %+v", len(wantStatuses), rrep.Ops)
	}
	for i, want := range wantStatuses {
		if rrep.Ops[i].Status != want {
			t.Fatalf("op %d: want %s, got %+v", i, want, rrep.Ops[i])
		}
	}
	assertTreesEqual(t, "after remove", before, snapshotSansReceipts(t, root))
}

// TestRemoveReanchorLIFOByteClean — REANCHOR ×2 with different vars,
// then LIFO removes (Beacon first, Timeline second): each replay is a
// pure image swap, and the tree lands byte-clean.
func TestRemoveReanchorLIFOByteClean(t *testing.T) {
	root := seedWidgetTree(t)
	before := snapshotSansReceipts(t, root)

	varsT := widgetVars("Timeline", "20260716100000", "42", "43")
	varsB := widgetVars("Beacon", "20260716110000", "43", "44")
	runFixture(t, root, varsT)
	runFixture(t, root, varsB)

	// LIFO: the later sibling first.
	repB := removeFixture(t, root, varsB)
	if !repB.Mutated {
		t.Fatal("Beacon remove must mutate")
	}
	// After removing Beacon the tree must equal the post-Timeline state:
	// Timeline's cron tuple separator-bare again.
	cfg := readTreeFile(t, root, "api/config/config.exs")
	if !strings.Contains(cfg, "Workers.Timeline}\n") || strings.Contains(cfg, "Beacon") {
		t.Fatalf("Beacon remove wrong:\n%s", cfg)
	}

	repT := removeFixture(t, root, varsT)
	if !repT.Mutated {
		t.Fatal("Timeline remove must mutate")
	}
	assertTreesEqual(t, "after LIFO removes", before, snapshotSansReceipts(t, root))
}

// TestRemoveOutOfOrderRefusesNamingSibling — the other order: removing
// the EARLIER family member while a later sibling is planted finds its
// post-image mutated (the sibling's splice comma-d its tail), REFUSES
// with SCAFFY-DRIFT naming the interfering sibling, and writes NOTHING
// — including inversions that succeeded in the overlay before the
// drift was found (a failed remove is atomic).
func TestRemoveOutOfOrderRefusesNamingSibling(t *testing.T) {
	root := seedWidgetTree(t)
	varsT := widgetVars("Timeline", "20260716100000", "42", "43")
	varsB := widgetVars("Beacon", "20260716110000", "43", "44")
	runFixture(t, root, varsT)
	runFixture(t, root, varsB)

	applied := snapshotSansReceipts(t, root)
	_, err := Remove(RemoveOptions{CommandPath: fixturePath, Vars: varsT, RepoRoot: root})
	var de *DriftError
	if !errors.As(err, &de) {
		t.Fatalf("want DriftError, got %v", err)
	}
	if !strings.Contains(err.Error(), "SCAFFY-DRIFT") {
		t.Fatalf("drift must fail loud as SCAFFY-DRIFT: %v", err)
	}
	if !strings.Contains(err.Error(), "MARK:cron-beacon") || !strings.Contains(err.Error(), "LIFO") {
		t.Fatalf("drift must name the interfering later sibling: %v", err)
	}
	// file:line shape on every finding.
	for _, f := range de.Findings {
		if f.Path == "" || f.Line < 1 {
			t.Fatalf("finding lacks file:line: %+v", f)
		}
	}
	// Atomic refusal: Timeline's creates/inserts DID invert in the
	// overlay before the cron drift surfaced — none of it may be on
	// disk.
	assertTreesEqual(t, "after refused remove", applied, snapshotSansReceipts(t, root))
}

// TestRemoveSecondRemoveSkipsClean — outcome (b) of drift-refusal:
// after a successful remove the receipt persists; a second remove finds
// every op already retracted and skips clean (idempotent, exit-0
// semantics — nil error, nothing mutated).
func TestRemoveSecondRemoveSkipsClean(t *testing.T) {
	root := seedWidgetTree(t)
	vars := widgetVars("Timeline", "20260716100000", "42", "43")
	runFixture(t, root, vars)
	removeFixture(t, root, vars)

	before := snapshotSansReceipts(t, root)
	rep := removeFixture(t, root, vars)
	if rep.Mutated {
		t.Fatal("second remove must be a full no-op")
	}
	if !rep.Ok {
		t.Fatalf("second remove must succeed: %+v", rep)
	}
	for _, op := range rep.Ops {
		if op.Status != OpSkipped || !strings.Contains(op.Reason, "already retracted") {
			t.Fatalf("second remove op must skip as already retracted: %+v", op)
		}
	}
	assertTreesEqual(t, "after second remove", before, snapshotSansReceipts(t, root))
}

// TestRemoveHandMutatedRefusesWritesNothing — outcome (c): a created
// file whose bytes drifted from the receipt post-image refuses with a
// file:line SCAFFY-DRIFT, and inversions that had already succeeded in
// the overlay (the count-bump REPLACE replays before the create in
// reverse order) never reach disk.
func TestRemoveHandMutatedRefusesWritesNothing(t *testing.T) {
	root := seedWidgetTree(t)
	vars := widgetVars("Timeline", "20260716100000", "42", "43")
	runFixture(t, root, vars)

	// Hand-edit the created module file (op 0 — the LAST op replayed).
	mod := readTreeFile(t, root, "internal/widgets/timeline.go")
	writeTreeFile(t, root, "internal/widgets/timeline.go", mod+"\n// hand edit\n")
	applied := snapshotSansReceipts(t, root)

	_, err := Remove(RemoveOptions{CommandPath: fixturePath, Vars: vars, RepoRoot: root})
	var de *DriftError
	if !errors.As(err, &de) {
		t.Fatalf("want DriftError, got %v", err)
	}
	f := de.Findings[0]
	if f.Path != "internal/widgets/timeline.go" || f.Line < 1 {
		t.Fatalf("drift must carry the mutated file:line: %+v", f)
	}
	if !strings.Contains(err.Error(), "internal/widgets/timeline.go:") || !strings.Contains(err.Error(), "hand-edited") {
		t.Fatalf("drift message: %v", err)
	}
	// Mid-remove abort writes nothing: the count bump (43→42) and every
	// other inversion stayed in the discarded overlay.
	if js := readTreeFile(t, root, "js/widgets/widgets.test.ts"); !strings.Contains(js, "toHaveLength(43)") {
		t.Fatalf("refused remove leaked an overlay inversion to disk:\n%s", js)
	}
	assertTreesEqual(t, "after refused remove", applied, snapshotSansReceipts(t, root))
}

// TestRemoveMutatedInsertBlockRefuses — outcome (c) on an INSERT: the
// planted mark survives but the recorded post-image is gone (the block
// was hand-mutated) — never a silent skip.
func TestRemoveMutatedInsertBlockRefuses(t *testing.T) {
	root, cmdPath := seedComboTree(t)
	if _, err := Run(RunOptions{CommandPath: cmdPath, Vars: comboVars, RepoRoot: root}); err != nil {
		t.Fatal(err)
	}
	list := readTreeFile(t, root, "docs/list.txt")
	writeTreeFile(t, root, "docs/list.txt", strings.Replace(list, "entry alpha", "entry ALPHA-EDITED", 1))

	_, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: comboVars, RepoRoot: root})
	var de *DriftError
	if !errors.As(err, &de) {
		t.Fatalf("want DriftError, got %v", err)
	}
	if !strings.Contains(err.Error(), "docs/list.txt:") || !strings.Contains(err.Error(), "hand-mutated") {
		t.Fatalf("mutated insert block must refuse loudly: %v", err)
	}
}

// TestRemoveAmbiguousPostImageRefuses — outcome (c), multiple matches:
// a duplicated post-image is never fuzzy-matched.
func TestRemoveAmbiguousPostImageRefuses(t *testing.T) {
	root, cmdPath := seedComboTree(t)
	if _, err := Run(RunOptions{CommandPath: cmdPath, Vars: comboVars, RepoRoot: root}); err != nil {
		t.Fatal(err)
	}
	entry := "entry alpha MARK:combo-entry-alpha\n"
	list := readTreeFile(t, root, "docs/list.txt")
	writeTreeFile(t, root, "docs/list.txt", list+entry)

	_, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: comboVars, RepoRoot: root})
	var de *DriftError
	if !errors.As(err, &de) {
		t.Fatalf("want DriftError, got %v", err)
	}
	if !strings.Contains(err.Error(), "2 times") {
		t.Fatalf("ambiguous match must refuse with the count: %v", err)
	}
}

// TestRemoveMissingReceipt — no receipt for the command+vars key is a
// not-found-shaped error (CLI exit 4), and the keying is per-vars: a
// receipt written under other vars does not match.
func TestRemoveMissingReceipt(t *testing.T) {
	root := seedWidgetTree(t)
	vars := widgetVars("Timeline", "20260716100000", "42", "43")

	_, err := Remove(RemoveOptions{CommandPath: fixturePath, Vars: vars, RepoRoot: root})
	var rm *ReceiptMissingError
	if !errors.As(err, &rm) {
		t.Fatalf("want ReceiptMissingError, got %v", err)
	}
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("ReceiptMissingError must be not-found-shaped (errors.Is fs.ErrNotExist)")
	}

	// Per-command+vars keying: Timeline's receipt never answers for
	// Beacon's vars.
	runFixture(t, root, vars)
	_, err = Remove(RemoveOptions{CommandPath: fixturePath, Vars: widgetVars("Beacon", "20260716110000", "43", "44"), RepoRoot: root})
	if !errors.As(err, &rm) {
		t.Fatalf("different vars must miss the receipt, got %v", err)
	}
}

// TestRemoveDryRun — report what would be inverted, touch nothing: no
// writes, no receipt deletion, per-file -/+ diffs.
func TestRemoveDryRun(t *testing.T) {
	root := seedWidgetTree(t)
	vars := widgetVars("Timeline", "20260716100000", "42", "43")
	runFixture(t, root, vars)
	applied := snapshotTree(t, root)

	rep, err := Remove(RemoveOptions{CommandPath: fixturePath, Vars: vars, DryRun: true, RepoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if !rep.DryRun || !rep.Mutated {
		t.Fatalf("dry-run report wrong: %+v", rep)
	}
	if len(rep.Ops) == 0 || len(rep.Diffs) == 0 {
		t.Fatalf("dry-run must report ops and diffs: %+v", rep)
	}
	var found bool
	for _, d := range rep.Diffs {
		if d.Path == "js/widgets/widgets.test.ts" {
			for _, ln := range d.Lines {
				if strings.HasPrefix(ln, "+") && strings.Contains(ln, "toHaveLength(42)") {
					found = true
				}
			}
		}
	}
	if !found {
		t.Fatalf("dry-run diff must show the restored pre-image line: %+v", rep.Diffs)
	}
	// Nothing touched — receipt included.
	assertTreesEqual(t, "after dry-run remove", applied, snapshotTree(t, root))
}

const removeNoteSrc = `COMMAND "remove-note" DESCRIPTION "Retract a note." CONCEPT "note" DIRECTION "remove"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name of the note." EXAMPLES "Alpha"

IN "docs/notes.txt"
REMOVE
::: note block :::
note {{.note-name}} MARK:note-{{.note-name}}
::: note block :::
MARK "note-{{.note-name}}"
ASLONG FILE CONTAIN "MARK:note-{{.note-name}}"
`

// TestRemoveDirectionRemoveRefused — D36 dispatch law: a
// DIRECTION-remove command is a `bp scaffy run` target, never an object
// of `remove`. Usage-shaped refusal, before any receipt is probed.
func TestRemoveDirectionRemoveRefused(t *testing.T) {
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "remove-note.scaffy", removeNoteSrc)
	_, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: map[string]string{"NoteName": "Alpha"}, RepoRoot: root})
	var ve *VarError
	if !errors.As(err, &ve) || !strings.Contains(err.Error(), "D36") {
		t.Fatalf("direction-remove must refuse as usage citing D36, got %v", err)
	}
}

// TestInvertOpRemoveKindRefused — defense-in-depth behind the direction
// check: a REMOVE-verb receipt op records its pre-image WITHOUT
// position (engine-core reviewer handoff), so replay refuses it hard.
func TestInvertOpRemoveKindRefused(t *testing.T) {
	tr := newTree(t.TempDir())
	_, _, _, err := invertOp(tr, "r.json", 0, ReceiptOp{Kind: "remove", Path: "docs/x.txt", PreImage: []byte("x\n")})
	if err == nil || !strings.Contains(err.Error(), "D36") || !strings.Contains(err.Error(), "positionless") {
		t.Fatalf("remove-kind op must refuse inversion, got %v", err)
	}
}

// TestInvertOpDeleteKind — the DELETE inverse (restore the pre-image
// file), all three outcomes.
func TestInvertOpDeleteKind(t *testing.T) {
	op := ReceiptOp{Kind: "delete", Path: "docs/gone.txt", PreImage: []byte("old\n"), PreSHA256: sha256Hex([]byte("old\n"))}

	// (a) file absent → invert: restore.
	root := t.TempDir()
	tr := newTree(root)
	res, mutated, finding, err := invertOp(tr, "r.json", 0, op)
	if err != nil || finding != nil {
		t.Fatalf("restore: %v %+v", err, finding)
	}
	if res.Status != OpCreated || !mutated {
		t.Fatalf("restore result: %+v", res)
	}
	if b, ok, _ := tr.read("docs/gone.txt"); !ok || string(b) != "old\n" {
		t.Fatalf("overlay not restored: %q %v", b, ok)
	}

	// (b) file already back with matching bytes → clean skip.
	root = t.TempDir()
	writeTreeFile(t, root, "docs/gone.txt", "old\n")
	res, mutated, finding, err = invertOp(newTree(root), "r.json", 0, op)
	if err != nil || finding != nil || mutated || res.Status != OpSkipped {
		t.Fatalf("skip: %+v %+v %v", res, finding, err)
	}

	// (c) foreign bytes at the path → drift.
	root = t.TempDir()
	writeTreeFile(t, root, "docs/gone.txt", "something else\n")
	_, _, finding, err = invertOp(newTree(root), "r.json", 0, op)
	if err != nil || finding == nil || !strings.Contains(finding.String(), "SCAFFY-DRIFT") {
		t.Fatalf("drift: %+v %v", finding, err)
	}
}

const flakyAssertSrc = `COMMAND "add-flaky" DESCRIPTION "Mutates then fails its local assert." CONCEPT "flaky" DIRECTION "add"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name of the note." EXAMPLES "Alpha"

CREATE FILE IF ABSENT "docs/{{.note-name}}.txt"
::: flaky body :::
note {{.note-name}} MARK:flaky-{{.note-name}}
::: flaky body :::

ASSERT CMD "exit 1"
`

// TestRemoveAfterFailedAssertRun — engine-core reviewer handoff (3):
// receipts persist BEFORE asserts run, so a run whose closing assert
// FAILED still left a replayable receipt — and remove returns the tree
// byte-clean from that state.
func TestRemoveAfterFailedAssertRun(t *testing.T) {
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "add-flaky.scaffy", flakyAssertSrc)
	before := snapshotSansReceipts(t, root)
	vars := map[string]string{"NoteName": "Alpha"}

	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: vars, RepoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	if rep.Ok {
		t.Fatal("the fixture's assert must fail")
	}
	if rep.Receipt == "" {
		t.Fatal("a mutating run persists its receipt even when asserts fail")
	}
	if _, err := os.Stat(rep.Receipt); err != nil {
		t.Fatalf("receipt missing on disk: %v", err)
	}

	if _, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: vars, RepoRoot: root}); err != nil {
		t.Fatalf("Remove after failed-assert run: %v", err)
	}
	assertTreesEqual(t, "after remove", before, snapshotSansReceipts(t, root))
}

const nestCreateSrc = `COMMAND "add-nest" DESCRIPTION "Create a file in a fresh nested dir." CONCEPT "nest" DIRECTION "add"

VARIABLE 1 "NestName" TITLE "Nest" DESCRIPTION "Name of the nest." EXAMPLES "Alpha"

CREATE FILE IF ABSENT "nest/{{.nest-name}}/deep/a.txt"
::: nest file :::
nest {{.nest-name}}
::: nest file :::
`

var nestVars = map[string]string{"NestName": "Alpha"}

func dirExists(t *testing.T, root, rel string) bool {
	t.Helper()
	info, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel)))
	if errors.Is(err, fs.ErrNotExist) {
		return false
	}
	if err != nil {
		t.Fatalf("stat %s: %v", rel, err)
	}
	return info.IsDir()
}

// TestRemovePrunesEmptyCreatedDirs — the D35 created_dirs cleanup. A
// CREATE into a fresh nest/<name>/deep/ chain records those three dirs
// in the receipt; remove rmdirs them deepest-first once the file is
// gone, leaving no residue. A NON-empty created dir (a hand-added
// sibling still inside it) is left untouched — never force-removed.
func TestRemovePrunesEmptyCreatedDirs(t *testing.T) {
	t.Run("empty dirs pruned deepest-first", func(t *testing.T) {
		root := t.TempDir()
		cmdPath := writeCommand(t, root, "add-nest.scaffy", nestCreateSrc)

		rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: nestVars, RepoRoot: root})
		if err != nil {
			t.Fatal(err)
		}
		// The receipt records exactly the dirs the flush created.
		rec, err := ReadReceipt(rep.Receipt)
		if err != nil {
			t.Fatal(err)
		}
		wantDirs := []string{"nest", "nest/alpha", "nest/alpha/deep"}
		if strings.Join(rec.CreatedDirs, ",") != strings.Join(wantDirs, ",") {
			t.Fatalf("created_dirs = %v, want %v", rec.CreatedDirs, wantDirs)
		}
		if !dirExists(t, root, "nest/alpha/deep") {
			t.Fatal("apply must have created the nested dir")
		}

		if _, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: nestVars, RepoRoot: root}); err != nil {
			t.Fatalf("Remove: %v", err)
		}
		for _, d := range wantDirs {
			if dirExists(t, root, d) {
				t.Errorf("empty created dir %s must be rmdir'd after remove", d)
			}
		}
	})

	t.Run("non-empty created dir left intact", func(t *testing.T) {
		root := t.TempDir()
		cmdPath := writeCommand(t, root, "add-nest.scaffy", nestCreateSrc)

		if _, err := Run(RunOptions{CommandPath: cmdPath, Vars: nestVars, RepoRoot: root}); err != nil {
			t.Fatal(err)
		}
		// A hand-added sibling inside one of the created dirs.
		writeTreeFile(t, root, "nest/alpha/deep/manual.txt", "kept by hand\n")

		if _, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: nestVars, RepoRoot: root}); err != nil {
			t.Fatalf("Remove: %v", err)
		}
		// The created file is gone, but the non-empty dir chain survives
		// with the hand-added file intact.
		if _, err := os.Stat(filepath.Join(root, "nest/alpha/deep/a.txt")); !errors.Is(err, fs.ErrNotExist) {
			t.Error("the created file must be deleted by remove")
		}
		if !dirExists(t, root, "nest/alpha/deep") {
			t.Error("a non-empty created dir must be left in place")
		}
		if got := readTreeFile(t, root, "nest/alpha/deep/manual.txt"); got != "kept by hand\n" {
			t.Errorf("hand-added file clobbered: %q", got)
		}
	})
}

// TestRemoveBackCompatNoCreatedDirsField — a receipt written before the
// created_dirs field existed (the field simply absent from the JSON)
// removes cleanly: files retracted as always, no dirs pruned, no error.
func TestRemoveBackCompatNoCreatedDirsField(t *testing.T) {
	root := t.TempDir()
	cmdPath := writeCommand(t, root, "add-nest.scaffy", nestCreateSrc)

	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: nestVars, RepoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	// Rewrite the receipt as a pre-field one: created_dirs omitted.
	rec, err := ReadReceipt(rep.Receipt)
	if err != nil {
		t.Fatal(err)
	}
	rec.CreatedDirs = nil
	b, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(b, []byte("created_dirs")) {
		t.Fatal("test setup: created_dirs must be absent from a pre-field receipt")
	}
	if err := os.WriteFile(rep.Receipt, append(b, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: nestVars, RepoRoot: root}); err != nil {
		t.Fatalf("remove of a pre-field receipt must succeed: %v", err)
	}
	// File retracted (old behavior); the empty dir residue is left (old
	// behavior — nothing to prune without the field).
	if _, err := os.Stat(filepath.Join(root, "nest/alpha/deep/a.txt")); !errors.Is(err, fs.ErrNotExist) {
		t.Error("pre-field remove must still delete the created file")
	}
}
