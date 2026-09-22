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
// the foreign-tool scoping stops disqualifying the clause that quotes git.
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

// ─── THE FIELD-WIDE SKIP THAT MADE THE GUARD GO QUIET ───────────────────────
//
// realTasksProse is cut VERBATIM from api/lib/barkpark/plugins/tasks.ex, the
// manifest prose this guard actually reads. Four of the five flag-mentioning
// strings in that file that carry a backticked bare word are here; the fifth
// (`landed`/`renew`) mentions only flags its own command declares.
//
// This is the BOTH-DIRECTIONS control on REAL DATA. The tempting fix for a
// guard that over-disqualifies is to narrow its predicate until it never
// disqualifies anything, which reads as a clean pass. So each case asserts
// BOTH that the field became visible again AND — for the one field that really
// does invoke git — that it stays disqualified, and every case asserts that
// the OLD field-wide rule would have answered differently (fieldWideSkip), so
// none of it can go vacuous.
var realTasksProse = struct{ events, files, stage, rerun string }{
	events: "Replay task events since a cursor — a keyset stream over mutation_events, id-ASC. Pass --since <id> (the last event id you saw); the response carries the next `cursor` + `has_more`. The one poll feed every surface reads; omit --since to replay from the start.",
	files:  "ONE changed path per occurrence — `--files api/lib/x.ex --files api/test/x_test.exs` — stored at content.landed.files as a LIST, which is the half a landing could not carry until this flag existed: the sha said a merge happened and only the --note PROSE said what it touched, and prose is not queryable. Rides the request BODY as a JSON array (never the query string), so one path and forty arrive in the same shape and a 40-path manifest never reaches the request-line wall. Up to 40 paths are kept verbatim; past that the server stores the count plus the sorted top-level dirs under `file_digests` instead. It is ALSO the overlap guard's only input: with files present the server refuses (409 landing_files_outside_row) a landing whose every path misses every path the row's own text names — a merge sealing work that was not this row's work. Omit it and that check is unmeasurable, and the response says so rather than letting silence read as a pass.",
	stage:  "Stage a task between the thought/backlog states — the sanctioned lifecycle-transition verb. `state` is the target: considering | researching | open, OR the row's OWN current state. Enforces the charter-D7 transition-legality table for those targets: considering⇄researching; considering|researching→open; open→considering; the terminal/blocked reopen edges done→open, cancelled→open, blocked→open, in_progress→open; same→same. THE TERMINAL SAME-STATE ADJUDICATION EDGE (PDS wave 25): a same-state no-op is accepted on EVERY status, not just the stageable ones — done→done, blocked→blocked, in_progress→in_progress — so a FINISHED row can record its disposition/reason/reopen-trigger IN PLACE instead of being resurrected to `open` first (which would leave it saying open while carrying claim.closed_by, and put it back in `bp task ready`). It widens ADJUDICATION, not MOVEMENT: the from-state is read from the locked row, never from your input, so state==current is satisfiable only by a row already in that state, and the write set never includes content.claim — a done→done stage leaves lifecycle_status=done and close attribution byte-identical. (The false-done reopen recipe DEPENDS on reopening a done task — it legitimately re-enters the ready backlog via stage, KEEPING its claim; no epoch machinery.) Writes content.engagement {object,holder,ts,lapse_ttl_seconds,lapses_at} — an EPHEMERAL lease the TtlSweeper deletes wholesale after ~900s — on →considering/researching and clears it on →open; a `note` does NOT ride that lease, it lands on the DURABLE content.disposition_reason (no sweeper owns it) on EVERY target including →open; BREAKING (2026-09-06): a --note that would DISPLACE a different non-blank disposition_reason is now REFUSED with 409 note_would_supersede — the refusal quotes the note it would have destroyed and names --supersede, the flag that allows the replacement on purpose; emits a task.staged event carrying staged.note_key. PDS wave 24: this verb also owns the ADJUDICATION TRIPLE — --disposition (open|parked|closed, normalised here because one writer means one normaliser), --note/content.disposition_reason and --reopen-trigger are written in that same CAS update or not at all, and a --disposition parked with no trigger on the stage and none on the row is refused BEFORE anything is written. Raw /v1/data/mutate changes of content.disposition on a type:task are refused and name this verb. TWO DURABLE SLOTS, TWO LIFETIMES (task-bd7476eecdede252): a VERDICT is a dated measurement a later measurement should replace (--note → content.disposition_reason, override --supersede), while an OPERATING INSTRUCTION is standing guidance nothing newer supersedes (--instruction → content.operating_instruction, override --supersede-instruction). They are SEPARATELY ADDRESSABLE keys with SEPARATE guards, so writing a verdict with --supersede leaves an instruction byte-identical and writing an instruction with --supersede-instruction leaves a verdict byte-identical — before this there was one slot, and a lane ruling on a row that carried pinned guidance could only destroy the guidance or record nothing. Existing rows are NOT reclassified and there is no migration: a legacy content.disposition_reason stays exactly where it is and content.operating_instruction is simply absent. done is reached ONLY through `bp task close`, in_progress ONLY through `bp task claim`, kills go through close (→ cancelled); an illegal transition (e.g. open → done) is a 422 naming from,to. NO epoch fence — thought is not contended work.",
	rerun:  "PDS wave 28 — THE FOURTH DURABLE KEY: one command an auditor can run to try to prove this reason WRONG. Written to the DURABLE content.disposition_rerun in the SAME CAS update as the rest of the adjudication; the raw /v1/data/mutate door refuses it and names this flag, exactly as it does for content.disposition. OPTIONAL, and that is deliberate: a reason may honestly refuse to be checkable (a licence, a runtime-only probe, a judgment call) and omitting --rerun is a PASS, demoted never rejected. LEGAL SPELLINGS — `git rev-list --count origin/main..<sha> | grep -qx 0`, `git cat-file -e origin/main:<path>`, `git grep -n <token> origin/main -- <path>`; each reports the probe's OWN failure as a non-zero exit. REFUSED SPELLINGS (422 unfalsifiable_rerun, NOTHING written): `git -C` in any spelling (also --git-dir/--work-tree — it retargets the repo the check runs against), a `test`/`[` filesystem predicate (asserts about the local checkout, not origin/main), `$( … )` or backtick command substitution (the exit code becomes the outer command's, swallowing the probe's failure), `git merge-base --is-ancestor` (refused by truth-grip's own screen), and a PIPE-MASKED tail whose last stage merely formats (head/tail/wc/cat/jq/…) — `git show origin/main:<deleted> | head -1` exits 0 while the bare `git show` exits 128. Blank counts as absent. Distinctness is NOT applied to this field (PDS-D391b/PDS-D336(a)): a SHARED rerun over distinct rows is the honest shape.",
}

