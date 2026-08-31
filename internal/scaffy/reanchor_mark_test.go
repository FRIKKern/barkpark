package scaffy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// reanchorSiblingMarkCommand is a REANCHOR REPLACE whose payload RE-EMITS an
// anchor line that already carries someone else's planted mark comment
// (`MARK:legacy-seed`) before it plants its own (`MARK:cron-…`). Every rule of
// the frozen catalog is satisfied — Run's ValidateFile pre-gate refuses on ANY
// finding, so this fixture is only meaningful because it validates clean.
const reanchorSiblingMarkCommand = `COMMAND "Add a cron worker" DESCRIPTION "Fixture: a REANCHOR REPLACE whose payload re-emits an anchor line that already carries a foreign planted mark comment." LAST_UPDATED "31-08-2026-00-00-00" DOMAIN "test" DIRECTION "add" VARIABLES
  VARIABLE 1 "Worker" TITLE "Worker module suffix" DESCRIPTION "The worker module the cron tuple points at." EXAMPLES "alpha", "beta"

IN "config.exs"
REPLACE
::: cron seed tuple :::
       # seeded by hand MARK:legacy-seed
       {"* * * * *", Workers.Seed}
::: cron seed tuple :::
WITH
::: {{.worker}} cron :::
       # seeded by hand MARK:legacy-seed
       {"* * * * *", Workers.Seed},
       # scaffy MARK:cron-{{.worker}}
       {"0 * * * *", Workers.{{.Worker}}}
::: {{.worker}} cron :::
MARK "cron-{{.worker}}"
REANCHOR "cron-"
ASLONG FILE DONT CONTAIN "MARK:cron-{{.worker}}"
`

// reanchorSiblingMarkConfig is the target file. The line directly after the
// cron list closes with the same byte the payload template's last line closes
// with (`}`), so an over-long extent K sails past the D33 tail-shape assertion
// instead of being caught by it — the splice lands SILENTLY in the wrong place.
const reanchorSiblingMarkConfig = `cron_jobs = [
       # seeded by hand MARK:legacy-seed
       {"* * * * *", Workers.Seed}
]
sweep = %{"@daily" => Workers.Sweep}
extra = [1, 2]
`

// TestReanchorLocatesMarkLineByDeclaredMark pins the D21/D33 re-anchor to the
// op's DECLARED mark. reanchorSplice used to find the payload template's mark
// line with a bare `strings.Contains(ln, "MARK:")` — a substring standing in
// for a fact the op declares structurally (Mark.Name, whose planted text
// E-008 guarantees the payload writes verbatim). Any payload that mentions the
// token "MARK:" on an earlier line — a re-emitted anchor that already carries a
// sibling's mark, a docs payload documenting the convention, generated code
// with a MARK: string constant — resolved to the WRONG line, so the static
// extent K came out too large and the run-2 splice was written past the end of
// the mark family's own block.
func TestReanchorLocatesMarkLineByDeclaredMark(t *testing.T) {
	root := t.TempDir()
	cmdPath := filepath.Join(t.TempDir(), "add-cron-worker.scaffy")
	if err := os.WriteFile(cmdPath, []byte(reanchorSiblingMarkCommand), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(root, "config.exs")
	if err := os.WriteFile(cfg, []byte(reanchorSiblingMarkConfig), 0o644); err != nil {
		t.Fatal(err)
	}

	// Run 1: no family mark planted yet — the byte-exact structural target.
	if _, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"Worker": "alpha"}, RepoRoot: root}); err != nil {
		t.Fatalf("run 1: %v", err)
	}
	// Run 2: the family IS planted — the D33 re-anchor path.
	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"Worker": "beta"}, RepoRoot: root})
	if err != nil {
		t.Fatalf("run 2 (re-anchor): %v", err)
	}
	if len(rep.Ops) != 1 || !rep.Ops[0].Reanchored {
		t.Fatalf("run 2 must take the re-anchor path, got %+v", rep.Ops)
	}

	got, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(got), "\n"), "\n")
	idx := func(needle string) int {
		for i, ln := range lines {
			if strings.Contains(ln, needle) {
				return i
			}
		}
		return -1
	}

	closeIdx := idx("]")
	betaIdx := idx("MARK:cron-beta")
	if betaIdx < 0 {
		t.Fatalf("run 2 planted no beta mark:\n%s", got)
	}
	if closeIdx < 0 || betaIdx > closeIdx {
		t.Fatalf("re-anchor spliced OUTSIDE the cron_jobs list: the mark line was located by the bare token %q, "+
			"which matched the payload's re-emitted %q line instead of the op's declared MARK:cron-<worker>, "+
			"so the static extent K over-shot the family block (beta at line %d, list closes at line %d):\n%s",
			"MARK:", "MARK:legacy-seed", betaIdx+1, closeIdx+1, got)
	}

	// The over-long extent also comma-s a line that is not part of the family
	// block and re-emits the anchor line a second time.
	if n := strings.Count(string(got), "MARK:legacy-seed"); n != 1 {
		t.Fatalf("re-anchor duplicated the payload's re-emitted anchor line (%d copies, want 1) — "+
			"the mark line was misclassified by the bare %q token:\n%s", n, "MARK:", got)
	}
	if !strings.Contains(string(got), "sweep = %{\"@daily\" => Workers.Sweep}\n") {
		t.Fatalf("re-anchor edited a line outside the mark family (the separator comma landed on `sweep`) — "+
			"the extent K was computed from a line found by the bare %q token:\n%s", "MARK:", got)
	}
}
