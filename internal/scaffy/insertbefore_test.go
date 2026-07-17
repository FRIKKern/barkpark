package scaffy

// insertbefore_test.go — conformance tests for the INSERT BEFORE
// FIRST|LAST primitive (ratified from the D55 deferral; task
// scaffy-backlog-insert-before-primitive). The splice lands the payload
// directly BEFORE the pinned anchor occurrence, the anchor survives
// untouched, and the AFTER laws carry over unchanged: implicit
// planted-MARK skip, receipt post-image excise on remove, fail-loud
// missing anchor, REANCHOR stays REPLACE-only (P-005).
//
// The closing test pins the MOTIVATING FIXTURE: the live corpus
// add-canonical-marker command marking TWO different-slug capabilities
// in ONE file — the exact scenario the pre-ratify self-consuming
// REPLACE + forced-REANCHOR idiom failed (run-proven: tail-desync abort
// on a `{`-terminal head, silent comma-corruption + duplicated head on
// a `}`-terminal one).

import (
	"errors"
	"strings"
	"testing"
)

const noteAboveSrc = `COMMAND "add-note-above" DESCRIPTION "Plant a note directly above a pinned heading." CONCEPT "note" DIRECTION "add"

VARIABLE 1 "NoteText" OPAQUE TITLE "Note" DESCRIPTION "The note text." EXAMPLES "reviewed"

IN "docs/notes.md"
INSERT BEFORE FIRST
::: pinned heading :::
## Pinned
::: pinned heading :::
WITH
::: {{.NoteText}} note :::
<!-- scaffy:add-note-above MARK:note-above -->
{{.NoteText}}
::: {{.NoteText}} note :::
MARK "note-above"

ASSERT FILE "docs/notes.md" CONTAINS "MARK:note-above"
`

const notesSeed = "# Notes\n\n## Pinned\nkeep me\n"

func TestInsertBeforeFirstRunNoopRemoveByteClean(t *testing.T) {
	root := t.TempDir()
	writeTreeFile(t, root, "docs/notes.md", notesSeed)
	cmdPath := writeCommand(t, root, "add-note-above.scaffy", noteAboveSrc)
	before := snapshotSansReceipts(t, root)
	vars := map[string]string{"NoteText": "reviewed"}

	// Run 1: the payload splices directly BEFORE the anchor; the anchor
	// bytes survive untouched.
	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: vars, RepoRoot: root})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !rep.Ok || !rep.Mutated {
		t.Fatalf("run 1 not ok+mutated: %+v", rep)
	}
	if rep.Ops[0].Kind != "insert-before-first" || rep.Ops[0].Status != OpInjected {
		t.Fatalf("op result: %+v", rep.Ops[0])
	}
	want := "# Notes\n\n<!-- scaffy:add-note-above MARK:note-above -->\nreviewed\n## Pinned\nkeep me\n"
	if got := readTreeFile(t, root, "docs/notes.md"); got != want {
		t.Fatalf("splice position wrong:\ngot  %q\nwant %q", got, want)
	}

	// Run 2: the implicit planted-MARK guard skips — full no-op, no
	// receipt clobber (D35).
	rep2, err := Run(RunOptions{CommandPath: cmdPath, Vars: vars, RepoRoot: root})
	if err != nil {
		t.Fatalf("re-run: %v", err)
	}
	if rep2.Mutated || rep2.Ops[0].Status != OpSkipped {
		t.Fatalf("re-run must skip on the planted mark: %+v", rep2.Ops[0])
	}
	if got := readTreeFile(t, root, "docs/notes.md"); got != want {
		t.Fatalf("no-op re-run changed bytes:\n%q", got)
	}

	// Remove: receipt replay excises the recorded post-image — the tree
	// is byte-clean vs the pre-apply snapshot (D34).
	rrep, err := Remove(RemoveOptions{CommandPath: cmdPath, Vars: vars, RepoRoot: root})
	if err != nil {
		t.Fatalf("Remove: %v", err)
	}
	if !rrep.Ok || !rrep.Mutated {
		t.Fatalf("remove not ok+mutated: %+v", rrep)
	}
	if rrep.Ops[0].Kind != "insert-before-first" || rrep.Ops[0].Status != OpRemoved {
		t.Fatalf("inversion result: %+v", rrep.Ops[0])
	}
	assertTreesEqual(t, "post-remove", before, snapshotSansReceipts(t, root))
}

