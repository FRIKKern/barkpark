package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func TestRunCompletionBash(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, globals{}, manifest.Context{}, []string{"bash"}); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%s", code, exitOK, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{"complete -F _bp_complete bp", "compgen", "doc", "schema", "--dataset"} {
		if !strings.Contains(out, want) {
			t.Errorf("bash completion missing %q:\n%s", want, out)
		}
	}
}

func TestRunCompletionZsh(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, globals{}, manifest.Context{}, []string{"zsh"}); code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	out := stdout.String()
	for _, want := range []string{"#compdef bp", "compdef _bp_complete bp", "compadd", "task"} {
		if !strings.Contains(out, want) {
			t.Errorf("zsh completion missing %q:\n%s", want, out)
		}
	}
}

func TestRunCompletionDefaultsToBash(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, globals{}, manifest.Context{}, nil); code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	if !strings.Contains(stdout.String(), "complete -F _bp_complete bp") {
		t.Errorf("no-arg completion should default to bash:\n%s", stdout.String())
	}
}

func TestRunCompletionFish(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, globals{}, manifest.Context{}, []string{"fish"}); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%s", code, exitOK, stderr.String())
	}
	out := stdout.String()
	// The script must register the completion (`complete -c bp`), gate nouns to
	// the subcommand position, offer a known noun + a global, and disable file
	// completion so a bare `bp <TAB>` shows commands not cwd files.
	for _, want := range []string{
		"complete -c bp -f",
		"__fish_use_subcommand",
		"not __fish_use_subcommand",
		"task",
		"--dataset",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("fish completion missing %q:\n%s", want, out)
		}
	}
}

func TestRunCompletionUnknownShell(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	// A genuinely unsupported shell still errors with usage exit. (fish is now
	// supported — see TestRunCompletionFish.)
	if code := runCompletion(w, globals{}, manifest.Context{}, []string{"powershell"}); code != exitUsage {
		t.Errorf("unknown shell exit = %d, want %d (usage)", code, exitUsage)
	}
}

// TestRunCompletionHelp pins the fix for `bp completion --help`: --help must
// print a short usage listing the supported shells, NOT dump the bash
// completion script (which is what happens when g.help is ignored and `shell`
// defaults to "bash").
func TestRunCompletionHelp(t *testing.T) {
	out := captureExecute(t, []string{"completion", "--help"})
	if !strings.Contains(out, "usage: bp completion") {
		t.Errorf("completion --help missing usage line; got:\n%s", out)
	}
	for _, script := range []string{"complete -F", "_bp"} {
		if strings.Contains(out, script) {
			t.Errorf("completion --help leaked the completion script (%q):\n%s", script, out)
		}
	}
}

// TestCompletionNounsCoverAllDispatchedBuiltins is the drift guard for the
// completionNouns invariant: every built-in verb dispatched in cli.go's single
// `switch noun` must be shell-completable. It parses that switch's `case "…":`
// tokens (handling alias cases like `case "attach", "register":` and hyphenated
// verbs like `go-live`) and fails if any is absent from completionNouns — the
// exact drift that had left `listen`, `go-live`, `register`, and `help`
// uncompletable, and that a naive grep for `case "[a-z]+"` silently misses.
func TestCompletionNounsCoverAllDispatchedBuiltins(t *testing.T) {
	src, err := os.ReadFile("cli.go")
	if err != nil {
		t.Fatalf("read cli.go: %v", err)
	}

	// A dispatch case is `case "v"[, "v2"…]:` at line start. Grab the token list,
	// then pull every quoted verb out of it.
	caseLine := regexp.MustCompile(`(?m)^\s*case\s+("[^"]+"(?:\s*,\s*"[^"]+")*)\s*:`)
	tokenRe := regexp.MustCompile(`"([^"]+)"`)

	have := make(map[string]bool, len(completionNouns))
	for _, n := range completionNouns {
		have[n] = true
	}

	seen := map[string]bool{}
	var missing []string
	for _, m := range caseLine.FindAllStringSubmatch(string(src), -1) {
		for _, tok := range tokenRe.FindAllStringSubmatch(m[1], -1) {
			verb := tok[1]
			if seen[verb] {
				continue
			}
			seen[verb] = true
			if !have[verb] {
				missing = append(missing, verb)
			}
		}
	}

	// Guard against a vacuous pass: if the switch/regex ever stops matching, the
	// test must fail loudly rather than silently assert nothing.
	if len(seen) == 0 {
		t.Fatal("no dispatch `case \"…\":` lines found in cli.go — the switch " +
			"structure or the regex changed; fix this guard before trusting it")
	}

	if len(missing) > 0 {
		sort.Strings(missing)
		t.Errorf("completionNouns is missing dispatched built-in verb(s) %v — add "+
			"them to builtins.go so `bp <TAB>` offers every command", missing)
	}
}

