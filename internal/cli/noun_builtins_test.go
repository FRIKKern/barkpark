package cli

import (
	"bytes"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// dispatchedVerb is one (noun, verb) pair the CLI can dispatch, with where it
// came from — the manifest tree or the nounBuiltins registry.
type dispatchedVerb struct {
	noun   string
	verb   string
	origin string
}

// dispatchedVerbs enumerates EVERY (noun, verb) the CLI dispatches for the
// nouns a manifest declares: the manifest's own verbs plus the verb-level
// built-ins registered in nounBuiltins. This is the enumeration criterion 2 of
// task-b2f6e594819f9ae7 asks for; the help test below is its assertion.
func dispatchedVerbs(tree *manifest.Tree) []dispatchedVerb {
	var all []dispatchedVerb
	for _, n := range tree.Nouns {
		for _, c := range n.Verbs {
			all = append(all, dispatchedVerb{noun: c.Noun, verb: c.Verb, origin: "manifest"})
		}
	}
	for _, b := range nounBuiltins {
		all = append(all, dispatchedVerb{noun: b.Noun, verb: b.Verb, origin: "built-in"})
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].noun != all[j].noun {
			return all[i].noun < all[j].noun
		}
		return all[i].verb < all[j].verb
	})
	return all
}

// nounHelpText renders the help a user sees for one noun. Manifest nouns go
// through usageNoun (the exact function `bp <noun> --help` calls); the two
// non-manifest nouns that carry built-ins own their own printer, so the test
// reaches them the same way Execute does. A noun with no help surface at all
// FAILS — that absence is the defect, not a reason to skip.
func nounHelpText(t *testing.T, tree *manifest.Tree, noun string) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	switch {
	case hasManifestNoun(tree, noun):
		usageNoun(w, tree, noun)
	case noun == "server":
		printServerNounHelp(w)
	case noun == "mcp":
		printMCPServeHelp(w)
	case noun == "context":
		printContextPackHelp(w)
	default:
		t.Fatalf("noun %q carries a dispatched verb but this test knows no help "+
			"surface for it — wire one (that missing surface IS the bug this test guards)", noun)
	}
	return stdout.String() + stderr.String()
}

func hasManifestNoun(tree *manifest.Tree, noun string) bool {
	_, ok := lookupNoun(tree, noun)
	return ok
}

// TestEveryDispatchedVerbAppearsInItsNounHelp is the criterion-2 gate.
//
// RED ON origin/main: `bp task --help` renders straight from the server
// manifest, which declares no `create` verb under `task`, while the CLI has
// dispatched `bp task create` as a client-side built-in for months. An agent
// told to read the manifest concluded the verb did not exist and filed through
// a raw `doc mutate`, landing drafts (the rot on task-cc83c7e8daef09a5). This
// test enumerates every (noun, verb) the CLI dispatches — manifest verbs UNION
// the nounBuiltins registry — and asserts each one is printed by its noun's
// help.
func TestEveryDispatchedVerbAppearsInItsNounHelp(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	all := dispatchedVerbs(tree)
	if len(all) == 0 {
		t.Fatal("enumerated no dispatched verbs — the fixture or the registry stopped " +
			"loading; fix this guard before trusting it")
	}
	// Non-vacuity: the exact pair that motivated the row must be in the
	// enumeration, or a green here proves nothing.
	if !containsPair(all, "task", "create") {
		t.Fatal("enumeration is missing (task, create) — the registry no longer " +
			"carries the built-in this test exists for")
	}

	help := map[string]string{}
	for _, dv := range all {
		if _, ok := help[dv.noun]; !ok {
			help[dv.noun] = nounHelpText(t, tree, dv.noun)
		}
		if !mentionsVerb(help[dv.noun], dv.verb) {
			t.Errorf("`bp %s --help` never prints the %s verb %q — the CLI dispatches "+
				"a command its own help says does not exist:\n%s",
				dv.noun, dv.origin, dv.verb, help[dv.noun])
		}
	}
}

// mentionsVerb looks for the verb as a whole word, so `ls` does not match
// inside "tools" and `next` does not match inside "next-generation".
func mentionsVerb(help, verb string) bool {
	re := regexp.MustCompile(`(?m)(^|[^\w-])` + regexp.QuoteMeta(verb) + `($|[^\w-])`)
	return re.MatchString(help)
}

func containsPair(all []dispatchedVerb, noun, verb string) bool {
	for _, dv := range all {
		if dv.noun == noun && dv.verb == verb {
			return true
		}
	}
	return false
}

// TestNounHelpMarksBuiltinsAsBuiltIn pins the "marked as built-in" half of the
// criterion: a reader must be able to tell a client-side verb from a manifest
// one, because only the manifest half is what a server-side capabilities read
// will ever show them.
func TestNounHelpMarksBuiltinsAsBuiltIn(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)
	out := nounHelpText(t, tree, "task")

	if !strings.Contains(out, "built-ins (CLI-native") {
		t.Errorf("`bp task --help` does not label its built-ins block:\n%s", out)
	}
	// The label must come AFTER the manifest verbs, so the block reads as an
	// addition to them rather than replacing them.
	iVerbs := strings.Index(out, "verbs:")
	iBuiltins := strings.Index(out, "built-ins (CLI-native")
	if iVerbs < 0 || iBuiltins < iVerbs {
		t.Errorf("built-ins block is not rendered next to (below) the manifest verbs:\n%s", out)
	}
	// And the manifest verbs must still all be there — the block is additive.
	for _, want := range []string{"claim", "close", "ready", "stamp"} {
		if !mentionsVerb(out, want) {
			t.Errorf("manifest verb %q disappeared from `bp task --help`:\n%s", want, out)
		}
	}
}

