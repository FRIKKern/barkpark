package scaffy

// discover_test.go pins the Discover engine on a SYNTHETIC git repository
// with scripted commit dates, so every figure is hand-checkable: the window
// derivation (pin-derived, never wall-clock), the min-support + existence
// filters, the uncapped partner counts and support histogram, the numstat
// shape split, the co-creation pair matcher (the mine.sh stage-2 semantics),
// the catalog cross-reference (SERVED / PARTIAL / UNSERVED), and determinism
// (two runs, identical reports). The live-repo parity against
// tooling/scaffy-mine/mine.sh is the verb's acceptance evidence, not a unit
// test — a golden test against a moving checkout could never be stable.

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// discoverGit runs one git command in dir with a scripted commit date and a
// fixed identity, failing the test on any error.
func discoverGit(t *testing.T, dir, date string, args ...string) {
	t.Helper()
	full := append([]string{"-C", dir,
		"-c", "user.name=discover-test", "-c", "user.email=discover@test",
		"-c", "commit.gpgsign=false"}, args...)
	cmd := exec.Command("git", full...)
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_DATE="+date+"T12:00:00+00:00",
		"GIT_COMMITTER_DATE="+date+"T12:00:00+00:00")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func discoverWrite(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func discoverAppend(t *testing.T, root, rel, line string) {
	t.Helper()
	p := filepath.Join(root, rel)
	f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(line + "\n"); err != nil {
		t.Fatal(err)
	}
}

// seedDiscoverRepo builds the scripted history. Commit dates: the out-of-
// window commit at 2024-06-01, the window at 2026-01-10..16 (until day
// 2026-01-16 → default since 2025-01-16). History, newest last:
//
//	old  2024-06-01  add lib/registry.ex + notes.md         (OUT of window)
//	c1   2026-01-10  registry append + add lib/a.txt        (PURE_ADD)
//	c2   2026-01-11  registry append + add lib/b.txt        (PURE_ADD)
//	c3   2026-01-12  registry line REPLACED + a.txt edit    (MIXED: +1/-1)
//	c4   2026-01-13  registry append + add lib/foo.ex + test/foo_test.exs
//	                                                        (PURE_ADD; strict pair)
//	c5   2026-01-14  registry append only                   (PURE_ADD)
//	cd1  2026-01-14  add lib/deleted.txt
//	cd2  2026-01-15  edit lib/deleted.txt + notes.md edit
//	cd3  2026-01-15  git rm lib/deleted.txt + notes.md edit (deleted at HEAD)
//	c6   2026-01-16  add lib/bar.ex + test/baz_test.exs     (loose pair only)
func seedDiscoverRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	discoverGit(t, root, "2024-06-01", "init", "-q", "-b", "main")

	discoverWrite(t, root, "lib/registry.ex", "defmodule Registry do\n  # zero\nend\n")
	discoverWrite(t, root, "notes.md", "notes\n")
	discoverGit(t, root, "2024-06-01", "add", ".")
	discoverGit(t, root, "2024-06-01", "commit", "-q", "-m", "old: seed registry (out of window)")

	discoverAppend(t, root, "lib/registry.ex", "# entry one")
	discoverWrite(t, root, "lib/a.txt", "a\n")
	discoverGit(t, root, "2026-01-10", "add", ".")
	discoverGit(t, root, "2026-01-10", "commit", "-q", "-m", "c1: entry one + a")

	discoverAppend(t, root, "lib/registry.ex", "# entry two")
	discoverWrite(t, root, "lib/b.txt", "b\n")
	discoverGit(t, root, "2026-01-11", "add", ".")
	discoverGit(t, root, "2026-01-11", "commit", "-q", "-m", "c2: entry two + b")

	discoverWrite(t, root, "lib/registry.ex", "defmodule Registry do\n  # ZERO\nend\n# entry one\n# entry two\n")
	discoverAppend(t, root, "lib/a.txt", "a2")
	discoverGit(t, root, "2026-01-12", "add", ".")
	discoverGit(t, root, "2026-01-12", "commit", "-q", "-m", "c3: replace a registry line + a2")

	discoverAppend(t, root, "lib/registry.ex", "# entry three")
	discoverWrite(t, root, "lib/foo.ex", "defmodule Foo do\nend\n")
	discoverWrite(t, root, "test/foo_test.exs", "defmodule FooTest do\nend\n")
	discoverGit(t, root, "2026-01-13", "add", ".")
	discoverGit(t, root, "2026-01-13", "commit", "-q", "-m", "c4: entry three + foo pair")

	discoverAppend(t, root, "lib/registry.ex", "# entry four")
	discoverGit(t, root, "2026-01-14", "add", ".")
	discoverGit(t, root, "2026-01-14", "commit", "-q", "-m", "c5: entry four")

	discoverWrite(t, root, "lib/deleted.txt", "gone soon\n")
	discoverGit(t, root, "2026-01-14", "add", ".")
	discoverGit(t, root, "2026-01-14", "commit", "-q", "-m", "cd1: add deleted")

	discoverAppend(t, root, "lib/deleted.txt", "more")
	discoverAppend(t, root, "notes.md", "n2")
	discoverGit(t, root, "2026-01-15", "add", ".")
	discoverGit(t, root, "2026-01-15", "commit", "-q", "-m", "cd2: edit deleted + notes")

	discoverGit(t, root, "2026-01-15", "rm", "-q", "lib/deleted.txt")
	discoverAppend(t, root, "notes.md", "n3")
	discoverGit(t, root, "2026-01-15", "add", ".")
	discoverGit(t, root, "2026-01-15", "commit", "-q", "-m", "cd3: rm deleted + notes")

	discoverWrite(t, root, "lib/bar.ex", "defmodule Bar do\nend\n")
	discoverWrite(t, root, "test/baz_test.exs", "defmodule BazTest do\nend\n")
	discoverGit(t, root, "2026-01-16", "add", ".")
	discoverGit(t, root, "2026-01-16", "commit", "-q", "-m", "c6: bar + baz (loose only)")

	// The catalog: one serving command (IN → lib/registry.ex), one ensure-*
	// command (IN → notes.md → PARTIAL), one pair-creating command (the
	// .ex/_test.exs shape). Parse tolerates lint findings — only the header
	// CONCEPT and the op target paths matter to the cross-reference.
	discoverWrite(t, root, "scaffy/commands/add-entry.scaffy",
		"COMMAND \"Add an entry\" DESCRIPTION \"synthetic\" DIRECTION \"add\" CONCEPT \"entry\" VARIABLES\n\n"+
			"IN \"lib/registry.ex\"\n"+
			"INSERT AFTER FIRST\n"+
			"::: anchor :::\n"+
			"# entry one\n"+
			"::: anchor :::\n"+
			"WITH\n"+
			"::: payload :::\n"+
			"# entry next\n"+
			"::: payload :::\n")
	discoverWrite(t, root, "scaffy/commands/ensure-notes.scaffy",
		"COMMAND \"Ensure notes zones\" DESCRIPTION \"synthetic\" DIRECTION \"add\" CONCEPT \"ensure-notes\" VARIABLES\n\n"+
			"IN \"notes.md\"\n"+
			"INSERT AFTER FIRST\n"+
			"::: anchor :::\n"+
			"notes\n"+
			"::: anchor :::\n"+
			"WITH\n"+
			"::: payload :::\n"+
			"zone\n"+
			"::: payload :::\n")
	discoverWrite(t, root, "scaffy/commands/add-pair.scaffy",
		"COMMAND \"Add a pair\" DESCRIPTION \"synthetic\" DIRECTION \"add\" CONCEPT \"pair\" VARIABLES\n\n"+
			"CREATE FILE IF ABSENT \"lib/{{.name}}.ex\"\n"+
			"::: src :::\n"+
			"defmodule X do\nend\n"+
			"::: src :::\n\n"+
			"CREATE FILE IF ABSENT \"test/{{.name}}_test.exs\"\n"+
			"::: test :::\n"+
			"defmodule XTest do\nend\n"+
			"::: test :::\n")
	// A templated-IN command: injects into lib/{{.name}}.txt — a SHAPE-level
	// claim on lib/a.txt (partial), never a literal serve.
	discoverWrite(t, root, "scaffy/commands/add-txt-note.scaffy",
		"COMMAND \"Add a txt note\" DESCRIPTION \"synthetic\" DIRECTION \"add\" CONCEPT \"txt-note\" VARIABLES\n\n"+
			"IN \"lib/{{.name}}.txt\"\n"+
			"INSERT AFTER FIRST\n"+
			"::: anchor :::\n"+
			"a\n"+
			"::: anchor :::\n"+
			"WITH\n"+
			"::: payload :::\n"+
			"note\n"+
			"::: payload :::\n")
	discoverGit(t, root, "2026-01-16", "add", "scaffy")
	discoverGit(t, root, "2026-01-16", "commit", "-q", "-m", "catalog: four synthetic commands")

	return root
}

