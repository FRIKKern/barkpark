package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// completion_builtins_test.go — the invariant that keeps builtinCompletionPaths
// honest, plus the behaviour tests that prove `bp cloud site <TAB>` and
// `bp cloud site deploy --<TAB>` actually offer something.
//
// TestCompletionNounsCoverAllDispatchedBuiltins (builtins_test.go) is the
// sibling one level up: it gates NOUNS against cli.go's switch. These gate the
// VERBS and FLAGS of the control-plane tree, which no manifest describes.

// packageFuncBodies reads every non-test .go file in the package and returns
// funcName -> body source. A function body runs from its `func name(` line to
// the next line starting with `func ` at column 0 (gofmt guarantees that
// shape), which is enough to scan a dispatch switch or a parseHzArgs call.
func packageFuncBodies(t *testing.T) map[string]string {
	t.Helper()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}
	funcRe := regexp.MustCompile(`(?m)^func (?:\([^)]*\) )?([A-Za-z0-9_]+)\(`)
	bodies := map[string]string{}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || filepath.Ext(name) != ".go" || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		s := string(src)
		locs := funcRe.FindAllStringSubmatchIndex(s, -1)
		for i, loc := range locs {
			end := len(s)
			if i+1 < len(locs) {
				end = locs[i+1][0]
			}
			bodies[s[loc[2]:loc[3]]] = s[loc[0]:end]
		}
	}
	if len(bodies) == 0 {
		t.Fatal("no function bodies parsed from the package — the scanner is broken; fix it before trusting this guard")
	}
	return bodies
}

var caseTokensRe = regexp.MustCompile(`(?m)^\s*case\s+("[^"]+"(?:\s*,\s*"[^"]+")*)\s*:`)
var quotedRe = regexp.MustCompile(`"([^"]+)"`)

// dispatchCaseVerbs returns every quoted token of every `case "…":` in body.
func dispatchCaseVerbs(body string) []string {
	var verbs []string
	for _, m := range caseTokensRe.FindAllStringSubmatch(body, -1) {
		for _, tok := range quotedRe.FindAllStringSubmatch(m[1], -1) {
			verbs = append(verbs, tok[1])
		}
	}
	return dedupeSorted(verbs)
}

// dispatchCaseHandlers maps each case token to the run* function the case body
// returns, e.g. "deploy" -> "runCloudSiteDeploy".
func dispatchCaseHandlers(body string) map[string]string {
	callRe := regexp.MustCompile(`return (run[A-Za-z0-9_]+)\(`)
	out := map[string]string{}
	locs := caseTokensRe.FindAllStringSubmatchIndex(body, -1)
	for i, loc := range locs {
		end := len(body)
		if i+1 < len(locs) {
			end = locs[i+1][0]
		}
		block := body[loc[1]:end]
		m := callRe.FindStringSubmatch(block)
		if m == nil {
			continue
		}
		for _, tok := range quotedRe.FindAllStringSubmatch(body[loc[2]:loc[3]], -1) {
			out[tok[1]] = m[1]
		}
	}
	return out
}

// parseHzArgsFlags pulls the declared flag names out of a handler's
// `parseHzArgs(args, []string{…}, []string{…}, usage)` call — the CLI's own
// single declaration of which flags a builtin verb accepts. Returns nil when
// the handler declares none (or does not use parseHzArgs at all).
func parseHzArgsFlags(body string) []string {
	callRe := regexp.MustCompile(`parseHzArgs\(\s*args\s*,\s*((?:nil|\[\]string\{[^}]*\}))\s*,\s*((?:nil|\[\]string\{[^}]*\}))\s*,`)
	m := callRe.FindStringSubmatch(body)
	if m == nil {
		return nil
	}
	var flags []string
	for _, group := range m[1:3] {
		for _, tok := range quotedRe.FindAllStringSubmatch(group, -1) {
			flags = append(flags, "--"+tok[1])
		}
	}
	return dedupeSorted(flags)
}

func missingFrom(have []string, want []string) []string {
	set := map[string]bool{}
	for _, h := range have {
		set[h] = true
	}
	var missing []string
	for _, w := range want {
		if !set[w] {
			missing = append(missing, w)
		}
	}
	sort.Strings(missing)
	return missing
}

