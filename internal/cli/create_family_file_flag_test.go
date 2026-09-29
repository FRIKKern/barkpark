package cli

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ---------------------------------------------------------------------------
// scaffy-backlog-ensure-cli-flag — THE MEASUREMENT THAT REPLACED A COMMAND.
//
// The row asked whether a scaffy `ensure-cli-flag(verb, flag)` command earns
// its place under the D57 ensure law, given "the missing file-flag defect class
// recurred 3x". Re-measuring the recurrences is what decided it:
//
//	git log -S'flag("file"' --all -- api/lib/barkpark/plugins/capabilities.ex
//	  c3abc60db 2026-07-13 fix(cli): honor doc create file and stdin body
//	  c96949237 2026-07-13 fix(cli): honor doc create file and stdin body
//	  6d19fba83 2026-07-13 fix(cli): honor document-create file and stdin bodies
//	  c7ab0ca26 2026-07-16 fix(cli): doc create-or-replace / create-if-not-exists accept --file
//	  8aab0269b 2026-07-16 …same, as #3810
//
// `git patch-id --stable` collapses those five to THREE ids, and the three
// July-13 commits are one event — the BUILD of --file/stdin support itself
// (319 insertions, 69 of them the run.go plumbing), not a recurrence of
// anything. So the class has ONE genuine recurrence: #3810, two sibling verbs,
// two manifest lines, because the runtime plumbing already existed.
//
// The third alleged recurrence, `doc.patch` "found at W4 review", is a
// DIFFERENT class: doc.patch declares `[set]` only and correctly should — its
// body is a patch spec, not a document object. What was wrong there was the
// HELP advertising --file for every writes:true command regardless of manifest.
// That is fixed by derivation (usage.go writeBodyHint reads cmd.Flags), and the
// parent census scaffy-backlog-file-flag-sweep closed on exactly that.
//
// VERDICT: no scaffy command. Under D57, an ensure command earns its keep on
// MULTI-SITE synchronisation — ensure-cli-noun exists because a noun lives in
// three copies (completionNouns, usageBuiltins, the dispatch switch). A body
// flag lives in exactly ONE site, the manifest's `flags:` list; every
// downstream surface derives from it. One site is nothing to ensure, and the
// only hard part — "does this verb take a whole document body?" — is a semantic
// judgement no template can make. A generator would have saved #3810 one line.
//
// What DOES generalise is the predicate below. #3810's two verbs were not
// arbitrary: they are the create FAMILY, whose payload is a whole document
// object keyed by `_id` — the exact population for which "a body from a file"
// is meaningful, and which run.go already names as setCreateFamilyOps. Keying
// the gate on that set rather than on the three flags that happened to go
// missing is what makes it catch the fourth recurrence: add a `replace` verb,
// or a new create-family op to the set, and forget the flag, and this reds.
// ---------------------------------------------------------------------------

// capabilitiesPath is the api-side manifest source, relative to this package.
// READ ONLY — this row's fence is internal/cli/ plus scaffy; a fix to a missing
// flag is a change to this file and is handed to the api lane, not made here.
const capabilitiesPath = "../../api/lib/barkpark/plugins/capabilities.ex"

var (
	// The command id is the first quoted string inside a core_cmd( block.
	coreCmdID = regexp.MustCompile(`core_cmd\(\s*"([^"]+)"`)
	// mutation_op: "createOrReplace"
	mutationOpDecl = regexp.MustCompile(`mutation_op:\s*"([A-Za-z]+)"`)
	// The SAME dual test commandHasFileFlag applies to a parsed manifest:
	// name == "file"  → flag("file", …)
	// type == "file"  → flag("<name>", "file", …)
	fileFlagDecl = regexp.MustCompile(`flag\(\s*"file"|flag\(\s*"[^"]+",\s*"file"`)
	// writes: true — the commands for which "a body from a file" is meaningful
	// at all. Without this fact the selectivity control below is dominated by
	// read verbs and passes for free; see checkSelectivity.
	writesDecl = regexp.MustCompile(`writes:\s*true`)
)

