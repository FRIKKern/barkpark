package cli

import (
	"os"
	"strings"
	"testing"
)

// Guard: the cardinal fail-safe contract (cmux_hook.go §7) is SOURCE-enforced,
// not just behaviour-tested. A hook must NEVER break the agent — so cmux_hook.go
// may never exit the process (codes ride the runCmuxHook return value, recovered
// to exitOK) and may never write a byte to stdout (diagnostics ride out.errf →
// stderr, and only under --dry-run / BP_CMUX_DEBUG). This tripwire fails the
// moment a future edit reintroduces os.Exit, an fmt.Print* to stdout, or a
// direct os.Stdout reference on any branch. Modelled on
// TestDispatchUsesSharedFrontier (cmux_dispatch_test.go).
//
// Scope is cmux_hook.go ONLY: cmux_cmd.go's `bp cmux status` legitimately prints
// a report to stdout — that is a normal CLI command, not a Claude Code hook.
func TestHookSourceNeverExitsOrWritesStdout(t *testing.T) {
	const src = "cmux_hook.go"
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read %s: %v", src, err)
	}
	text := string(data)

	// Unambiguous substrings — none has any legitimate use in a hook path.
	//   os.Exit(          — the hook returns codes; a process exit skips the
	//                       top-level recover and can hand Claude a non-zero code.
	//   fmt.Print / .Printf / .Println — write to stdout (NOT Fprint, which
	//                       names an explicit io.Writer and is not matched here).
	//   os.Stdout         — any direct stdout handle (covers fmt.Fprint(os.Stdout,
	//                       os.Stdout.Write, io.Copy(os.Stdout, …)).
	for _, banned := range []string{"os.Exit(", "fmt.Print", "os.Stdout"} {
		if strings.Contains(text, banned) {
			t.Errorf("%s contains %q — the hook must never exit non-zero nor write stdout "+
				"(fail-safe contract §7; route diagnostics through out.errf → stderr)", src, banned)
		}
	}

	// The builtins print/println emit to stderr, but they are unstructured and
	// bypass the debug gate — banned too. Scan per-line (skipping the // comment
	// tail and doc prose) so that fmt.Fprintln / strings.Sprint never false-match
	// on the trailing "print(" substring.
	for i, raw := range strings.Split(text, "\n") {
		line := raw
		if idx := strings.Index(line, "//"); idx >= 0 {
			line = line[:idx]
		}
		for _, b := range []string{"println(", "print("} {
			idx := strings.Index(line, b)
			if idx < 0 {
				continue
			}
			// Ignore Fprint/Sprint/Fprintln/Sprintln etc.: the builtin is a
			// bare identifier, so a preceding letter means it is a method suffix.
			if idx > 0 {
				if p := line[idx-1]; (p >= 'a' && p <= 'z') || (p >= 'A' && p <= 'Z') {
					continue
				}
			}
			t.Errorf("%s:%d uses builtin %q — hook output must go through out.errf → stderr", src, i+1, b)
		}
	}
}
