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
		// position-3+ flag completion keyed on the "noun verb" pair. Flag tokens
		// are untrusted, so they are single-quoted at assignment and matched
		// manually — never handed to compgen -W, which would re-expand them.
		`case "${COMP_WORDS[1]} ${COMP_WORDS[2]}" in`,
		`"doc create") __bpflags='--publish --set';;`,
		`for __bpword in $__bpflags $globals; do`,
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
		// flag tokens are untrusted → each element single-quoted in the array
		// literal (zsh command-substitutes an unquoted `flags=(...)` on assignment).
		`"doc create") flags=('--publish' '--set');;`,
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

// TestBashCompletionFlagInjectionNeutralized is the mutation-proof for the flag
// path: it plants a HOSTILE flag name carrying a `$(...)` command substitution
// (the shape a poisoned manifest cache would deliver, since manifest.Parse's
// safeName never validates Flag.Name), generates the bash script, and drives a
// REAL bash to `bp doc create --<TAB>`. If the emitter fails to single-quote the
// token, the case-body assignment (or a compgen -W re-expansion) runs the payload
// and the sentinel file appears. The assertion is on the sentinel's ABSENCE and
// on the raw payload bytes SURVIVING as a literal completion candidate — a correct
// single-quote fix preserves the `$(...)` bytes while neutralizing them, so this
// is deliberately NOT "the payload bytes are gone".
func TestBashCompletionFlagInjectionNeutralized(t *testing.T) {
	bashPath, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	dir := t.TempDir()
	// `$(>pwned)` truncates/creates ./pwned via a bare redirection — a side effect
	// with NO space, so the neutralized token also survives as ONE literal
	// candidate (a spaced payload would word-split and muddy the second assertion).
	payload := "--x$(>pwned)"
	flagMap := map[string][]string{"doc create": {payload}}
	script := bashCompletionScript(strings.Join(completionNouns, " "),
		strings.Join(completionGlobals, " "), sampleVerbMap, flagMap)
	harness := script + "\nCOMP_WORDS=(bp doc create '')\nCOMP_CWORD=3\n" +
		"_bp_complete\nprintf '%s\\n' \"${COMPREPLY[@]}\"\n"
	cmd := exec.Command(bashPath, "-c", harness)
	cmd.Dir = dir
	outb, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bash exec failed: %v\n--- harness ---\n%s\n--- output ---\n%s", err, harness, outb)
	}
	if _, statErr := os.Stat(dir + "/pwned"); statErr == nil {
		t.Fatalf("INJECTION: hostile flag %q executed on TAB — sentinel ./pwned was created;\nscript:\n%s", payload, script)
	}
	// The literal payload bytes must survive as a neutralized candidate (proves the
	// completion ran and offered the token, not that it was silently dropped).
	if !strings.Contains(string(outb), payload) {
		t.Errorf("expected neutralized literal %q among candidates; COMPREPLY:\n%s", payload, outb)
	}
}

// TestZshCompletionFlagInjectionQuoted proves the zsh emitter wraps a hostile flag
// token in single quotes INSIDE the `flags=(...)` array literal, so zsh's
// assignment-time command substitution can never fire. Structural assertion (the
// quote wrapping), not a payload-absence substring check.
func TestZshCompletionFlagInjectionQuoted(t *testing.T) {
	payload := "--x$(touch pwned)"
	flagMap := map[string][]string{"doc create": {payload}}
	script := zshCompletionScript("doc", "--dataset", sampleVerbMap, flagMap)
	want := `flags=('--x$(touch pwned)')`
	if !strings.Contains(script, want) {
		t.Errorf("zsh emitter did not single-quote hostile flag token; want %q in:\n%s", want, script)
	}
	// An embedded single quote must be escaped via the '\'' splice, not left bare.
	q := map[string][]string{"doc create": {"--a'b"}}
	s2 := zshCompletionScript("doc", "--dataset", sampleVerbMap, q)
	if !strings.Contains(s2, `flags=('--a'\''b')`) {
		t.Errorf("zsh emitter did not escape embedded single quote; got:\n%s", s2)
	}
}