type manifestCmdSource struct {
	id          string
	mutationOp  string
	hasFileFlag bool
	writes      bool
}

// parseCapabilityCommands splits capabilities.ex on its single command
// constructor and reads the three facts this gate needs out of each block.
func parseCapabilityCommands(t *testing.T) []manifestCmdSource {
	t.Helper()
	raw, err := os.ReadFile(capabilitiesPath)
	if err != nil {
		t.Skipf("manifest source not readable (%v) — this gate cannot run", err)
	}
	src := string(raw)

	starts := coreCmdID.FindAllStringSubmatchIndex(src, -1)
	var cmds []manifestCmdSource
	for i, loc := range starts {
		end := len(src)
		if i+1 < len(starts) {
			end = starts[i+1][0]
		}
		block := src[loc[0]:end]
		c := manifestCmdSource{
			id:          src[loc[2]:loc[3]],
			hasFileFlag: fileFlagDecl.MatchString(block),
			writes:      writesDecl.MatchString(block),
		}
		if m := mutationOpDecl.FindStringSubmatch(block); m != nil {
			c.mutationOp = m[1]
		}
		cmds = append(cmds, c)
	}

	// VACUITY GUARDS. A parser that goes blind makes every assertion below pass
	// for free, which is the failure mode this whole gate exists to prevent.
	if len(cmds) < 100 {
		t.Fatalf("parsed only %d core_cmd blocks out of %s — the parser went blind; "+
			"the manifest carried 164 when this gate was written", len(cmds), capabilitiesPath)
	}
	withOp := 0
	for _, c := range cmds {
		if c.mutationOp != "" {
			withOp++
		}
	}
	if withOp == 0 {
		t.Fatalf("parsed ZERO mutation_op declarations out of %s — every assertion "+
			"about the create family would be vacuous", capabilitiesPath)
	}
	writes := 0
	for _, c := range cmds {
		if c.writes {
			writes++
		}
	}
	if writes == 0 {
		t.Fatalf("parsed ZERO writes: true declarations out of %s — checkSelectivity's "+
			"write population would be empty and its verdict vacuous", capabilitiesPath)
	}
	return cmds
}

// TestCreateFamilyVerbsDeclareFileFlag is the gate. Its subject is the
// PREDICATE setCreateFamilyOps, not a list of verbs: whatever is in that set is
// what must declare a body file flag.
//
// RED PROOF (run by hand before committing): delete the
// `flag("file", "file", "Document fields as a JSON object …")` line from
// doc.create-or-replace in capabilities.ex — i.e. re-create #3810 exactly — and
// this prints:
//
//	--- FAIL: TestCreateFamilyVerbsDeclareFileFlag
//	    doc.create-or-replace (mutation_op "createOrReplace") is in the create
//	    family but declares no --file flag
//
// Restoring the line greens it again.
func TestCreateFamilyVerbsDeclareFileFlag(t *testing.T) {
	cmds := parseCapabilityCommands(t)

	family := 0
	for _, c := range cmds {
		if c.mutationOp == "" || !setCreateFamilyOps[c.mutationOp] {
			continue
		}
		family++
		if !c.hasFileFlag {
			t.Errorf("%s (mutation_op %q) is in the create family but declares no --file flag — "+
				"its payload is a whole document object keyed by _id, so a body from a file is "+
				"exactly what it takes; add flag(\"file\", \"file\", …) to its flags: list in %s",
				c.id, c.mutationOp, capabilitiesPath)
		}
	}

	// The third vacuity guard, and the one that matters most: if the family
	// population is empty the loop above asserts nothing at all.
	if family == 0 {
		t.Fatalf("ZERO commands matched setCreateFamilyOps %v — either the manifest stopped "+
			"declaring mutation_op or the set was emptied; this gate measured nothing",
			sortedOps(setCreateFamilyOps))
	}
}