// TestDispatchedVerbLiteralsAreRegisteredOrManifest is the anti-drift guard
// that keeps the registry honest: it re-derives the verb intercepts from
// cli.go's SOURCE and requires each to be either a registered built-in (so the
// help block prints it) or a real manifest verb of that noun (so the manifest
// block prints it). A future hand-written `if verb == "foo"` intercept for a
// verb the manifest does not declare fails here — which is precisely how
// `task create` went invisible. There is no exemption list; both branches are
// self-justifying, so this guard cannot be widened into a rubber stamp.
func TestDispatchedVerbLiteralsAreRegisteredOrManifest(t *testing.T) {
	src, err := os.ReadFile("cli.go")
	if err != nil {
		t.Fatalf("read cli.go: %v", err)
	}
	_, tree := loadTreeFrom(t, fullManifest)

	caseLine := regexp.MustCompile(`^\s*case\s+"([^"]+)"\s*:`)
	nounGuard := regexp.MustCompile(`noun\s*==\s*"([^"]+)"`)
	verbLit := regexp.MustCompile(`verb\s*==\s*"([^"]*)"`)

	registered := map[string]bool{}
	for _, b := range nounBuiltins {
		registered[b.Noun+" "+b.Verb] = true
	}

	var pairs []string
	curNoun := ""
	for _, line := range strings.Split(string(src), "\n") {
		// Read CODE, not prose: this file's own comments talk ABOUT verb
		// intercepts, and a doc line quoting one is not a dispatch.
		if strings.HasPrefix(strings.TrimSpace(line), "//") {
			continue
		}
		if m := caseLine.FindStringSubmatch(line); m != nil {
			curNoun = m[1]
		}
		for _, vm := range verbLit.FindAllStringSubmatch(line, -1) {
			verb := vm[1]
			if verb == "" {
				continue // `verb == ""` is the bare-noun branch, not an intercept
			}
			noun := curNoun
			if nm := nounGuard.FindStringSubmatch(line); nm != nil {
				noun = nm[1]
			}
			pairs = append(pairs, noun+" "+verb)
		}
	}

	// Non-vacuity: if the switch shape or the regexes stop matching, fail loudly
	// rather than assert nothing. `task ready` is a manifest-verb intercept that
	// has been in cli.go since the frontier header shipped.
	if len(pairs) < 4 {
		t.Fatalf("found only %d verb literal(s) in cli.go's dispatch (%v) — the "+
			"switch shape or the regex changed; fix this guard before trusting it", len(pairs), pairs)
	}
	if !contains(pairs, "task ready") {
		t.Fatalf("guard did not find the known `task ready` intercept in cli.go; "+
			"extracted %v — the scan is not reading the dispatch", pairs)
	}

	var orphans []string
	for _, p := range pairs {
		if registered[p] {
			continue
		}
		parts := strings.SplitN(p, " ", 2)
		if _, ok := tree.Lookup(parts[0], parts[1]); ok {
			continue // a manifest verb — its noun's help lists it from the manifest
		}
		orphans = append(orphans, p)
	}
	if len(orphans) > 0 {
		sort.Strings(orphans)
		t.Errorf("cli.go intercepts %v, which is neither a registered nounBuiltin "+
			"nor a manifest verb — the CLI would dispatch a verb no help prints. "+
			"Register it in noun_builtins.go instead of hand-writing the intercept.", orphans)
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

// TestBuiltinDispatchHonoursGate pins the one gated entry: `task next` is a
// REAL manifest verb, so the built-in must fire only with --frontier and stay
// out of the way otherwise.
func TestBuiltinDispatchHonoursGate(t *testing.T) {
	if _, ok := lookupNounBuiltin("task", "next", globals{}, []string{"w13"}); ok {
		t.Error("a bare `task next <worker>` must fall through to the manifest claim endpoint")
	}
	if _, ok := lookupNounBuiltin("task", "next", globals{}, []string{"w13", "--frontier"}); !ok {
		t.Error("`task next --frontier` must dispatch the frontier-aware built-in")
	}
	if _, ok := lookupNounBuiltin("task", "", globals{}, nil); ok {
		t.Error("an empty verb must never match a built-in (that is the bare-noun help path)")
	}
	if _, ok := lookupNounBuiltin("doc", "create", globals{}, nil); ok {
		t.Error("`doc create` is a manifest verb and must not be shadowed by the registry")
	}
}

// TestCapabilitiesNamesBuiltins is the criterion-3 gate: the manifest is not
// the whole command surface, and `bp capabilities` must say so. Human output
// carries the separate section; machine output carries the same fact as one
// STDERR line, leaving stdout byte-identical for every script and every brief
// parser (the manifest contract stays additive — no new key, no server change).
func TestCapabilitiesNamesBuiltins(t *testing.T) {
	line := builtinPointerLine()
	for _, want := range []string{"bp task create", "bp <noun> --help", "NOT in this manifest"} {
		if !strings.Contains(line, want) {
			t.Errorf("capabilities pointer line is missing %q: %q", want, line)
		}
	}
	if strings.Contains(line, "\n") {
		t.Errorf("the pointer must be ONE line, got:\n%s", line)
	}

	human := strings.Join(builtinCapabilityLines(), "\n")
	if !strings.Contains(human, "NOT declared by this manifest") {
		t.Errorf("capabilities human section does not mark the block as non-manifest:\n%s", human)
	}
	for _, b := range nounBuiltins {
		want := fmt.Sprintf("%-10s %-16s", b.Noun, verbCol(b))
		if !strings.Contains(human, want) {
			t.Errorf("capabilities human section is missing %q:\n%s", strings.TrimSpace(want), human)
		}
	}
}

func verbCol(b nounBuiltin) string {
	if b.GateHint != "" {
		return b.Verb + " " + b.GateHint
	}
	return b.Verb
}