// TestFishCompletionFlagInjectionQuoted proves the fish emitter escapes `'` and
// `\` inside the single-quoted `-a '...'` list, so a hostile token cannot break
// out of the quote. fish single quotes make `$`/`(...)` literal, so those need no
// escaping and are asserted to survive verbatim (neutralized), not to be removed.
func TestFishCompletionFlagInjectionQuoted(t *testing.T) {
	// `$(...)` is inert inside fish single quotes → preserved literally.
	flagMap := map[string][]string{"doc create": {"--x$(touch pwned)"}}
	script := fishCompletionScript("doc", "--dataset", sampleVerbMap, flagMap)
	if !strings.Contains(script, `-a '--x$(touch pwned)'`) {
		t.Errorf("fish emitter mangled inert token; got:\n%s", script)
	}
	// An embedded single quote must become \' so it cannot terminate the -a string.
	q := map[string][]string{"doc create": {`--a'b`, `--c\d`}}
	s2 := fishCompletionScript("doc", "--dataset", sampleVerbMap, q)
	if !strings.Contains(s2, `-a '--a\'b --c\\d'`) {
		t.Errorf("fish emitter did not escape ' and \\; got:\n%s", s2)
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

// whoamiCloudPayload runs `bp whoami -o json` and returns its cloud block.
func whoamiCloudPayload(t *testing.T, contentServer string) (map[string]any, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if code := runWhoami(w, globals{}, manifest.Context{Server: contentServer}, tokenProvenance{}); code != exitOK {
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
	return cloud, stdout.String()
}

// TestWhoamiCloudBlockVerified: a Cloud session whose token the control plane
// ANSWERS FOR reads logged_in:true / session:"verified" — and the token value
// itself never appears. The old test pinned logged_in:true from token PRESENCE
// against an unreachable plane, a pin that structurally could not fail on an
// invalid session (dr-w35-bl-whoami-presence-oracle); the /v1/me probe is what
// earns `true` now, so this fixture must actually answer it.
func TestWhoamiCloudBlockVerified(t *testing.T) {
	withTempConfigHome(t)
	cloudSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/me" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if r.Header.Get("Authorization") != "Bearer sess-secret-must-not-leak" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
			return
		}
		_, _ = w.Write([]byte(`{"user":{"id":"u1","email":"x@example.com"},"teams":[]}`))
	}))
	t.Cleanup(cloudSrv.Close)
	if err := SaveConfig(&Config{
		CloudURL:   cloudSrv.URL,
		CloudToken: "sess-secret-must-not-leak",
		CloudTeam:  "team-abc",
	}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	srv := unreachableWhoamiServer(t)

	cloud, raw := whoamiCloudPayload(t, srv.URL)
	if cloud["logged_in"] != true {
		t.Errorf("cloud.logged_in = %v, want true (the plane VERIFIED the token)", cloud["logged_in"])
	}
	if cloud["session"] != "verified" {
		t.Errorf("cloud.session = %v, want verified", cloud["session"])
	}
	if cloud["token_present"] != true {
		t.Errorf("cloud.token_present = %v, want true", cloud["token_present"])
	}
	if cloud["url"] != cloudSrv.URL {
		t.Errorf("cloud.url = %v", cloud["url"])
	}
	if cloud["team"] != "team-abc" {
		t.Errorf("cloud.team = %v", cloud["team"])
	}
	// The token value must NEVER appear anywhere in the output.
	if strings.Contains(raw, "sess-secret-must-not-leak") {
		t.Fatalf("whoami leaked the cloud token:\n%s", raw)
	}
}