// ── checkSelectivity: the QUIET arm, as a predicate ────────────────────────
//
// This control proves TestCreateFamilyVerbsDeclareFileFlag is a PREDICATE over
// setCreateFamilyOps and not a blanket "every write needs --file". Without it,
// a blanket rule would also pass that gate's RED PROOF.
//
// IT USED TO PIN doc.patch BY NAME, and that pin was WRONG — measured
// 2026-09-17 by cli-r21-w26 (task scaffy-backlog-doc-patch-file-flag). Adding
// the one line the api lane owes that row —
//
//	flag("file", "file", "Fields to change as a JSON object …")
//
// to doc.patch in capabilities.ex, and changing NOTHING else, turned this file
// RED on main:
//
//	--- FAIL: TestCreateFamilyGateIsSelective
//	    create_family_file_flag_test.go:199: doc.patch is not among the flagless
//	    non-family commands [...] — if it gained a --file flag that is a real
//	    decision, and this gate's documented specimen must move with it
//
// The pin's own error text asked for a real decision, and one had already been
// made in the OTHER direction: PR #18616 built the run.go routing that sends a
// --file object to a command's SetKey target, so a set_key command CAN take a
// file body correctly. The pin was a review tripwire whose question is
// discharged; left standing it is a cross-lane wall that reds a correct
// one-line api change with a message about a "documented specimen".
//
// An enumeration is a snapshot; a predicate is a rule. The selectivity fact was
// never "doc.patch specifically" — it is "some write outside the create family
// declares no file flag, and the gate is silent on it". Naming a member of that
// population froze one sample of it. The write filter is the sharpening the pin
// was standing in for: the flagless-non-family population is dominated by READ
// verbs (doc.get, doc.ls, search.query …), for which a body flag is meaningless,
// so an unfiltered count would stay non-empty even if every WRITE outside the
// family gained --file — the exact blanket rule this control exists to refuse.
//
// Returning an error rather than taking *testing.T is what makes the rule
// testable against fixtures the live manifest does not yet contain.
func checkSelectivity(cmds []manifestCmdSource) error {
	var outsideWrites []string
	for _, c := range cmds {
		if c.mutationOp != "" && setCreateFamilyOps[c.mutationOp] {
			continue
		}
		if c.writes && !c.hasFileFlag {
			outsideWrites = append(outsideWrites, c.id)
		}
	}
	if len(outsideWrites) == 0 {
		return fmt.Errorf("every WRITE outside the create family declares --file, so the gate's " +
			"selectivity is untested — it would pass identically as a blanket \"every write needs " +
			"--file\" rule, which is the thing this control refuses")
	}
	return nil
}

// TestCreateFamilyGateIsSelective runs the rule against the real manifest.
func TestCreateFamilyGateIsSelective(t *testing.T) {
	if err := checkSelectivity(parseCapabilityCommands(t)); err != nil {
		t.Error(err)
	}
}

// TestSelectivityGateDoesNotPinDocPatch is the arm that REDS ON REVERSION.
//
// Its fixture is the manifest as it will look the day the api lane lands
// doc.patch's file flag. Reinstating any by-name pin inside checkSelectivity
// reds here — which is precisely the failure this change removes, caught in
// THIS repo instead of in a cross-lane PR.
func TestSelectivityGateDoesNotPinDocPatch(t *testing.T) {
	afterAPILands := []manifestCmdSource{
		{id: "doc.create", mutationOp: "create", writes: true, hasFileFlag: true},
		{id: "doc.create-or-replace", mutationOp: "createOrReplace", writes: true, hasFileFlag: true},
		// The change under test: doc.patch declares a file flag. It is NOT in
		// setCreateFamilyOps, so it is a non-family write WITH the flag.
		{id: "doc.patch", mutationOp: "patch", writes: true, hasFileFlag: true},
		// …and some other non-family write still lacks one, which is the fact
		// the control actually measures.
		{id: "doc.publish", writes: true, hasFileFlag: false},
		{id: "doc.get", writes: false, hasFileFlag: false},
	}
	if err := checkSelectivity(afterAPILands); err != nil {
		t.Errorf("doc.patch gaining a --file flag must NOT red the selectivity control — "+
			"PR #18616 built the SetKey routing that makes that declaration correct, and "+
			"doc.publish still witnesses selectivity here. got: %v", err)
	}
}

