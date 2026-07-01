package cli

import (
	"bytes"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

func TestRunCompletionBash(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, []string{"bash"}); code != exitOK {
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
	if code := runCompletion(w, []string{"zsh"}); code != exitOK {
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
	if code := runCompletion(w, nil); code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	if !strings.Contains(stdout.String(), "complete -F _bp_complete bp") {
		t.Errorf("no-arg completion should default to bash:\n%s", stdout.String())
	}
}

func TestRunCompletionFish(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, []string{"fish"}); code != exitOK {
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
	if code := runCompletion(w, []string{"powershell"}); code != exitUsage {
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