// fieldWideSkip is the SHIPPED rule this change replaces: ANY backticked bare
// word disqualifies the WHOLE field. It lives here only as the RED-before
// witness — a case where it disagrees with the new scoping is a case that
// measures the change.
func fieldWideSkip(text string) bool {
	for {
		i := strings.IndexByte(text, '`')
		if i < 0 {
			return false
		}
		rest := text[i+1:]
		j := strings.IndexByte(rest, '`')
		if j < 0 {
			return false
		}
		if spanInvokesForeignProgram(rest[:j]) {
			return true
		}
		text = rest[j+1:]
	}
}

// TestForeignScopingOverRealTasksProse is the DETECTOR for the field-wide skip.
// It fails if the disqualifier goes back to swallowing a whole field, and it
// fails just as loudly if it stops disqualifying git prose at all.
func TestForeignScopingOverRealTasksProse(t *testing.T) {
	cases := []struct {
		name    string
		prose   string
		visible []string // must advertise: real bp flags the guard must see
		hidden  []string // must NOT advertise: flags that belong to git
	}{
		{
			name:    "task events summary (disqualified by the noun `cursor`)",
			prose:   realTasksProse.events,
			visible: []string{"since"},
		},
		{
			name:    "--files summary (disqualified by the noun `file_digests`)",
			prose:   realTasksProse.files,
			visible: []string{"files", "note"},
		},
		{
			name:    "task stage summary (disqualified by the noun `state`)",
			prose:   realTasksProse.stage,
			visible: []string{"note", "supersede", "disposition"},
		},
		{
			name:    "--rerun summary (the ONE real git invocation)",
			prose:   realTasksProse.rerun,
			visible: []string{"rerun"},
			hidden:  []string{"git-dir", "work-tree", "count", "is-ancestor"},
		},
	}

	for _, c := range cases {
		// The precondition: the shipped rule really did skip this whole field.
		// Without this the case could pass on prose the old rule never touched.
		if !fieldWideSkip(c.prose) {
			t.Fatalf("CASE %s: the field-wide rule does NOT skip this prose, so this case measures nothing", c.name)
		}
		cmd := manifest.Command{ID: "task.x", Noun: "task", Verb: "x", Summary: c.prose}
		for _, name := range c.visible {
			if !manifestAdvertisesFlag(cmd, name) {
				t.Errorf("CASE %s: --%s is NOT advertised — the guard is still blind to a flag this prose names", c.name, name)
			}
		}
		for _, name := range c.hidden {
			if manifestAdvertisesFlag(cmd, name) {
				t.Errorf("CASE %s: --%s reads as advertised, but it is git's flag — that is the false stale-install verdict", c.name, name)
			}
		}
	}
}

// TestForeignClauseScopingShapes pins the clause reader in both directions: the
// clause that invokes a foreign program goes, everything else stays. The `-`
// stdin spelling that appears in the TRUE drift's own prose must NOT read as a
// foreign program, or the guard would disqualify itself.
func TestForeignClauseScopingShapes(t *testing.T) {
	cases := []struct {
		text    string
		removed bool   // a clause was dropped
		keeps   string // a substring that must SURVIVE the scoping
	}{
		{text: "--criterion-text-file <path> (or `-` for stdin) reads the bytes", removed: false, keeps: "--criterion-text-file"},
		{text: "no spans at all --met", removed: false, keeps: "--met"},
		{text: "run `bp task get <id>` first", removed: false, keeps: "bp task get"},
		{text: "LEGAL SPELLINGS — `git rev-list --count origin/main..<sha>`", removed: true},
		{text: "`git -C` in any spelling (also --git-dir/--work-tree)", removed: true},
		{text: "an unterminated `span", removed: false, keeps: "unterminated"},
		{text: "`` empty span --met", removed: false, keeps: "--met"},
		// THE WHOLE POINT: a field that quotes git AND advertises its own flag
		// loses only the git clause.
		{text: "Pass --note to record it. Prove it with `git rev-list --count x`.", removed: true, keeps: "--note"},
	}
	for _, c := range cases {
		got := withoutForeignProgramClauses(c.text)
		if removed := got != c.text; removed != c.removed {
			t.Errorf("withoutForeignProgramClauses(%q) removed=%v, want %v (got %q)", c.text, removed, c.removed, got)
		}
		if c.keeps != "" && !strings.Contains(got, c.keeps) {
			t.Errorf("withoutForeignProgramClauses(%q) dropped %q: %q", c.text, c.keeps, got)
		}
	}
}
