package cli

import (
	"errors"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ─── THE FALSE STALE-INSTALL VERDICT (task-3ca5db4fec0bda68) ────────────────
//
// The drift guard asks one question — "does the manifest's prose for this
// command mention the flag?" — and answered YES for prose that merely
// CROSS-REFERENCES a sibling command's flag or QUOTES git. Measured against the
// live guerrilla manifest on 2026-09-13 with a binary built from main, four
// commands answered `cli_manifest_drift` ("this bp is BEHIND the server
// manifest … refresh it") to an operator whose binary was current:
//
//	bp task landed     --merge-gated   ← "unlike stamp's --merge-gated"
//	bp task stamp      --set           ← "the same idea as close's --set observed_rev=<rev>"
//	bp task stage      --git-dir / --work-tree / --is-ancestor / --count
//	bp bulldocs publish --if-rev       ← "(bp bulldocs patch --if-rev)"
//
// A refusal that names a culprit is exactly where the operator stops looking,
// and every one of those named a culprit that was not the cause and prescribed
// a remedy that cannot work. These fixtures are cut from the REAL manifest
// prose, verbatim, so the detector measures the shipped shape and not an
// invented one.

// crossRefLandedCmd is `task landed` as the server ships it: its summary
// mentions `--merge-gated` only to contrast with `task stamp`, which DECLARES
// that flag. This binary can therefore parse --merge-gated; it is not behind.
func crossRefLandedCmd() manifest.Command {
	return manifest.Command{
		ID: "task.landed", Noun: "task", Verb: "landed",
		Summary: "Record that the PR landed. There is no override flag: unlike stamp's " +
			"--merge-gated, here the predicate gates a PERMIT rather than a refusal.",
		Flags: []manifest.Flag{{Name: "files", Type: "string", Summary: "Changed paths."}},
	}
}

// foreignToolStageCmd is `task stage` as the server ships it: its --rerun
// summary quotes GIT command lines, so `--git-dir`, `--work-tree`,
// `--is-ancestor` and `--count` appear in bp prose while belonging to git.
func foreignToolStageCmd() manifest.Command {
	return manifest.Command{
		ID: "task.stage", Noun: "task", Verb: "stage",
		Summary: "Stage an instruction on a task.",
		Flags: []manifest.Flag{
			{Name: "rerun", Type: "string", Summary: "LEGAL SPELLINGS — `git rev-list --count origin/main..<sha> | grep -qx 0`. " +
				"REFUSED SPELLINGS (422 unfalsifiable_rerun, NOTHING written): `git -C` in any spelling " +
				"(also --git-dir/--work-tree — it retargets the repo the check runs against), and " +
				"`git merge-base --is-ancestor` (refused by truth-grip's own screen)."},
		},
	}
}

// crossRefManifest is the loaded manifest both fixtures live in: `task stamp`
// really does declare --merge-gated, which is the whole point — the binary
// parses that flag one command over.
func crossRefManifest() *manifest.Manifest {
	stamp := driftStampCmd()
	stamp.Flags = append(stamp.Flags,
		manifest.Flag{Name: "merge-gated", Type: "string", Summary: "TAKES A REASON."},
		manifest.Flag{Name: "met", Type: "bool", Summary: "Mark it met."})
	return &manifest.Manifest{Commands: []manifest.Command{
		stamp, crossRefLandedCmd(), foreignToolStageCmd(),
	}}
}

// assertOrdinaryUnknownFlag is the shared assertion: an ordinary, correct
// unknown-flag refusal that NAMES the flag and is not the drift verdict.
func assertOrdinaryUnknownFlag(t *testing.T, err error, spelled, noun, verb string) {
	t.Helper()
	if err == nil {
		t.Fatalf("splitArgs accepted %s on %s %s", spelled, noun, verb)
	}
	var drift *flagDriftError
	if errors.As(err, &drift) {
		t.Fatalf("%s on %s %s answered a FALSE stale-install verdict: %q", spelled, noun, verb, err)
	}
	want := "unknown flag " + spelled + " for " + noun + " " + verb
	if err.Error() != want {
		t.Fatalf("refusal = %q, want %q", err.Error(), want)
	}
	if !strings.Contains(err.Error(), spelled) {
		t.Fatalf("refusal does not name the flag: %q", err)
	}
}

// TestCrossReferencedFlagIsNotDrift is the DETECTOR for criterion 1. It fails
// if flagParsableSomewhere stops disqualifying a flag another command declares.
func TestCrossReferencedFlagIsNotDrift(t *testing.T) {
	m := crossRefManifest()

	_, _, err := splitArgsWithManifest(m, crossRefLandedCmd(), []string{"task-1", "--merge-gated", "why"})
	assertOrdinaryUnknownFlag(t, err, "--merge-gated", "task", "landed")

	// The sibling direction: --set is a `task close` flag quoted in stamp prose.
	stamp := driftStampCmd()
	stamp.Flags = append(stamp.Flags, manifest.Flag{
		Name: "observed-rev", Type: "string",
		Summary: "the rev is the read-before-write proof instead, the same idea as close's --set observed_rev=<rev>.",
	})
	closeCmd := manifest.Command{ID: "task.close", Noun: "task", Verb: "close",
		Flags: []manifest.Flag{{Name: "set", Type: "string", Summary: "Extra field."}}}
	m2 := &manifest.Manifest{Commands: []manifest.Command{stamp, closeCmd}}

	_, _, err = splitArgsWithManifest(m2, stamp, []string{"task-1", "--set", "a=b"})
	assertOrdinaryUnknownFlag(t, err, "--set", "task", "stamp")
}

// TestForeignToolProseIsNotDrift is the DETECTOR for criterion 2. It fails if
// quotesForeignProgram stops disqualifying a field that quotes git.
func TestForeignToolProseIsNotDrift(t *testing.T) {
	m := crossRefManifest()
	stage := foreignToolStageCmd()

	// --git-dir and --work-tree are named in bp prose but exist only in git,
	// so NO command declares them: only the foreign-tool disqualifier can save
	// them. --is-ancestor is the same, inside a backticked git invocation.
	for _, spelled := range []string{"--git-dir", "--work-tree", "--is-ancestor"} {
		_, _, err := splitArgsWithManifest(m, stage, []string{"task-1", spelled, "v"})
		assertOrdinaryUnknownFlag(t, err, spelled, "task", "stage")
	}
}

// TestDriftSurvivesBothDisqualifiers is the CONTROL that keeps the guard from
// becoming a uniform "never drift" verdict: the ONE true drift in the live
// manifest — a client-side flag no command declares, in prose that quotes no
// foreign program — must still answer cli_manifest_drift.
func TestDriftSurvivesBothDisqualifiers(t *testing.T) {
	m := crossRefManifest()
	// The parser fixture is the OLD stamp: it does not declare
	// --criterion-text-file (nothing ever can — it is client-side).
	_, _, err := splitArgsWithManifest(m, driftStampCmd(),
		[]string{"task-1", "--criterion-text-file", "crit.txt"})
	var drift *flagDriftError
	if !errors.As(err, &drift) {
		t.Fatalf("the one TRUE drift stopped being drift: %T %q", err, err)
	}
	if !strings.Contains(err.Error(), "--criterion-text-file") {
		t.Errorf("drift refusal does not name the flag: %q", err)
	}
}

// TestQuotesForeignProgramSpanShapes pins the span reader. The `-` stdin
// spelling that appears in the TRUE drift's own prose must NOT read as a
// foreign program, or the guard would disqualify itself.
func TestQuotesForeignProgramSpanShapes(t *testing.T) {
	cases := []struct {
		text string
		want bool
	}{
		{"--criterion-text-file <path> (or `-` for stdin) reads the bytes", false},
		{"no spans at all --met", false},
		{"run `bp task get <id>` first", false},
		{"LEGAL SPELLINGS — `git rev-list --count origin/main..<sha>`", true},
		{"`git -C` in any spelling (also --git-dir/--work-tree)", true},
		{"an unterminated `span", false},
		{"`` empty span", false},
	}
	for _, c := range cases {
		if got := quotesForeignProgram(c.text); got != c.want {
			t.Errorf("quotesForeignProgram(%q) = %v, want %v", c.text, got, c.want)
		}
	}
}

// TestDriftPredicateCensusOverManifestShape is the DETECTOR for criterion 3: a
// PREDICATE, not a skip list. It walks every command in a manifest, asks the
// drift predicate about every flag its prose mentions, and asserts that the
// only survivors are flags NO command declares — so a future manifest edge
// that cross-references a sibling's declared flag cannot silently re-open the
// false verdict. The seeded fixture below is exactly such an edge.
func TestDriftPredicateCensusOverManifestShape(t *testing.T) {
	m := crossRefManifest()
	declared := map[string]bool{}
	for _, c := range m.Commands {
		for _, f := range c.Flags {
			declared[f.Name] = true
		}
	}

	mentions := func(c manifest.Command) []string {
		texts := []string{c.Summary}
		for _, f := range c.Flags {
			texts = append(texts, f.Summary)
		}
		var out []string
		for _, t := range texts {
			for i := 0; i+2 < len(t); i++ {
				if t[i] != '-' || t[i+1] != '-' {
					continue
				}
				j := i + 2
				for j < len(t) && isFlagNameByte(t[j]) {
					j++
				}
				if j > i+2 {
					out = append(out, t[i+2:j])
				}
				i = j
			}
		}
		return out
	}

	surviving := 0
	for _, c := range m.Commands {
		own := map[string]bool{}
		for _, f := range c.Flags {
			own[f.Name] = true
		}
		for _, name := range mentions(c) {
			if own[name] {
				continue
			}
			if !manifestAdvertisesFlag(c, name) || flagParsableSomewhere(m, name) {
				continue
			}
			surviving++
			if declared[name] {
				t.Errorf("%s %s: --%s still reads as a stale-install verdict, but %q is declared by a command in this manifest",
					c.Noun, c.Verb, name, name)
			}
		}
	}
	if surviving == 0 {
		t.Fatalf("census measured nothing: no mentioned flag survived the drift predicate, so the assertion above is vacuous")
	}
}