func discoverCandidate(t *testing.T, rep *DiscoverReport, path string) AccretionCandidate {
	t.Helper()
	for _, c := range rep.Accretion {
		if c.Path == path {
			return c
		}
	}
	t.Fatalf("candidate %s missing from report: %+v", path, rep.Accretion)
	return AccretionCandidate{}
}

func TestDiscoverSyntheticRepo(t *testing.T) {
	root := seedDiscoverRepo(t)
	rep, err := Discover(DiscoverOptions{Dir: root, MinSupport: 2, Top: 10})
	if err != nil {
		t.Fatal(err)
	}

	// Window: pin-derived from the until commit's day, never wall-clock.
	if rep.Window.UntilDay != "2026-01-16" {
		t.Errorf("until day = %s, want 2026-01-16", rep.Window.UntilDay)
	}
	if rep.Window.Since != "2025-01-16" {
		t.Errorf("since = %s, want 2025-01-16 (12m before the until day)", rep.Window.Since)
	}
	if !rep.Window.NoMerges {
		t.Error("window must record --no-merges")
	}
	// 10 in-window commits (c1..c6, cd1..cd3, catalog); the 2024 seed is out.
	if rep.Window.Commits != 10 {
		t.Errorf("window commits = %d, want 10", rep.Window.Commits)
	}

	// Registry: 5 in-window commits, partners a/b/foo.ex/foo_test.exs with
	// a.txt at support 2; shapes 4 PURE_ADD + 1 MIXED (the +1/-1 replace).
	reg := discoverCandidate(t, rep, "lib/registry.ex")
	if reg.Rank != 1 || reg.Commits != 5 {
		t.Errorf("registry rank/commits = %d/%d, want 1/5", reg.Rank, reg.Commits)
	}
	if reg.Partners != 4 {
		t.Errorf("registry partners = %d, want 4 (a, b, foo.ex, foo_test.exs)", reg.Partners)
	}
	if reg.Support != (SupportHistogram{Ge2: 1}) {
		t.Errorf("registry support = %+v, want exactly one partner at ≥2 (a.txt)", reg.Support)
	}
	if reg.Shape != (ShapeSplit{PureAdd: 4, Mixed: 1}) {
		t.Errorf("registry shape = %+v, want 4 pure_add + 1 mixed", reg.Shape)
	}
	if reg.Coverage != "served" || !reflect.DeepEqual(reg.CoveredBy, []string{"entry"}) {
		t.Errorf("registry coverage = %s %v, want served [entry]", reg.Coverage, reg.CoveredBy)
	}

	// notes.md: 2 in-window commits, targeted only by ensure-notes → PARTIAL.
	notes := discoverCandidate(t, rep, "notes.md")
	if notes.Commits != 2 || notes.Coverage != "partial" ||
		!reflect.DeepEqual(notes.CoveredBy, []string{"ensure-notes (ensure)"}) {
		t.Errorf("notes = %+v, want 2 commits, partial via ensure-notes", notes)
	}

	// a.txt: 2 commits; only the templated-IN command's lib/*.txt shape claim
	// touches it (add-pair's templated CREATE lib/{{.name}}.ex claims nothing
	// per-file) → PARTIAL at shape level.
	a := discoverCandidate(t, rep, "lib/a.txt")
	if a.Commits != 2 || a.Coverage != "partial" ||
		!reflect.DeepEqual(a.CoveredBy, []string{"txt-note (shape)"}) {
		t.Errorf("a.txt = %+v, want 2 commits, partial via txt-note (shape)", a)
	}

	// b.txt: 1 commit — below min-support, and that is the point: the shape
	// glob alone must never invent candidates.
	for _, c := range rep.Accretion {
		if c.Path == "lib/b.txt" {
			t.Errorf("b.txt (1 commit) must be filtered by min-support 2")
		}
	}

	// foo.ex IS matched by add-pair's templated lib/{{.name}}.ex — but at 1
	// commit it is below min-support, so it must not be a candidate at all.
	for _, c := range rep.Accretion {
		if c.Path == "lib/foo.ex" {
			t.Errorf("foo.ex (1 commit) must be filtered by min-support 2")
		}
		if c.Path == "lib/deleted.txt" {
			t.Errorf("deleted.txt does not exist at HEAD — the existence filter must drop it")
		}
	}

	// Co-creation: the .ex/_test.exs rule sees ONE strict commit (c4: foo
	// basename-paired) and TWO loose (c4 + c6's bar/baz mismatch), hot dir
	// "lib", covered by the pair-creating command.
	var ex CoCreationRule
	for _, r := range rep.CoCreation {
		if r.SrcSuffix == ".ex" {
			ex = r
		}
	}
	if ex.Strict != 1 || ex.Loose != 2 {
		t.Errorf(".ex rule strict/loose = %d/%d, want 1/2", ex.Strict, ex.Loose)
	}
	if !reflect.DeepEqual(ex.TopDirs, []DirCount{{Dir: "lib", Count: 1}}) {
		t.Errorf(".ex rule top dirs = %+v, want [lib:1]", ex.TopDirs)
	}
	if !reflect.DeepEqual(ex.CoveredBy, []string{"pair"}) {
		t.Errorf(".ex rule covered_by = %v, want [pair]", ex.CoveredBy)
	}

	if rep.CatalogCommands != 4 {
		t.Errorf("catalog commands = %d, want 4", rep.CatalogCommands)
	}
	if rep.Note != DiscoverNote {
		t.Errorf("report must carry the frequency-not-verdict note")
	}
}

