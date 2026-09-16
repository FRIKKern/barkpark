package cli

import (
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
)

type manifestCmdSource struct {
	id          string
	mutationOp  string
	hasFileFlag bool
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

// TestCreateFamilyGateIsSelective is the QUIET arm — the control that proves
// the gate above is a predicate and not a blanket "every write needs --file".
//
// Without it, a gate that required the flag of ALL 104 writes:true commands
// would also pass the RED PROOF, and would have forced --file onto doc.patch,
// whose parser rejects it. The arm asserts the selectivity in both directions:
// a non-family write exists that lacks the flag, and the gate is silent on it.
func TestCreateFamilyGateIsSelective(t *testing.T) {
	cmds := parseCapabilityCommands(t)

	var outsideWithoutFile []string
	for _, c := range cmds {
		if c.mutationOp != "" && setCreateFamilyOps[c.mutationOp] {
			continue
		}
		if !c.hasFileFlag {
			outsideWithoutFile = append(outsideWithoutFile, c.id)
		}
	}
	if len(outsideWithoutFile) == 0 {
		t.Fatalf("every command outside the create family declares --file, so the gate's "+
			"selectivity is untested — it would pass identically as a blanket rule")
	}

	// doc.patch is the named specimen: the W4 review's alleged third
	// "recurrence", which is correctly flagless.
	found := false
	for _, id := range outsideWithoutFile {
		if id == "doc.patch" {
			found = true
		}
	}
	if !found {
		t.Errorf("doc.patch is not among the flagless non-family commands %v — if it gained a "+
			"--file flag that is a real decision, and this gate's documented specimen must move with it",
			outsideWithoutFile)
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