const stampAboveTailSrc = `COMMAND "stamp-above-tail" DESCRIPTION "Stamp directly above the LAST divider." CONCEPT "stamp" DIRECTION "add"

VARIABLE 1 "StampText" OPAQUE TITLE "Stamp" DESCRIPTION "The stamp text." EXAMPLES "v2"

IN "docs/log.md"
INSERT BEFORE LAST
::: divider line :::
---
::: divider line :::
WITH
::: {{.StampText}} stamp :::
<!-- scaffy:stamp-above-tail MARK:stamp-above-tail -->
{{.StampText}}
::: {{.StampText}} stamp :::
MARK "stamp-above-tail"

ASSERT FILE "docs/log.md" CONTAINS "MARK:stamp-above-tail"
`

func TestInsertBeforeLastPinsLastOccurrence(t *testing.T) {
	root := t.TempDir()
	writeTreeFile(t, root, "docs/log.md", "alpha\n---\nbeta\n---\ngamma\n")
	cmdPath := writeCommand(t, root, "stamp-above-tail.scaffy", stampAboveTailSrc)

	rep, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"StampText": "v2"}, RepoRoot: root})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if rep.Ops[0].Kind != "insert-before-last" || rep.Ops[0].Status != OpInjected {
		t.Fatalf("op result: %+v", rep.Ops[0])
	}
	want := "alpha\n---\nbeta\n<!-- scaffy:stamp-above-tail MARK:stamp-above-tail -->\nv2\n---\ngamma\n"
	if got := readTreeFile(t, root, "docs/log.md"); got != want {
		t.Fatalf("BEFORE LAST must splice above the last occurrence:\ngot  %q\nwant %q", got, want)
	}
}

func TestInsertBeforeMissingAnchorFailsLoud(t *testing.T) {
	root := t.TempDir()
	writeTreeFile(t, root, "docs/notes.md", "# Notes\nno pinned heading here\n")
	cmdPath := writeCommand(t, root, "add-note-above.scaffy", noteAboveSrc)

	_, err := Run(RunOptions{CommandPath: cmdPath, Vars: map[string]string{"NoteText": "reviewed"}, RepoRoot: root})
	var ae *ApplyError
	if !errors.As(err, &ae) || !strings.Contains(err.Error(), "INSERT BEFORE FIRST anchor not found") {
		t.Fatalf("want fail-loud missing-anchor ApplyError, got %v", err)
	}
	if got := readTreeFile(t, root, "docs/notes.md"); !strings.HasSuffix(got, "here\n") || strings.Contains(got, "MARK:") {
		t.Fatalf("failed run must write nothing:\n%q", got)
	}
}

// TestReanchorOnInsertBeforeRefused: REANCHOR stays REPLACE-only —
// attaching it to an INSERT BEFORE op reds P-005 at parse time.
func TestReanchorOnInsertBeforeRefused(t *testing.T) {
	src := strings.Replace(noteAboveSrc,
		"MARK \"note-above\"\n",
		"MARK \"note-above\"\nREANCHOR \"note-\"\n", 1)
	findings := ValidateFile("reanchor-on-insert-before.scaffy", []byte(src))
	found := false
	for _, f := range findings {
		if f.Rule == RuleReanchorMisplaced {
			found = true
		}
	}
	if !found {
		t.Fatalf("REANCHOR on INSERT BEFORE must red P-005, got:\n%s", renderFindings(findings))
	}
}

// TestParseInsertBeforeVerbs: both BEFORE spellings parse to their
// verbs; an unpinned INSERT BEFORE is P-002 (the red fixture
// P-002-insert-before-unpinned.scaffy pins the same law file-side).
func TestParseInsertBeforeVerbs(t *testing.T) {
	cmd, findings := Parse("verbs.scaffy", []byte(noteAboveSrc))
	if len(findings) != 0 {
		t.Fatalf("unexpected findings: %v", findings)
	}
	if in, ok := cmd.Ops[0].(*InOp); !ok || in.Verb != InsertBeforeFirst || in.Verb.String() != "INSERT BEFORE FIRST" {
		t.Fatalf("verb: %+v", cmd.Ops[0])
	}
	cmd, findings = Parse("verbs.scaffy", []byte(stampAboveTailSrc))
	if len(findings) != 0 {
		t.Fatalf("unexpected findings: %v", findings)
	}
	if in, ok := cmd.Ops[0].(*InOp); !ok || in.Verb != InsertBeforeLast || in.Verb.String() != "INSERT BEFORE LAST" {
		t.Fatalf("verb: %+v", cmd.Ops[0])
	}
}

