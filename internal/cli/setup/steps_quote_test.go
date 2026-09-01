package setup

import (
	"fmt"
	"os/exec"
	"reflect"
	"strings"
	"testing"
)

// shellRoundTripArgv is the adversarial argv any shell-word joiner must survive:
// after a REAL POSIX shell word-splits the joined line, every element must come
// back byte-identical. It asserts the PROPERTY, not a character list, so a rune
// nobody thought of the day this was written still fails the test the day it
// matters — which is exactly what a denylist of "known bad" metacharacters
// cannot do. Kept in step with cloud.shellRoundTripArgv, the twin joiner's table.
//
// Every payload is deliberately INERT: the ones that would execute only echo,
// and nothing writes, moves or deletes. A RED run of this test against a leaky
// joiner must not be able to damage the tree it runs in.
var shellRoundTripArgv = []string{
	"plainword",
	"a-b_c.d/e:f=g@h%i+j",
	"",
	"a b",
	"a\tb",
	"it's",
	`he said "hi"`,
	// Space-FREE injection payloads. These are the ones that matter: a denylist
	// keyed on whitespace-or-quote quotes "$(echo pwned)" by accident, because
	// of the SPACE, and would have looked green while the same substitution
	// spelled without a space walked straight through.
	"$(pwd)",
	"`pwd`",
	"${HOME}",
	"a;true",
	"a&&true",
	"a|true",
	// …and the same shapes spelled with a space, which a whitespace denylist
	// does happen to catch — kept so the table covers both spellings.
	"$(echo pwned)",
	"a;echo pwned",
	"x|y",
	">&2",
	"<in",
	"*",
	"?",
	"[a-z]",
	"(paren)",
	"{a,b}",
	`back\slash`,
	"line1\nline2",
	"~",
	"#hash",
	"!bang",
	"naïve",
	"a=$b",
}

// shellSplit renders joined through a real /bin/sh and returns the words the
// SHELL produced — the only oracle that cannot agree with the bug it is hunting.
// printf's NUL separator keeps a newline-bearing word intact, and the shell runs
// in a scratch dir so a glob or redirect a leaky joiner lets through is
// contained rather than loose in the worktree.
func shellSplit(t *testing.T, joined string) []string {
	t.Helper()
	cmd := exec.Command("/bin/sh", "-c", "printf '%s\\0' "+joined)
	cmd.Dir = t.TempDir()
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("/bin/sh refused the joined line %q: %v", joined, err)
	}
	if len(out) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(out), "\x00"), "\x00")
}

// TestShJoinRoundTripsThroughARealShell holds shJoin to the same contract as its
// cloud twin. shJoin's output is BOTH what an operator copy-pastes into a shell
// and (via provision/caddy steps) the rendering beside a real Argv, so a token
// the shell would re-interpret is a fidelity bug either way.
func TestShJoinRoundTripsThroughARealShell(t *testing.T) {
	// The whole argv at once — a leaky joiner can drop a word, invent one, or
	// make the line unparseable outright, and only joining everything catches
	// that last shape. In its own subtest so a hard shell refusal here still
	// leaves the per-token subtests below to name the exact offenders.
	t.Run("whole argv", func(t *testing.T) {
		if got := shellSplit(t, shJoin(shellRoundTripArgv)); !reflect.DeepEqual(got, shellRoundTripArgv) {
			t.Errorf("whole-argv round trip lost fidelity\n joined = %s\n  got   = %q\n  want  = %q",
				shJoin(shellRoundTripArgv), got, shellRoundTripArgv)
		}
	})
	for _, arg := range shellRoundTripArgv {
		t.Run(fmt.Sprintf("%q", arg), func(t *testing.T) {
			joined := shJoin([]string{arg})
			got := shellSplit(t, joined)
			if len(got) != 1 || got[0] != arg {
				t.Errorf("shJoin([%q]) = %s\n  /bin/sh read that back as %q\n  want exactly one word, unchanged", arg, joined, got)
			}
		})
	}
}

// TestShJoinLeavesSafeWordsBare pins the other half of the contract: the
// copy-pasteable line stays unquoted for the ordinary CLI words every caller
// builds today, so hardening the quoting does not churn every step's Cmd.
func TestShJoinLeavesSafeWordsBare(t *testing.T) {
	argv := []string{"hcloud", "server", "create", "--name", "barkpark", "--type", "cax11"}
	const want = "hcloud server create --name barkpark --type cax11"
	if got := shJoin(argv); got != want {
		t.Errorf("shJoin(%q) = %q, want %q", argv, got, want)
	}
}