// completionNounList must union the baked built-ins with the cache's manifest
// nouns, so a server-specific / plugin noun completes at position 1 without a
// code edit — the same way its verbs already come from the cache. It must also
// stay sorted+deduped, and degrade to exactly the baked floor with no cache.
func TestCompletionNounListUnionsManifestNouns(t *testing.T) {
	// No cache → exactly the baked floor, sorted.
	baked := completionNounList(nil)
	wantFloor := append([]string(nil), completionNouns...)
	sort.Strings(wantFloor)
	if baked != strings.Join(wantFloor, " ") {
		t.Errorf("no-cache noun list = %q; want the sorted baked floor %q", baked, strings.Join(wantFloor, " "))
	}

	// With a cache carrying a manifest-only noun (`graph`) and a dup of a baked
	// noun (`doc`), the union adds `graph`, keeps `doc` once, and stays sorted.
	got := completionNounList(map[string][]string{
		"graph": {"neighbors"},
		"doc":   {"ls", "get"},
	})
	fields := strings.Fields(got)
	if !slicesContains(fields, "graph") {
		t.Errorf("union noun list %q is missing the manifest-only noun 'graph'", got)
	}
	if countOccurrences(fields, "doc") != 1 {
		t.Errorf("union noun list %q must contain 'doc' exactly once (no dup)", got)
	}
	if !sort.StringsAreSorted(fields) {
		t.Errorf("union noun list %q is not sorted", got)
	}
}

func slicesContains(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}

func countOccurrences(xs []string, want string) int {
	n := 0
	for _, x := range xs {
		if x == want {
			n++
		}
	}
	return n
}

