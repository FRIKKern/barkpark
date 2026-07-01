package cli

import (
	"bytes"
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

// sampleVerbMap is a fixed noun→verbs map used by the verb-completion tests so
// they don't depend on a real on-disk manifest cache.
var sampleVerbMap = map[string][]string{
	"task": {"close", "next", "ready"},
	"doc":  {"create", "delete", "get"},
}

func TestBashCompletionVerbsStructural(t *testing.T) {
	script := bashCompletionScript("task doc", "--dataset", sampleVerbMap)
	for _, want := range []string{
		`case "${COMP_WORDS[1]}" in`,
		`task) __bpverbs="close next ready";;`,
		`doc) __bpverbs="create delete get";;`,
		`compgen -W "$__bpverbs $globals"`,
	} {
		if !strings.Contains(script, want) {
			t.Errorf("bash verb script missing %q:\n%s", want, script)
		}
	}
}

func TestZshCompletionVerbsStructural(t *testing.T) {
	script := zshCompletionScript("task doc", "--dataset", sampleVerbMap)
	for _, want := range []string{
		`case "${words[2]}" in`,
		`task) verbs=(close next ready);;`,
		`compadd -- $verbs $globals`,
	} {
		if !strings.Contains(script, want) {
			t.Errorf("zsh verb script missing %q:\n%s", want, script)
		}
	}
}

func TestFishCompletionVerbsStructural(t *testing.T) {
	script := fishCompletionScript("task doc", "--dataset", sampleVerbMap)
	for _, want := range []string{
		`complete -c bp -n '__fish_seen_subcommand_from task' -a 'close next ready'`,
		`complete -c bp -n '__fish_seen_subcommand_from doc' -a 'create delete get'`,
	} {
		if !strings.Contains(script, want) {
			t.Errorf("fish verb script missing %q:\n%s", want, script)
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

	run := func(t *testing.T, verbMap map[string][]string, word string, cword int) string {
		t.Helper()
		script := bashCompletionScript(strings.Join(completionNouns, " "),
			strings.Join(completionGlobals, " "), verbMap)
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
	out := run(t, sampleVerbMap, "task", 2)
	for _, verb := range []string{"close", "next", "ready"} {
		if !strings.Contains(out, verb) {
			t.Errorf("bp task <TAB> did not offer %q; COMPREPLY:\n%s", verb, out)
		}
	}

	// Empty verbMap (no cache): the generated script must still be VALID bash and
	// simply fall back to globals — proves the empty `case … *) ;; esac` parses.
	outEmpty := run(t, nil, "task", 2)
	if !strings.Contains(outEmpty, "--dataset") {
		t.Errorf("empty-verbMap position-2 should offer globals; COMPREPLY:\n%s", outEmpty)
	}
}
