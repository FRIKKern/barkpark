package cli

import (
	"bytes"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE MEASUREMENT THIS FILE LOCKS (#18, task-7f06080cfd584194).
//
// RED WITHOUT the block — measured by deleting the `if cmd.ID ==
// docMutateCommandID { … }` stanza from usageCommand (usage.go) and re-running:
//
//	--- FAIL: TestDocMutateHelpShowsEveryMutationShape
//	    `bp doc mutate --help` never names the mutation op "create".
//	    help=…usage: barkpark doc mutate…flags:  --file <value>…
//
// The captured pre-change help is the whole complaint: two flags, a summary
// that says "(create/patch/publish/unpublish/delete)", and no shape anywhere —
// so the next move after a `malformed` 400 is to open mutations.ex.
//
// The DRIFT arm below is the one that keeps this honest over time: it reads the
// server's own apply_one clause heads and compares them to mutateShapeOps in
// BOTH directions, so neither a new server op nor a help entry for an op the
// server would reject can survive a test run.

// serverMutationsPath is the api-side source of truth, relative to this package.
// READ ONLY — this row's fence is internal/cli/; the 422-names-the-field half of
// #18 is a change to this file and is handed back to the lead, not made here.
const serverMutationsPath = "../../api/lib/barkpark/content/mutations.ex"

// applyOneHead matches the op name in an apply_one/3 clause head. Both physical
// shapes in the file are covered: the single-line
// `defp apply_one(%{"create" => attrs}, dataset, opts) do` and the wrapped
// `defp apply_one(\n  %{"patch" => %{…}} = patch},\n  dataset,\n  opts\n) do`.
var applyOneHead = regexp.MustCompile(`%\{"([A-Za-z]+)" =>`)

// serverMutationOps returns the DEDUPED set of op names the server's apply_one/3
// accepts, read out of mutations.ex. The catch-all clause `apply_one(_, _, _)`
// carries no map pattern and so contributes nothing, which is correct: it is the
// refusal, not a shape.
func serverMutationOps(t *testing.T) []string {
	t.Helper()
	src, err := os.ReadFile(serverMutationsPath)
	if err != nil {
		t.Skipf("server mutations source not readable (%v) — drift arm cannot run", err)
	}
	lines := strings.Split(string(src), "\n")
	seen := map[string]bool{}
	var ops []string
	for i, line := range lines {
		if !strings.Contains(line, "defp apply_one(") {
			continue
		}
		// The pattern is on the clause-head line itself, or (for the wrapped
		// form) on one of the next two lines before `dataset,`.
		end := i + 3
		if end > len(lines) {
			end = len(lines)
		}
		window := lines[i:end]
		for _, w := range window {
			m := applyOneHead.FindStringSubmatch(w)
			if m == nil {
				continue
			}
			if !seen[m[1]] {
				seen[m[1]] = true
				ops = append(ops, m[1])
			}
			break
		}
	}
	if len(ops) == 0 {
		t.Fatalf("parsed ZERO apply_one clause heads out of %s — the parser went blind, "+
			"which would make every assertion below vacuous", serverMutationsPath)
	}
	sort.Strings(ops)
	return ops
}

// TestMutateHelpNamesEveryServerMutationClause is the drift arm. It fails in
// BOTH directions on purpose:
//
//	add a fake op to mutateShapeOps      → "help names an op the server does not accept"
//	delete one from mutateShapeOps       → "the server accepts an op the help never names"
//
// Both were run by hand before this file was committed; the messages below are
// the ones that printed.
func TestMutateHelpNamesEveryServerMutationClause(t *testing.T) {
	server := serverMutationOps(t)
	help := append([]string(nil), mutateShapeOps...)
	sort.Strings(help)

	inHelp := map[string]bool{}
	for _, op := range help {
		inHelp[op] = true
	}
	inServer := map[string]bool{}
	for _, op := range server {
		inServer[op] = true
	}

	for _, op := range server {
		if !inHelp[op] {
			t.Errorf("the server accepts mutation op %q (an apply_one clause in %s) "+
				"and `bp doc mutate --help` never names it — a caller hitting that shape "+
				"is back to reading mutations.ex.\nserver=%v\nhelp=%v",
				op, serverMutationsPath, server, help)
		}
	}
	for _, op := range help {
		if !inServer[op] {
			t.Errorf("`bp doc mutate --help` names mutation op %q, which is NOT an apply_one "+
				"clause in %s — the help would send a caller into a `malformed` 400.\n"+
				"server=%v\nhelp=%v", op, serverMutationsPath, server, help)
		}
	}
}

// TestMutateShapeLinesRenderEveryOp guards the OTHER half of the drift: the op
// NAMES list can be complete while the rendered block silently drops one (they
// are separate literals so the test above can compare names without parsing
// prose). Every op in mutateShapeOps must appear, quoted as a JSON key, in the
// text a caller actually reads.
func TestMutateShapeLinesRenderEveryOp(t *testing.T) {
	block := strings.Join(mutateShapeLines(), "\n")
	for _, op := range mutateShapeOps {
		if !strings.Contains(block, `"`+op+`"`) {
			t.Errorf("mutation op %q is in mutateShapeOps but the rendered help block never "+
				"shows a {%q: …} shape.\nblock:\n%s", op, op, block)
		}
	}
	// The three id/type ops are the ones the report named explicitly: their
	// wrong shape was the 400 that cost the most time.
	for _, op := range []string{"publish", "unpublish", "delete"} {
		want := `{"` + op + `":`
		if !strings.Contains(block, want) || !strings.Contains(block, `"id":"<id>", "type":"<type>"`) {
			t.Errorf("the {id,type} requirement for %q is not literally shown.\nblock:\n%s", op, block)
		}
	}
}

func docMutateHelpCommand() manifest.Command {
	return manifest.Command{
		ID:      docMutateCommandID,
		Noun:    "doc",
		Verb:    "mutate",
		Summary: "Apply an atomic batch of mutations (create/patch/publish/unpublish/delete).",
		Writes:  true,
		Batch:   true,
		Flags: []manifest.Flag{
			{Name: "file", Type: "file", Summary: "Mutations payload from a file or - for stdin."},
			{Name: "quiet", Type: "bool", Summary: "Print only the resulting rev."},
		},
	}
}

func renderUsage(cmd manifest.Command) string {
	var stdout, stderr bytes.Buffer
	usageCommand(newWriter(&stdout, &stderr), cmd)
	return stderr.String()
}

// TestDocMutateHelpShowsEveryMutationShape is criterion c2's CLI half: the
// shapes are where the caller looks. It asserts on the real help renderer, not
// on the literal slice, so deleting the usage.go stanza reds it.
func TestDocMutateHelpShowsEveryMutationShape(t *testing.T) {
	help := renderUsage(docMutateHelpCommand())
	for _, op := range mutateShapeOps {
		if !strings.Contains(help, `"`+op+`"`) {
			t.Fatalf("`bp doc mutate --help` never names the mutation op %q.\nhelp=%s", op, help)
		}
	}
	if !strings.Contains(help, "mutation shapes:") {
		t.Fatalf("the help has no `mutation shapes:` block at all.\nhelp=%s", help)
	}
	// The draft consequence belongs next to the shapes — a caller reading how
	// to write must learn in the same breath that the write is invisible.
	if !strings.Contains(help, "drafts:") || !strings.Contains(help, "bp doc publish") {
		t.Fatalf("the shapes block never says the create/patch family writes drafts, nor how to "+
			"publish.\nhelp=%s", help)
	}
}

// TestMutationShapesDoNotLeakIntoOtherHelp is the discrimination control. A
// block printed on every command would pass the test above while telling a `doc
// get` caller about mutation payloads.
func TestMutationShapesDoNotLeakIntoOtherHelp(t *testing.T) {
	other := manifest.Command{ID: "doc.get", Noun: "doc", Verb: "get", Summary: "Fetch one document."}
	if help := renderUsage(other); strings.Contains(help, "mutation shapes:") {
		t.Fatalf("`bp doc get --help` printed the mutation shapes block.\nhelp=%s", help)
	}
}