// TestCompletionGlobalsCoverAllGlobalFlags is the drift guard for the
// completionGlobals invariant: every global flag the parser recognises
// (globals.go's valueFlags + boolFlags) must be shell-completable after `-`.
// It failed the old list that missed `-h`/`--help`, `--version`/`-V`, and
// `--json`, and that carried a stray `--file` (a per-command manifest flag, not
// a global) — the exact drift a hand-maintained slice invites.
func TestCompletionGlobalsCoverAllGlobalFlags(t *testing.T) {
	have := make(map[string]bool, len(completionGlobals))
	for _, f := range completionGlobals {
		have[f] = true
	}

	var missing []string
	for flag := range valueFlags {
		if !have[flag] {
			missing = append(missing, flag)
		}
	}
	for flag := range boolFlags {
		if !have[flag] {
			missing = append(missing, flag)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		t.Errorf("completionGlobals is missing recognised global flag(s) %v — add "+
			"them to builtins.go so `bp -<TAB>` offers every global", missing)
	}
}

// --- verb completion (bp <noun> <TAB> → the noun's verbs) --------------------

// sampleVerbMap / sampleFlagMap are fixed maps used by the completion-structure
// tests so they don't depend on a real on-disk manifest cache.
var sampleVerbMap = map[string][]string{
	"task": {"close", "next", "ready"},
	"doc":  {"create", "delete", "get"},
}

var sampleFlagMap = map[string][]string{
	"doc create": {"--publish", "--set"},
	"task close": {"--epoch"},
}

func TestBashCompletionVerbsStructural(t *testing.T) {
	script := bashCompletionScript("task doc", "--dataset", sampleVerbMap, sampleFlagMap)
	for _, want := range []string{
		`case "${COMP_WORDS[1]}" in`,
		`task) __bpverbs="close next ready";;`,
		`doc) __bpverbs="create delete get";;`,
		`compgen -W "$__bpverbs $globals"`,
		// position-3+ flag completion keyed on the "noun verb" pair
		`case "${COMP_WORDS[1]} ${COMP_WORDS[2]}" in`,
		`"doc create") __bpflags="--publish --set";;`,
		`compgen -W "$__bpflags $globals"`,
	} {
		if !strings.Contains(script, want) {
			t.Errorf("bash script missing %q:\n%s", want, script)
		}
	}
}

func TestZshCompletionVerbsStructural(t *testing.T) {
	script := zshCompletionScript("task doc", "--dataset", sampleVerbMap, sampleFlagMap)
	for _, want := range []string{
		`case "${words[2]}" in`,
		`task) verbs=(close next ready);;`,
		`compadd -- $verbs $globals`,
		`case "${words[2]} ${words[3]}" in`,
		`"doc create") flags=(--publish --set);;`,
		`compadd -- $flags $globals`,
	} {
		if !strings.Contains(script, want) {
			t.Errorf("zsh script missing %q:\n%s", want, script)
		}
	}
}

func TestFishCompletionVerbsStructural(t *testing.T) {
	script := fishCompletionScript("task doc", "--dataset", sampleVerbMap, sampleFlagMap)
	for _, want := range []string{
		`complete -c bp -n '__fish_seen_subcommand_from task' -a 'close next ready'`,
		`complete -c bp -n '__fish_seen_subcommand_from doc' -a 'create delete get'`,
		// a flag completes only under BOTH its noun and verb
		`complete -c bp -n '__fish_seen_subcommand_from doc; and __fish_seen_subcommand_from create' -a '--publish --set'`,
	} {
		if !strings.Contains(script, want) {
			t.Errorf("fish script missing %q:\n%s", want, script)
		}
	}
}

// TestBashCompletionVerbExec is the correctness proof: it runs the generated
// script through a REAL bash (3.2 on macOS — no associative arrays), simulates
// `bp task <TAB>`, and checks COMPREPLY actually contains the verbs. Structural
// string checks can't catch a script that parses wrong; this does.
func TestBashCompletionVerbExec(t *testing.T) {
	bashPath, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}

	run := func(t *testing.T, verbMap, flagMap map[string][]string, word string, cword int) string {
		t.Helper()
		script := bashCompletionScript(strings.Join(completionNouns, " "),
			strings.Join(completionGlobals, " "), verbMap, flagMap)
		harness := script + "\nCOMP_WORDS=(bp " + word + " '')\nCOMP_CWORD=" +
			strconv.Itoa(cword) + "\n_bp_complete\nprintf '%s\\n' \"${COMPREPLY[@]}\"\n"
		outb, err := exec.Command(bashPath, "-c", harness).CombinedOutput()
		if err != nil {
			t.Fatalf("bash exec failed: %v\n--- script+harness ---\n%s\n--- output ---\n%s",
				err, harness, outb)
		}
		return string(outb)
	}

	// `bp task <TAB>` must offer the task verbs.
	out := run(t, sampleVerbMap, sampleFlagMap, "task", 2)
	for _, verb := range []string{"close", "next", "ready"} {
		if !strings.Contains(out, verb) {
			t.Errorf("bp task <TAB> did not offer %q; COMPREPLY:\n%s", verb, out)
		}
	}

	// `bp doc create --<TAB>` must offer that command's OWN flags — the real proof
	// the position-3+ `case "${COMP_WORDS[1]} ${COMP_WORDS[2]}"` parses and matches.
	outFlags := run(t, sampleVerbMap, sampleFlagMap, "doc create", 3)
	for _, flag := range []string{"--publish", "--set"} {
		if !strings.Contains(outFlags, flag) {
			t.Errorf("bp doc create <TAB> did not offer %q; COMPREPLY:\n%s", flag, outFlags)
		}
	}

	// Empty maps (no cache): the generated script must still be VALID bash and
	// simply fall back to globals — proves the empty `case … *) ;; esac` blocks
	// parse at BOTH the verb (pos 2) and flag (pos 3) positions.
	outEmpty := run(t, nil, nil, "task", 2)
	if !strings.Contains(outEmpty, "--dataset") {
		t.Errorf("empty-verbMap position-2 should offer globals; COMPREPLY:\n%s", outEmpty)
	}
	outEmptyFlags := run(t, nil, nil, "doc create", 3)
	if !strings.Contains(outEmptyFlags, "--dataset") {
		t.Errorf("empty-flagMap position-3 should offer globals; COMPREPLY:\n%s", outEmptyFlags)
	}
}