func TestDiscoverDeterministic(t *testing.T) {
	root := seedDiscoverRepo(t)
	run := func() *DiscoverReport {
		rep, err := Discover(DiscoverOptions{Dir: root, MinSupport: 2, Top: 10})
		if err != nil {
			t.Fatal(err)
		}
		rep.DurationMS = 0 // the only wall-clock-dependent field
		return rep
	}
	if a, b := run(), run(); !reflect.DeepEqual(a, b) {
		t.Errorf("two runs differ:\n%+v\n%+v", a, b)
	}
}

func TestDiscoverSinceForms(t *testing.T) {
	root := seedDiscoverRepo(t)

	// Duration form: 3d before the until day (2026-01-16) → 2026-01-13,
	// which drops c1..c3 — the registry falls to 2 commits (c4 + c5).
	rep, err := Discover(DiscoverOptions{Dir: root, Since: "3d", MinSupport: 2, Top: 10})
	if err != nil {
		t.Fatal(err)
	}
	if rep.Window.Since != "2026-01-13" {
		t.Errorf("since 3d = %s, want 2026-01-13", rep.Window.Since)
	}
	if reg := discoverCandidate(t, rep, "lib/registry.ex"); reg.Commits != 2 {
		t.Errorf("registry commits in 3d window = %d, want 2", reg.Commits)
	}

	// Explicit date form passes through verbatim.
	rep, err = Discover(DiscoverOptions{Dir: root, Since: "2026-01-12", MinSupport: 2, Top: 10})
	if err != nil {
		t.Fatal(err)
	}
	if rep.Window.Since != "2026-01-12" {
		t.Errorf("explicit since = %s, want 2026-01-12", rep.Window.Since)
	}

	// Malformed values are ErrSinceFormat (the CLI's usage-error hook).
	for _, bad := range []string{"banana", "12", "m12", "2026-13-40", "1h"} {
		if _, err := Discover(DiscoverOptions{Dir: root, Since: bad}); !errors.Is(err, ErrSinceFormat) {
			t.Errorf("since %q: err = %v, want ErrSinceFormat", bad, err)
		}
		if err := CheckSinceFormat(bad); !errors.Is(err, ErrSinceFormat) {
			t.Errorf("CheckSinceFormat(%q) = %v, want ErrSinceFormat", bad, err)
		}
	}
	for _, good := range []string{"", "12m", "90d", "2w", "1y", "2025-07-17"} {
		if err := CheckSinceFormat(good); err != nil {
			t.Errorf("CheckSinceFormat(%q) = %v, want nil", good, err)
		}
	}
}