// ---- the motivating fixture, re-proven on the ratified primitive ----

const canonicalMarkerPath = "../../scaffy/commands/add-canonical-marker.scaffy"

const clientSeed = `package pkg

func New(cfg Config) *Client {
	return &Client{cfg: cfg}
}

func IsZero(v int) bool { return v == 0 }
`

func runCanonicalMarker(root, head, slug, aka string) (*RunReport, error) {
	return Run(RunOptions{
		CommandPath: canonicalMarkerPath,
		RepoRoot:    root,
		Vars: map[string]string{
			"TargetFile":   "pkg/client.go",
			"HeadLine":     head,
			"slug":         slug,
			"Aka":          aka,
			"CommentToken": "//",
		},
	})
}

// TestCanonicalMarkerTwoSlugsOneFile — the ratifying scenario, now
// green: two different-slug markers in ONE file land as independent
// clean inserts (the pre-ratify REPLACE idiom aborted or corrupted
// here), the same-slug re-run no-ops on the guard, and both receipts
// replay back to a byte-clean tree.
func TestCanonicalMarkerTwoSlugsOneFile(t *testing.T) {
	root := t.TempDir()
	writeTreeFile(t, root, "pkg/client.go", clientSeed)
	before := snapshotSansReceipts(t, root)

	newVars := []string{"func New(cfg Config) *Client {", "api-client-new", "New,client"}
	zeroVars := []string{"func IsZero(v int) bool { return v == 0 }", "zero-check", "zero,empty"}

	rep1, err := runCanonicalMarker(root, newVars[0], newVars[1], newVars[2])
	if err != nil || !rep1.Ok {
		t.Fatalf("run 1: %v %+v", err, rep1)
	}
	rep2, err := runCanonicalMarker(root, zeroVars[0], zeroVars[1], zeroVars[2])
	if err != nil || !rep2.Ok {
		t.Fatalf("run 2 (second slug, same file) must succeed: %v %+v", err, rep2)
	}

	want := `package pkg

// scaffy:add-canonical-marker api-client-new MARK:canonical-api-client-new
// @canonical capability:api-client-new aka:New,client
func New(cfg Config) *Client {
	return &Client{cfg: cfg}
}

// scaffy:add-canonical-marker zero-check MARK:canonical-zero-check
// @canonical capability:zero-check aka:zero,empty
func IsZero(v int) bool { return v == 0 }
`
	if got := readTreeFile(t, root, "pkg/client.go"); got != want {
		t.Fatalf("two-slug plant wrong:\ngot  %q\nwant %q", got, want)
	}

	// Same-slug re-run: full no-op on the guard/mark.
	rep3, err := runCanonicalMarker(root, newVars[0], newVars[1], newVars[2])
	if err != nil {
		t.Fatalf("same-slug re-run: %v", err)
	}
	if rep3.Mutated || rep3.Ops[0].Status != OpSkipped {
		t.Fatalf("same-slug re-run must skip: %+v", rep3.Ops[0])
	}
	if got := readTreeFile(t, root, "pkg/client.go"); got != want {
		t.Fatalf("no-op re-run changed bytes:\n%q", got)
	}

	// Receipt replay both runs back out — byte-clean (D34). Insert
	// inversions are independent block excisions, order-free.
	for _, vars := range [][]string{zeroVars, newVars} {
		rrep, err := Remove(RemoveOptions{
			CommandPath: canonicalMarkerPath,
			RepoRoot:    root,
			Vars: map[string]string{
				"TargetFile": "pkg/client.go", "HeadLine": vars[0],
				"slug": vars[1], "Aka": vars[2], "CommentToken": "//",
			},
		})
		if err != nil || !rrep.Ok {
			t.Fatalf("remove %s: %v %+v", vars[1], err, rrep)
		}
	}
	assertTreesEqual(t, "post-remove", before, snapshotSansReceipts(t, root))
}