// TestWhoamiCloudBlockRejectedSession is the test the old suite structurally
// could not have: a token that IS on disk and that the control plane REJECTS.
// logged_in must be false — presence is not a session — and the human line must
// say the session is dead rather than "logged in".
func TestWhoamiCloudBlockRejectedSession(t *testing.T) {
	withTempConfigHome(t)
	cloudSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"unauthorized: session expired"}`))
	}))
	t.Cleanup(cloudSrv.Close)
	if err := SaveConfig(&Config{CloudURL: cloudSrv.URL, CloudToken: "dead-tok"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	srv := unreachableWhoamiServer(t)

	cloud, _ := whoamiCloudPayload(t, srv.URL)
	if cloud["logged_in"] != false {
		t.Errorf("cloud.logged_in = %v, want false — the plane REJECTED the token and a presence-derived true is the defect this slice removes", cloud["logged_in"])
	}
	if cloud["session"] != "rejected" {
		t.Errorf("cloud.session = %v, want rejected", cloud["session"])
	}
	if cloud["token_present"] != true {
		t.Errorf("cloud.token_present = %v, want true — the FILE fact stays honest under its own name", cloud["token_present"])
	}

	// Human line: the dead session is named, and "logged in" is not claimed.
	var hOut, hErr bytes.Buffer
	hw := newWriter(&hOut, &hErr)
	hw.output = "table"
	if code := runWhoami(hw, globals{}, manifest.Context{Server: srv.URL}, tokenProvenance{}); code != exitOK {
		t.Fatalf("runWhoami (human) exit = %d\n%s", code, hErr.String())
	}
	if !strings.Contains(hOut.String(), "REJECTED") || !strings.Contains(hOut.String(), "bp login") {
		t.Fatalf("a rejected session must be named with its remedy:\n%s", hOut.String())
	}
	if strings.Contains(hOut.String(), "logged in to") {
		t.Fatalf("a rejected session must not read as logged in:\n%s", hOut.String())
	}
}

// TestWhoamiCloudBlockUnverifiedSession: a token on disk and a control plane
// that cannot be reached is a MISSING MEASUREMENT, not a session and not its
// absence — logged_in is null (the epic's signature defect is ABSENT collapsing
// into a confident reading, in either direction).
func TestWhoamiCloudBlockUnverifiedSession(t *testing.T) {
	withTempConfigHome(t)
	// A closed port: reserve one with a listener, then shut it down.
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	deadURL := dead.URL
	dead.Close()
	if err := SaveConfig(&Config{CloudURL: deadURL, CloudToken: "some-tok"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	srv := unreachableWhoamiServer(t)

	cloud, _ := whoamiCloudPayload(t, srv.URL)
	if cloud["logged_in"] != nil {
		t.Errorf("cloud.logged_in = %v, want null — an unreachable plane cannot adjudicate the token, and neither true (presence oracle) nor false (invented rejection) is honest", cloud["logged_in"])
	}
	if cloud["session"] != "unverified" {
		t.Errorf("cloud.session = %v, want unverified", cloud["session"])
	}
	if cloud["token_present"] != true {
		t.Errorf("cloud.token_present = %v, want true", cloud["token_present"])
	}

	var hOut, hErr bytes.Buffer
	hw := newWriter(&hOut, &hErr)
	hw.output = "table"
	if code := runWhoami(hw, globals{}, manifest.Context{Server: srv.URL}, tokenProvenance{}); code != exitOK {
		t.Fatalf("runWhoami (human) exit = %d\n%s", code, hErr.String())
	}
	if !strings.Contains(hOut.String(), "UNVERIFIED") {
		t.Fatalf("an unverified session must say so:\n%s", hOut.String())
	}
	if strings.Contains(hOut.String(), "logged in to") {
		t.Fatalf("an unverified session must not read as logged in:\n%s", hOut.String())
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
	if code := runWhoami(hw, globals{}, manifest.Context{Server: srv.URL}, tokenProvenance{}); code != exitOK {
		t.Fatalf("runWhoami (human) exit = %d\n%s", code, hErr.String())
	}
	if !strings.Contains(hOut.String(), "not logged in") {
		t.Fatalf("expected a 'not logged in' hint:\n%s", hOut.String())
	}

	// JSON mode: logged_in must be false.
	var jOut, jErr bytes.Buffer
	jw := newWriter(&jOut, &jErr)
	jw.output = "json"
	if code := runWhoami(jw, globals{}, manifest.Context{Server: srv.URL}, tokenProvenance{}); code != exitOK {
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
	if cloud["session"] != "none" {
		t.Errorf("cloud.session = %v, want none", cloud["session"])
	}
	if cloud["token_present"] != false {
		t.Errorf("cloud.token_present = %v, want false", cloud["token_present"])
	}
}

// scopeFateManifestJSON is a four-command roster with exactly one command per
// ScopeFate, so the tally whoami prints is checkable to the digit:
//
//	carried            workspace.project-create — :workspace_slug is in its own path
//	mirrored           doc.ls — no scope in the path, but a scoped_prefix is advertised
//	unscoped-by-design auth.login — the `auth` noun is declared server-global
//	refused            task.get — the `task` noun is declared refuse-before-I/O
//
// doc.ls deliberately carries a NON-scoped auth_tier: commandCarriesScope
// composes the prefix into the template for the scoped_* tiers, which would
// make it read as carried rather than mirrored.
const scopeFateManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "auth_tier": "admin",
  "server": {"name": "scope-fate-test", "base_url": "http://replaced"},
  "nouns": [
    {"name": "workspace", "summary": "Tenancy."},
    {"name": "doc", "summary": "Documents."},
    {"name": "auth", "summary": "Identity."},
    {"name": "task", "summary": "Ledger."}
  ],
  "commands": [
    {"id":"workspace.project-create","noun":"workspace","verb":"project-create","summary":"New project.",
     "http":{"method":"POST","path_template":"/v1/workspaces/:workspace_slug/projects"},
     "auth_tier":"admin","args":[],"flags":[],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"List documents.",
     "http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},
     "auth_tier":"admin","args":[],"flags":[],
     "writes":false,"batch":false,"paginated":true,"dry_run":false,
     "default_output":"table","scoped_prefix":"/w/:workspace_slug/p/:project_slug"},
    {"id":"auth.login","noun":"auth","verb":"login","summary":"Log in.",
     "http":{"method":"POST","path_template":"/v1/auth/login"},
     "auth_tier":"public","args":[],"flags":[],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"task.get","noun":"task","verb":"get","summary":"One task.",
     "http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},
     "auth_tier":"admin",
     "args":[{"name":"doc_id","required":true,"type":"string","summary":"Task id."}],
     "flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

// scopeFateServer serves scopeFateManifestJSON at GET /v1/capabilities and 404s
// everything else, so whoami's manifest fetch succeeds and its side probes
// (/v1/meta, the cloud plane) stay silent.
func scopeFateServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/capabilities" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(scopeFateManifestJSON))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// whoamiScopeBlock runs whoami in human mode and returns the `scope:` line plus
// every continuation line indented under it.
func whoamiScopeBlock(t *testing.T, ctx manifest.Context) []string {
	t.Helper()
	var out, errb bytes.Buffer
	w := newWriter(&out, &errb)
	w.output = "table"
	if code := runWhoami(w, globals{server: ctx.Server}, ctx, tokenProvenance{}); code != exitOK {
		t.Fatalf("runWhoami exit = %d\n%s", code, errb.String())
	}
	var block []string
	for _, l := range strings.Split(out.String(), "\n") {
		if strings.HasPrefix(l, "scope:") {
			block = append(block, l)
			continue
		}
		if len(block) > 0 && strings.HasPrefix(l, "           ") {
			block = append(block, l)
			continue
		}
		if len(block) > 0 {
			break
		}
	}
	if len(block) == 0 {
		t.Fatalf("whoami printed no scope line:\n%s", out.String())
	}
	return block
}

// TestWhoamiScopePrintFloorIsByteIdentical pins the arm that is CORRECT today.
// With no stated scope the operator's context IS the scope every request uses,
// so the line must stay exactly what it has always been — one line, no mark, no
// tally. This is the regression fence on the honesty work: it must not tax the
// invocation that was never lying.
func TestWhoamiScopePrintFloorIsByteIdentical(t *testing.T) {
	withTempConfigHome(t)
	srv := scopeFateServer(t)

	block := whoamiScopeBlock(t, manifest.Context{
		Server:    srv.URL,
		Workspace: "default",
		Project:   "default",
		Dataset:   "production",
	})
	want := "scope:     w=default p=default d=production"
	if len(block) != 1 || block[0] != want {
		t.Fatalf("floor scope block must be the single byte-identical line\n got: %q\nwant: [%q]", block, want)
	}
}

// TestWhoamiScopePrintFloorIgnoresProvenanceAloneAtFloorValue is the sibling
// trap. WorkspaceExplicit is true for EVERY operator with a saved context or a
// BARKPARK_WORKSPACE — including one set to the floor value. Marking on
// provenance alone would put the "(stated)" tail on essentially every user, so
// the print arms on the same divergence-AND-provenance rule StatedScope draws.
func TestWhoamiScopePrintFloorIgnoresProvenanceAloneAtFloorValue(t *testing.T) {
	withTempConfigHome(t)
	srv := scopeFateServer(t)

	block := whoamiScopeBlock(t, manifest.Context{
		Server:            srv.URL,
		Workspace:         "default",
		Project:           "default",
		Dataset:           "production",
		WorkspaceExplicit: true,
		ProjectExplicit:   true,
	})
	want := "scope:     w=default p=default d=production"
	if len(block) != 1 || block[0] != want {
		t.Fatalf("a stated-but-floor scope is not a divergence and must print the plain line\n got: %q\nwant: [%q]", block, want)
	}
}

// TestWhoamiScopePrintMarksStatedScopeWithItsFate is THE criterion-4 check, and
// it is the one that reds if the print ever reverts to an unconditional ctx
// echo: with `-w beta` in play, `w=beta` alone is a claim the CLI cannot keep —
// on this roster the flag reaches the wire on 1 command of 4 and is refused
// outright on another. The line must mark the value as stated AND carry the
// per-fate tally derived from the live manifest.
func TestWhoamiScopePrintMarksStatedScopeWithItsFate(t *testing.T) {
	withTempConfigHome(t)
	srv := scopeFateServer(t)

	block := whoamiScopeBlock(t, manifest.Context{
		Server:            srv.URL,
		Workspace:         "beta",
		Project:           "default",
		Dataset:           "production",
		WorkspaceExplicit: true,
	})
	joined := strings.Join(block, "\n")

	if block[0] != "scope:     w=beta (stated) p=default d=production" {
		t.Fatalf("a stated workspace must be marked, not echoed as ambient:\n%s", joined)
	}
	if len(block) < 2 {
		t.Fatalf("a stated scope must carry its per-command fate summary:\n%s", joined)
	}
	// The tally is the manifest's, to the digit: 1 carried, 1 mirrored,
	// 1 unscoped-by-design, 1 refused, over 4 commands.
	for _, needle := range []string{
		"-w beta is NOT ambient",
		"of 4 commands",
		"1 carry it in their own path",
		"1 route to the workspace mirror",
		"1 ignore it by design",
		"1 are REFUSED before any request is sent",
		"bp capabilities",
	} {
		if !strings.Contains(joined, needle) {
			t.Errorf("scope block missing %q:\n%s", needle, joined)
		}
	}
	// The project stayed at the floor and must NOT be marked.
	if strings.Contains(block[0], "p=default (stated)") {
		t.Errorf("an unstated project must not be marked:\n%s", joined)
	}
}

// TestWhoamiScopePrintBothFlagsNamed: -w and -p stated together are named
// together, so the operator reads the whole scope that is at risk, not half.
func TestWhoamiScopePrintBothFlagsNamed(t *testing.T) {
	withTempConfigHome(t)
	srv := scopeFateServer(t)

	block := whoamiScopeBlock(t, manifest.Context{
		Server:            srv.URL,
		Workspace:         "beta",
		Project:           "acme",
		Dataset:           "production",
		WorkspaceExplicit: true,
		ProjectExplicit:   true,
	})
	joined := strings.Join(block, "\n")
	if block[0] != "scope:     w=beta (stated) p=acme (stated) d=production" {
		t.Fatalf("both stated scopes must be marked:\n%s", joined)
	}
	if !strings.Contains(joined, "-w beta / -p acme is NOT ambient") {
		t.Fatalf("both stated scopes must be named in the fate line:\n%s", joined)
	}
}

// TestWhoamiScopePrintUnreachableManifestSaysUnknown: an unreachable server is a
// MISSING MEASUREMENT. The print must not invent a tally in either direction —
// and it must still refuse to present the stated scope as ambient.
func TestWhoamiScopePrintUnreachableManifestSaysUnknown(t *testing.T) {
	withTempConfigHome(t)
	srv := unreachableWhoamiServer(t)

	block := whoamiScopeBlock(t, manifest.Context{
		Server:            srv.URL,
		Workspace:         "beta",
		Project:           "default",
		Dataset:           "production",
		WorkspaceExplicit: true,
	})
	joined := strings.Join(block, "\n")
	if block[0] != "scope:     w=beta (stated) p=default d=production" {
		t.Fatalf("an unreachable manifest does not make a stated scope ambient:\n%s", joined)
	}
	if !strings.Contains(joined, "UNKNOWN") || !strings.Contains(joined, "unreachable") {
		t.Fatalf("an unmeasured fate must say so rather than guess:\n%s", joined)
	}
	if strings.Contains(joined, "of 0 commands") {
		t.Fatalf("an empty roster must never render as a tally:\n%s", joined)
	}
}

// TestWhoamiScopeJSONParity: `-o json` carries the same split. workspace= alone
// is the structured form of the same lie, so scope_stated / scope_fate_tally
// appear beside it when a scope is stated — and are ABSENT at the floor, which
// keeps every existing receipt (the onboarding spine included) byte-shaped.
func TestWhoamiScopeJSONParity(t *testing.T) {
	withTempConfigHome(t)
	srv := scopeFateServer(t)

	run := func(ctx manifest.Context) map[string]any {
		t.Helper()
		var out, errb bytes.Buffer
		w := newWriter(&out, &errb)
		w.output = "json"
		if code := runWhoami(w, globals{server: ctx.Server}, ctx, tokenProvenance{}); code != exitOK {
			t.Fatalf("runWhoami exit = %d\n%s", code, errb.String())
		}
		var payload map[string]any
		if err := json.Unmarshal(out.Bytes(), &payload); err != nil {
			t.Fatalf("parse json: %v\n%s", err, out.String())
		}
		return payload
	}

	floor := run(manifest.Context{Server: srv.URL, Workspace: "default", Project: "default", Dataset: "production"})
	if _, ok := floor["scope_stated"]; ok {
		t.Errorf("floor scope must not grow a scope_stated key: %v", floor["scope_stated"])
	}
	if _, ok := floor["scope_fate_tally"]; ok {
		t.Errorf("floor scope must not grow a scope_fate_tally key: %v", floor["scope_fate_tally"])
	}

	stated := run(manifest.Context{Server: srv.URL, Workspace: "beta", Project: "default", Dataset: "production", WorkspaceExplicit: true})
	got, _ := stated["scope_stated"].([]any)
	if len(got) != 1 || got[0] != "-w" {
		t.Fatalf("scope_stated = %v, want [-w]", stated["scope_stated"])
	}
	tally, ok := stated["scope_fate_tally"].(map[string]any)
	if !ok {
		t.Fatalf("stated scope missing scope_fate_tally:\n%v", stated)
	}
	for k, want := range map[string]float64{"commands": 4, "carried": 1, "mirrored": 1, "unscoped-by-design": 1, "refused": 1} {
		if tally[k] != want {
			t.Errorf("scope_fate_tally[%q] = %v, want %v", k, tally[k], want)
		}
	}
}