// unreachableWhoamiServer stands up a server that 404s everything, so whoami's
// best-effort manifest + /v1/meta fetches both fail fast (reachable=false) and
// the command exercises only its local-first, config-driven output — no real
// backend needed.
func unreachableWhoamiServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestWhoamiCloudBlockLoggedIn: with a Cloud session on disk, whoami's json
// payload carries a cloud block (logged_in/url/team) and NEVER the token value.
func TestWhoamiCloudBlockLoggedIn(t *testing.T) {
	withTempConfigHome(t)
	if err := SaveConfig(&Config{
		CloudURL:   "https://api.barkpark.cloud",
		CloudToken: "sess-secret-must-not-leak",
		CloudTeam:  "team-abc",
	}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	srv := unreachableWhoamiServer(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if code := runWhoami(w, globals{}, manifest.Context{Server: srv.URL}); code != exitOK {
		t.Fatalf("runWhoami exit = %d\n%s", code, stderr.String())
	}

	var payload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("parse json: %v\n%s", err, stdout.String())
	}
	cloud, ok := payload["cloud"].(map[string]any)
	if !ok {
		t.Fatalf("whoami json missing a cloud block:\n%s", stdout.String())
	}
	if cloud["logged_in"] != true {
		t.Errorf("cloud.logged_in = %v, want true", cloud["logged_in"])
	}
	if cloud["url"] != "https://api.barkpark.cloud" {
		t.Errorf("cloud.url = %v", cloud["url"])
	}
	if cloud["team"] != "team-abc" {
		t.Errorf("cloud.team = %v", cloud["team"])
	}
	// The token value must NEVER appear anywhere in the output.
	if strings.Contains(stdout.String(), "sess-secret-must-not-leak") {
		t.Fatalf("whoami leaked the cloud token:\n%s", stdout.String())
	}
}

// TestWhoamiCloudBlockLoggedOut: with no Cloud session, whoami's human output
// surfaces the "not logged in — run 'bp login'" hint and json reports
// logged_in:false.
func TestWhoamiCloudBlockLoggedOut(t *testing.T) {
	withTempConfigHome(t)
	srv := unreachableWhoamiServer(t)

	// Human mode: the hint must appear.
	var hOut, hErr bytes.Buffer
	hw := newWriter(&hOut, &hErr)
	hw.output = "table"
	if code := runWhoami(hw, globals{}, manifest.Context{Server: srv.URL}); code != exitOK {
		t.Fatalf("runWhoami (human) exit = %d\n%s", code, hErr.String())
	}
	if !strings.Contains(hOut.String(), "not logged in") {
		t.Fatalf("expected a 'not logged in' hint:\n%s", hOut.String())
	}

	// JSON mode: logged_in must be false.
	var jOut, jErr bytes.Buffer
	jw := newWriter(&jOut, &jErr)
	jw.output = "json"
	if code := runWhoami(jw, globals{}, manifest.Context{Server: srv.URL}); code != exitOK {
		t.Fatalf("runWhoami (json) exit = %d\n%s", code, jErr.String())
	}
	var payload map[string]any
	if err := json.Unmarshal(jOut.Bytes(), &payload); err != nil {
		t.Fatalf("parse json: %v\n%s", err, jOut.String())
	}
	cloud, ok := payload["cloud"].(map[string]any)
	if !ok {
		t.Fatalf("whoami json missing a cloud block:\n%s", jOut.String())
	}
	if cloud["logged_in"] != false {
		t.Errorf("cloud.logged_in = %v, want false", cloud["logged_in"])
	}
}