// TestBuiltinCompletionPathsCoverDispatchedCloudTree is the drift guard the row
// asked for: a NEW builtin verb or flag that reaches no completion source reds
// here. It reads the truth out of the SOURCE (the dispatch switches and the
// parseHzArgs declarations), never out of a hand-kept list, so the only way to
// go green is to register the token in builtinCompletionPaths.
func TestBuiltinCompletionPathsCoverDispatchedCloudTree(t *testing.T) {
	bodies := packageFuncBodies(t)

	// 1. `bp cloud <TAB>` — every subcommand runCloud dispatches.
	cloudBody, ok := bodies["runCloud"]
	if !ok {
		t.Fatal("runCloud not found — the scanner or the dispatcher moved; fix this guard")
	}
	cloudVerbs := dispatchCaseVerbs(cloudBody)
	if len(cloudVerbs) < 10 {
		t.Fatalf("only %d cases parsed out of runCloud (%v) — the switch shape changed; "+
			"fix this guard before trusting it", len(cloudVerbs), cloudVerbs)
	}
	if missing := missingFrom(builtinPathCandidates("cloud"), cloudVerbs); len(missing) > 0 {
		t.Errorf("builtinCompletionPaths[\"cloud\"] is missing dispatched subcommand(s) %v — "+
			"add them in completion_builtins.go so `bp cloud <TAB>` offers every command", missing)
	}

	// 2. `bp cloud site <TAB>` — every verb runCloudSite dispatches, under BOTH
	//    dispatcher spellings (`site` and the `sites` alias).
	siteBody, ok := bodies["runCloudSite"]
	if !ok {
		t.Fatal("runCloudSite not found — the scanner or the dispatcher moved; fix this guard")
	}
	siteVerbs := dispatchCaseVerbs(siteBody)
	if len(siteVerbs) < 5 {
		t.Fatalf("only %d cases parsed out of runCloudSite (%v) — the switch shape changed; "+
			"fix this guard before trusting it", len(siteVerbs), siteVerbs)
	}
	for _, prefix := range []string{"cloud site", "cloud sites"} {
		if missing := missingFrom(builtinPathCandidates(prefix), siteVerbs); len(missing) > 0 {
			t.Errorf("builtinCompletionPaths[%q] is missing dispatched verb(s) %v — "+
				"add them so `bp %s <TAB>` offers every verb", prefix, missing, prefix)
		}
	}

	// 3. `bp cloud site <verb> --<TAB>` — every flag the verb's handler declares
	//    through parseHzArgs. This is the half that made --prebuilt invisible.
	handlers := dispatchCaseHandlers(siteBody)
	if len(handlers) < 5 {
		t.Fatalf("only %d case->handler pairs parsed out of runCloudSite — the switch "+
			"shape changed; fix this guard before trusting it", len(handlers))
	}
	sawAnyFlag := false
	for _, verb := range siteVerbs {
		handler, ok := handlers[verb]
		if !ok {
			continue
		}
		body, ok := bodies[handler]
		if !ok {
			t.Errorf("runCloudSite dispatches %q to %s, which the scanner did not find", verb, handler)
			continue
		}
		flags := parseHzArgsFlags(body)
		if len(flags) == 0 {
			continue
		}
		sawAnyFlag = true
		prefix := "cloud site " + verb
		if missing := missingFrom(builtinPathCandidates(prefix), flags); len(missing) > 0 {
			t.Errorf("builtinCompletionPaths[%q] is missing flag(s) %v declared by %s — "+
				"add them so `bp %s --<TAB>` offers them", prefix, missing, handler, prefix)
		}
	}
	if !sawAnyFlag {
		t.Fatal("no parseHzArgs flag declaration parsed out of any cloud site handler — " +
			"the call shape changed; fix this guard before trusting it")
	}
}

// TestBuiltinNounVerbsCoverTheRegistry proves the verb-level built-ins
// (`bp task create`, `bp context pack`, …) all reach completion from the ONE
// registry Execute dispatches from — no second hand list to drift.
func TestBuiltinNounVerbsCoverTheRegistry(t *testing.T) {
	if len(nounBuiltins) == 0 {
		t.Fatal("nounBuiltins is empty — nothing to assert; fix this guard")
	}
	merged := mergeBuiltinVerbs(nil)
	for _, b := range nounBuiltins {
		if len(missingFrom(merged[b.Noun], []string{b.Verb})) > 0 {
			t.Errorf("built-in `bp %s %s` is registered in nounBuiltins but not completable "+
				"— mergeBuiltinVerbs(%q) = %v", b.Noun, b.Verb, b.Noun, merged[b.Noun])
		}
	}
}

// TestBuiltinPathCandidatesQuietArm is the other half of the invariant: an
// unregistered prefix must offer NOTHING, so a green above is not the result of
// a table that answers every question. Also pins that a one-word prefix is
// served by the position-2 verb map, never duplicated into the path map.
func TestBuiltinPathCandidatesQuietArm(t *testing.T) {
	for _, prefix := range []string{
		"cloud site frobnicate", "doc create", "", "site", "cloud site deploy extra",
	} {
		if got := builtinPathCandidates(prefix); len(got) > 0 {
			t.Errorf("builtinPathCandidates(%q) = %v; want nothing — an unregistered "+
				"prefix must not complete", prefix, got)
		}
	}
	pm := builtinPathMap()
	for key := range pm {
		if !strings.Contains(key, " ") {
			t.Errorf("builtinPathMap carries the one-word key %q — one-word prefixes "+
				"belong in the position-2 verb map (mergeBuiltinVerbs), not here", key)
		}
	}
	if _, ok := pm["cloud site deploy"]; !ok {
		t.Fatal("builtinPathMap lost `cloud site deploy` — the quiet arm is now vacuous")
	}
}