// TestSelectivityGateStillCatchesABlanketRule is the quiet control on the
// control: proof that checkSelectivity is not simply inert after the de-pinning.
// Reverting the write filter, or weakening the emptiness check, reds this.
func TestSelectivityGateStillCatchesABlanketRule(t *testing.T) {
	blanket := []manifestCmdSource{
		{id: "doc.create", mutationOp: "create", writes: true, hasFileFlag: true},
		{id: "doc.patch", mutationOp: "patch", writes: true, hasFileFlag: true},
		{id: "doc.publish", writes: true, hasFileFlag: true},
		// Reads without the flag: numerous, and deliberately NOT a witness.
		// If the write filter is dropped these make the gate pass for free.
		{id: "doc.get", writes: false, hasFileFlag: false},
		{id: "doc.ls", writes: false, hasFileFlag: false},
	}
	if err := checkSelectivity(blanket); err == nil {
		t.Error("a manifest in which EVERY write declares --file must fail the selectivity " +
			"control; got nil, so the control measures nothing and read verbs are being " +
			"counted as witnesses")
	}
}

// TestSetIDKeyRefusalNeverNamesAnUndeclaredFileFlag is the arm on the run.go
// change. checkSetIDKeyRouting used to append "(or --file to send a body
// verbatim …)" to BOTH arms unconditionally — including the `patch` arm, whose
// command declares [set] only, so splitArgs refuses --file with exit 2. The
// refusal was recommending a flag the next invocation would reject.
//
// RED PROOF: make fileBodyAside return the sentence unconditionally (drop the
// commandHasFileFlag check) and the patch subtest reds with
// "refusal names --file but doc.patch declares no file flag".
func TestSetIDKeyRefusalNeverNamesAnUndeclaredFileFlag(t *testing.T) {
	mk := func(id, verb, op, setKey string, withFile bool) manifest.Command {
		flags := []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}}
		if withFile {
			flags = append([]manifest.Flag{{Name: "file", Type: "file"}}, flags...)
		}
		return manifest.Command{
			ID: id, Noun: "doc", Verb: verb, Writes: true, MutationOp: op, SetKey: setKey,
			HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
			Flags: flags,
		}
	}

	t.Run("patch declares no file flag, so its refusal must not name --file", func(t *testing.T) {
		cmd := mk("doc.patch", "patch", "patch", "set", false)
		err := checkSetIDKeyRouting(cmd, "id=x", "id")
		if err == nil {
			t.Fatalf("want a refusal for --set id= on doc.patch, got nil — this arm measured nothing")
		}
		if strings.Contains(err.Error(), "--file") {
			t.Errorf("refusal names --file but doc.patch declares no file flag; splitArgs would "+
				"reject it with exit 2. err=%s", err)
		}
		// The refusal must still carry its real remedy, or "no --file" would be
		// satisfiable by an empty message.
		if !strings.Contains(err.Error(), "--set id:=null") {
			t.Errorf("refusal lost its removal hint: %s", err)
		}
	})

	t.Run("create declares a file flag, so its refusal keeps the escape hatch", func(t *testing.T) {
		cmd := mk("doc.create", "create", "create", "", true)
		err := checkSetIDKeyRouting(cmd, "id=x", "id")
		if err == nil {
			t.Fatalf("want a refusal for --set id= on doc.create, got nil — this arm measured nothing")
		}
		if !strings.Contains(err.Error(), "--file") {
			t.Errorf("doc.create DOES declare --file; dropping the escape hatch removes the only "+
				"way to store a content field literally named id. err=%s", err)
		}
		if !strings.Contains(err.Error(), "_id") {
			t.Errorf("refusal lost the _id spelling: %s", err)
		}
	})
}

func sortedOps(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
