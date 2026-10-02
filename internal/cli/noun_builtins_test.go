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
		// Both verbs, mirroring cli.go's `bp context` help surface: `pack`
		// pictures the full text of files you name, `map` pictures the shape
		// of an epic you name by keyword.
		printContextPackHelp(w)
		printContextMapHelp(w)
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
// that keeps the registry honest: it re-derives the verb intercepts from the
// SOURCE of every non-test .go file in internal/cli — not cli.go alone, because
// cli.go delegates verb-level dispatch to lookupNounBuiltin one file over — and
// requires each to be either a registered built-in (so the help block prints
// it) or a real manifest verb (so the manifest block prints it). A future
// hand-written `if verb == "foo"` intercept for a verb the manifest does not
// declare fails here — which is precisely how `task create` went invisible.
// There is no exemption list; both branches are self-justifying, so this guard
// cannot be widened into a rubber stamp.
//
// WHICH LITERALS IT JUDGES is a predicate, never a list:
//
//   - A line naming the noun — `noun == "x"` anywhere in the package, or the
//     enclosing `case "x":` in cli.go's dispatch switch — is judged against
//     THAT noun, when x is a manifest noun or a registered built-in's noun.
//   - A literal with no noun on the line is judged only in a file that
//     PARTICIPATES in verb-level built-in dispatch (it names nounBuiltins or
//     lookupNounBuiltin). There the verb must be dispatchable somewhere.
//   - Everything else belongs to a WHOLE-NOUN built-in (`bp scaffy`,
//     `bp cloud hetzner`, …): its noun is not a manifest noun and it renders
//     its own help, so this table's premise does not apply. Those are counted
//     and logged, not silently dropped — run with -v to read the disposition.
func TestDispatchedVerbLiteralsAreRegisteredOrManifest(t *testing.T) {
	files := packageSourceFiles(t)
	_, tree := loadTreeFrom(t, fullManifest)

	caseLine := regexp.MustCompile(`^\s*case\s+"([^"]+)"\s*:`)
	nounGuard := regexp.MustCompile(`noun\s*==\s*"([^"]+)"`)
	// The leading class keeps `r.verb == "x"` (a struct FIELD on some result)
	// out: only the bare dispatch variable `verb` is an intercept.
	verbLit := regexp.MustCompile(`(^|[^\w.])verb\s*==\s*"([^"]*)"`)
	// A file participates in verb-level dispatch if it names the registry or
	// its lookup. cli.go reaches the built-ins through lookupNounBuiltin, and
	// lookupNounBuiltin's own file is where an intercept escapes cli.go.
	dispatchPath := regexp.MustCompile(`nounBuiltins|lookupNounBuiltin`)

	registered := map[string]bool{}
	registeredVerb := map[string]bool{}
	builtinNoun := map[string]bool{}
	for _, b := range nounBuiltins {
		registered[b.Noun+" "+b.Verb] = true
		registeredVerb[b.Verb] = true
		builtinNoun[b.Noun] = true
	}
	manifestNoun := map[string]bool{}
	for _, n := range tree.NounNames() {
		manifestNoun[n] = true
	}

	type site struct {
		where  string // file:line
		noun   string // "" when no noun is on the line (and the file is not cli.go)
		verb   string
		onPath bool // the file participates in verb-level dispatch
	}
	var sites []site
	var pairs []string // cli.go-attributed pairs, for the non-vacuity anchor
	var pathFiles []string
	for _, f := range files {
		onPath := dispatchPath.MatchString(f.body)
		if onPath {
			pathFiles = append(pathFiles, f.name)
		}
		curNoun := ""
		for i, line := range strings.Split(f.body, "\n") {
			// Read CODE, not prose: these files' own comments talk ABOUT verb
			// intercepts, and a doc line quoting one is not a dispatch.
			if strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			if m := caseLine.FindStringSubmatch(line); m != nil {
				curNoun = m[1]
			}
			for _, vm := range verbLit.FindAllStringSubmatch(line, -1) {
				verb := vm[2]
				if verb == "" {
					continue // `verb == ""` is the bare-noun branch, not an intercept
				}
				if strings.HasPrefix(verb, "-") {
					continue // `-h`/`--help` in the verb slot is a FLAG, not a verb
				}
				noun := ""
				if nm := nounGuard.FindStringSubmatch(line); nm != nil {
					noun = nm[1]
				} else if f.name == "cli.go" {
					noun = curNoun
				}
				sites = append(sites, site{
					where:  fmt.Sprintf("%s:%d", f.name, i+1),
					noun:   noun,
					verb:   verb,
					onPath: onPath,
				})
				if f.name == "cli.go" && noun != "" {
					pairs = append(pairs, noun+" "+verb)
				}
			}
		}
	}

	// Non-vacuity: if the switch shape or the regexes stop matching, fail loudly
	// rather than assert nothing. `task ready` is a manifest-verb intercept that
	// has been in cli.go since the frontier header shipped. Both arms are pinned
	// to cli.go so widening the scan cannot satisfy them from elsewhere.
	if len(pairs) < 4 {
		t.Fatalf("found only %d verb literal(s) in cli.go's dispatch (%v) — the "+
			"switch shape or the regex changed; fix this guard before trusting it", len(pairs), pairs)
	}
	if !contains(pairs, "task ready") {
		t.Fatalf("guard did not find the known `task ready` intercept in cli.go; "+
			"extracted %v — the scan is not reading the dispatch", pairs)
	}
	// And the scan must have reached past cli.go into the file cli.go delegates
	// verb dispatch to, or it is the old one-file guard wearing a new name.
	if len(files) < 2 || !contains(pathFiles, "noun_builtins.go") || !contains(pathFiles, "cli.go") {
		t.Fatalf("the dispatch-path file set is %v over %d package file(s) — it must contain "+
			"both cli.go and noun_builtins.go or an intercept one file over stays invisible",
			pathFiles, len(files))
	}

	var orphans, outOfScope []string
	for _, s := range sites {
		switch {
		case s.noun != "" && (manifestNoun[s.noun] || builtinNoun[s.noun]):
			if registered[s.noun+" "+s.verb] {
				continue
			}
			if _, ok := tree.Lookup(s.noun, s.verb); ok {
				continue // a manifest verb — its noun's help lists it from the manifest
			}
			orphans = append(orphans, fmt.Sprintf("%s (%s %s)", s.where, s.noun, s.verb))
		case s.noun != "":
			// A noun this manifest does not declare and no built-in registers:
			// a whole-noun built-in, which renders its own help.
			outOfScope = append(outOfScope, fmt.Sprintf("%s (%s %s: not a manifest noun)", s.where, s.noun, s.verb))
		case s.onPath:
			if registeredVerb[s.verb] || dispatchableUnderSomeNoun(tree, s.verb) {
				continue
			}
			orphans = append(orphans, fmt.Sprintf("%s (%q, no noun on the line, in the dispatch path)", s.where, s.verb))
		default:
			outOfScope = append(outOfScope, fmt.Sprintf("%s (%q: whole-noun built-in, off the verb-dispatch path)", s.where, s.verb))
		}
	}
	sort.Strings(outOfScope)
	t.Logf("scanned %d non-test file(s); %d verb literal(s); dispatch-path files %v; "+
		"%d literal(s) out of this table's scope:\n  %s",
		len(files), len(sites), pathFiles, len(outOfScope), strings.Join(outOfScope, "\n  "))
	if len(orphans) > 0 {
		sort.Strings(orphans)
		t.Errorf("internal/cli intercepts %v, which is neither a registered nounBuiltin "+
			"nor a manifest verb — the CLI would dispatch a verb no help prints. "+
			"Register it in noun_builtins.go instead of hand-writing the intercept.", orphans)
	}
}

// dispatchableUnderSomeNoun reports whether the manifest declares `verb` under
// any noun at all. It is the weaker test applied where the source does not name
// the noun the intercept runs under.
func dispatchableUnderSomeNoun(tree *manifest.Tree, verb string) bool {
	for _, noun := range tree.NounNames() {
		if _, ok := tree.Lookup(noun, verb); ok {
			return true
		}
	}
	return false
}

// packageSource is one non-test .go file of internal/cli, kept SEPARATE (not
// concatenated like readPackageSources) so a finding can cite file:line and so
// per-file `case` state does not bleed across files.
type packageSource struct {
	name string
	body string
}

func packageSourceFiles(t *testing.T) []packageSource {
	t.Helper()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read internal/cli sources: %v", err)
	}
	var out []packageSource
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		body, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		out = append(out, packageSource{name: name, body: string(body)})
	}
	if len(out) == 0 {
		t.Fatal("read internal/cli sources: no non-test .go files found — the scan would pass vacuously")
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out
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