func TestDiscoverUntilPinsTheWindow(t *testing.T) {
	root := seedDiscoverRepo(t)
	// Pin to the c5 commit (5 commits before HEAD): cd1..c6 + catalog drop
	// out of reachability, so the co-creation loose count falls to 1 (c4
	// only) and the catalog still cross-references from the WORKTREE corpus.
	rep, err := Discover(DiscoverOptions{Dir: root, Until: "HEAD~5", MinSupport: 2, Top: 10})
	if err != nil {
		t.Fatal(err)
	}
	if rep.Window.UntilDay != "2026-01-14" {
		t.Errorf("pinned until day = %s, want 2026-01-14 (c5)", rep.Window.UntilDay)
	}
	var ex CoCreationRule
	for _, r := range rep.CoCreation {
		if r.SrcSuffix == ".ex" {
			ex = r
		}
	}
	if ex.Strict != 1 || ex.Loose != 1 {
		t.Errorf("pinned .ex rule strict/loose = %d/%d, want 1/1", ex.Strict, ex.Loose)
	}
	if _, err := Discover(DiscoverOptions{Dir: root, Until: "no-such-rev"}); err == nil {
		t.Error("an unknown until rev must error")
	}
}

// seedRecencyRepo builds a history that separates OLD churn from a RECENT
// decomposition, so the recent column and the DECOMPOSED flag both have
// hand-checkable answers. History, newest last (until day 2026-06-15 →
// recent sub-window start 2026-03-17, 90d before):
//
//	2026-01-05  create big.ex (20 lines over 3 commits) + p1.txt  (OLD)
//	2026-01-06  append 5 lines to big.ex                          (OLD)
//	2026-01-07  append 5 lines to big.ex                          (OLD)
//	2026-05-01  create calm.ex (3 lines) + p2.txt                 (RECENT)
//	2026-05-05  append 3 lines to calm.ex                         (RECENT)
//	2026-05-08  append 3 lines to calm.ex                         (RECENT)
//	2026-06-15  rewrite big.ex to 2 lines (+2/-20 decomposition)  (RECENT, HEAD)
func seedRecencyRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	discoverGit(t, root, "2026-01-05", "init", "-q", "-b", "main")

	// big.ex: 10 lines at create, +5, +5 → 20 lines, all in OLD (Jan) commits.
	big := ""
	for i := 0; i < 10; i++ {
		big += "old line\n"
	}
	discoverWrite(t, root, "lib/big.ex", big)
	discoverWrite(t, root, "lib/p1.txt", "p1\n")
	discoverGit(t, root, "2026-01-05", "add", ".")
	discoverGit(t, root, "2026-01-05", "commit", "-q", "-m", "big: create (10 lines)")
	for _, d := range []string{"2026-01-06", "2026-01-07"} {
		for i := 0; i < 5; i++ {
			discoverAppend(t, root, "lib/big.ex", "more")
		}
		discoverGit(t, root, d, "add", ".")
		discoverGit(t, root, d, "commit", "-q", "-m", "big: +5 lines")
	}

	// calm.ex: 3 lines + two 3-line appends, all in the RECENT (May) window,
	// pure additions → recent == total commits, never decomposed.
	discoverWrite(t, root, "lib/calm.ex", "a\nb\nc\n")
	discoverWrite(t, root, "lib/p2.txt", "p2\n")
	discoverGit(t, root, "2026-05-01", "add", ".")
	discoverGit(t, root, "2026-05-01", "commit", "-q", "-m", "calm: create (3 lines)")
	for _, d := range []string{"2026-05-05", "2026-05-08"} {
		for i := 0; i < 3; i++ {
			discoverAppend(t, root, "lib/calm.ex", "x")
		}
		discoverGit(t, root, d, "add", ".")
		discoverGit(t, root, d, "commit", "-q", "-m", "calm: +3 lines")
	}

	// The decomposition: big.ex gutted from 20 lines to 2 in ONE recent commit.
	discoverWrite(t, root, "lib/big.ex", "brand new\ndelegation head\n")
	discoverGit(t, root, "2026-06-15", "add", ".")
	discoverGit(t, root, "2026-06-15", "commit", "-q", "-m", "big: decompose to 2-line head")

	return root
}