// TestCompletionScriptsCarryBuiltinTree asserts the EMITTED scripts — all three
// shells — carry the cloud tree. This is what makes `bp cloud site <TAB>` and
// `bp cloud site deploy --<TAB>` real rather than a table nobody reads.
func TestCompletionScriptsCarryBuiltinTree(t *testing.T) {
	nouns := completionNounList(mergeBuiltinVerbs(nil))
	globals := strings.Join(completionGlobals, " ")
	verbMap := mergeBuiltinVerbs(nil)

	scripts := map[string]string{
		"bash": bashCompletionScript(nouns, globals, verbMap, nil),
		"zsh":  zshCompletionScript(nouns, globals, verbMap, nil),
		"fish": fishCompletionScript(nouns, globals, verbMap, nil),
	}
	for shell, script := range scripts {
		for _, want := range []string{"cloud site", "--prebuilt", "doctor", "preflight"} {
			if !strings.Contains(script, want) {
				t.Errorf("%s completion script does not carry %q:\n%s", shell, want, script)
			}
		}
		// The quiet arm: a verb nobody dispatches must not appear.
		if strings.Contains(script, "frobnicate") {
			t.Errorf("%s completion script offers an unregistered token", shell)
		}
	}
	// `bp cloud <TAB>` rides the position-2 verb map, so `site` must be in it.
	if len(missingFrom(verbMap["cloud"], []string{"site", "status", "deploy"})) > 0 {
		t.Errorf("verb map for `cloud` = %v; want the control-plane subcommands", verbMap["cloud"])
	}
}

// TestBashCompletionOffersCloudSiteVerbsLive RUNS the emitted bash script and
// drives _bp_complete the way the shell does — COMP_WORDS/COMP_CWORD in,
// COMPREPLY out. A structural assertion proves the case arm was WRITTEN; this
// proves it FIRES, which is the difference between present-in-file and works.
func TestBashCompletionOffersCloudSiteVerbsLive(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash on PATH")
	}
	script := bashCompletionScript(completionNounList(mergeBuiltinVerbs(nil)),
		strings.Join(completionGlobals, " "), mergeBuiltinVerbs(nil), nil)

	run := func(t *testing.T, words []string, cword int) []string {
		t.Helper()
		var arr strings.Builder
		for _, w := range words {
			arr.WriteString("'" + w + "' ")
		}
		driver := script + "\nCOMP_WORDS=(" + arr.String() + ")\nCOMP_CWORD=" +
			strconv.Itoa(cword) + "\n_bp_complete\nprintf '%s\\n' \"${COMPREPLY[@]}\"\n"
		out, err := exec.Command(bash, "-c", driver).CombinedOutput()
		if err != nil {
			t.Fatalf("bash driver failed: %v\n%s", err, out)
		}
		return strings.Fields(string(out))
	}

	// `bp cloud site <TAB>` — the row's headline case.
	got := run(t, []string{"bp", "cloud", "site", ""}, 3)
	if missing := missingFrom(got, []string{"create", "deploy", "rollback", "status", "doctor"}); len(missing) > 0 {
		t.Errorf("`bp cloud site <TAB>` offered %v; missing %v", got, missing)
	}

	// `bp cloud site deploy --<TAB>` — the flag the row names.
	got = run(t, []string{"bp", "cloud", "site", "deploy", "--"}, 4)
	if missing := missingFrom(got, []string{"--prebuilt", "--no-follow", "--wait-for-live"}); len(missing) > 0 {
		t.Errorf("`bp cloud site deploy --<TAB>` offered %v; missing %v", got, missing)
	}

	// `bp cloud <TAB>` — position 2, through the verb map.
	got = run(t, []string{"bp", "cloud", ""}, 2)
	if missing := missingFrom(got, []string{"site", "status", "instance"}); len(missing) > 0 {
		t.Errorf("`bp cloud <TAB>` offered %v; missing %v", got, missing)
	}

	// QUIET ARM: an unregistered path completes nothing but the globals — a
	// green above must not come from a script that offers everything everywhere.
	got = run(t, []string{"bp", "cloud", "site", "deploy", "x", "--pre"}, 5)
	for _, tok := range got {
		if tok == "--prebuilt" {
			continue // the path still applies at deeper positions, by design
		}
		if !strings.HasPrefix(tok, "--pre") {
			t.Errorf("`--pre<TAB>` offered %q, which does not match the typed prefix", tok)
		}
	}
	got = run(t, []string{"bp", "frobnicate", "site", ""}, 3)
	if len(missingFrom(got, []string{"create"})) == 0 {
		t.Errorf("`bp frobnicate site <TAB>` offered the cloud site verbs (%v) — the "+
			"path case is matching a prefix it should not", got)
	}
}