func TestDiscoverRecencyAndDecomposition(t *testing.T) {
	root := seedRecencyRepo(t)
	rep, err := Discover(DiscoverOptions{Dir: root, MinSupport: 3, Top: 10})
	if err != nil {
		t.Fatal(err)
	}

	// Recent sub-window: 90 days before the until commit's day, pin-derived.
	if rep.Window.RecentDays != RecentWindowDays {
		t.Errorf("recent days = %d, want %d", rep.Window.RecentDays, RecentWindowDays)
	}
	if rep.Window.RecentSince != "2026-03-17" {
		t.Errorf("recent since = %s, want 2026-03-17 (90d before 2026-06-15)", rep.Window.RecentSince)
	}

	// big.ex: 4 commits total, but only the June decomposition is recent — the
	// ranked churn is OLD. And it is DECOMPOSED: one commit deleted 20 lines,
	// far more than half its current 2-line body.
	big := discoverCandidate(t, rep, "lib/big.ex")
	if big.Commits != 4 || big.RecentCommits != 1 {
		t.Errorf("big.ex commits/recent = %d/%d, want 4/1 (churn is pre-decomposition)", big.Commits, big.RecentCommits)
	}
	if !big.Decomp.Detected || big.Decomp.MaxDelete != 20 || big.Decomp.CurrentLines != 2 {
		t.Errorf("big.ex decomposition = %+v, want detected max_delete=20 current_lines=2", big.Decomp)
	}

	// calm.ex: pure recent additions — recent == total, never decomposed. This
	// is the control that proves the flag does not fire on ordinary accretion.
	calm := discoverCandidate(t, rep, "lib/calm.ex")
	if calm.Commits != 3 || calm.RecentCommits != 3 {
		t.Errorf("calm.ex commits/recent = %d/%d, want 3/3", calm.Commits, calm.RecentCommits)
	}
	if calm.Decomp.Detected {
		t.Errorf("calm.ex must not be flagged decomposed: %+v", calm.Decomp)
	}
	if calm.Decomp.CurrentLines != 9 {
		t.Errorf("calm.ex current lines = %d, want 9", calm.Decomp.CurrentLines)
	}
}

func TestDiscoverNotARepo(t *testing.T) {
	if _, err := Discover(DiscoverOptions{Dir: t.TempDir()}); err == nil ||
		!strings.Contains(err.Error(), "not a git repository") {
		t.Errorf("err = %v, want a not-a-git-repository error", err)
	}
}
