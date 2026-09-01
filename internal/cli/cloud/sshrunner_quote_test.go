package cloud

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
// cannot do.
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

// TestShJoinArgvRoundTripsThroughARealShell is the regression guard for the
// unquoted-metacharacter leak into the remote `bash -l`: shJoinArgv's output is
// a shell script line, so the contract is that the shell reads back EXACTLY the
// argv that went in.
func TestShJoinArgvRoundTripsThroughARealShell(t *testing.T) {
	// The whole argv at once — a leaky joiner can drop a word, invent one, or
	// make the line unparseable outright, and only joining everything catches
	// that last shape. In its own subtest so a hard shell refusal here still
	// leaves the per-token subtests below to name the exact offenders.
	t.Run("whole argv", func(t *testing.T) {
		if got := shellSplit(t, shJoinArgv(shellRoundTripArgv)); !reflect.DeepEqual(got, shellRoundTripArgv) {
			t.Errorf("whole-argv round trip lost fidelity\n joined = %s\n  got   = %q\n  want  = %q",
				shJoinArgv(shellRoundTripArgv), got, shellRoundTripArgv)
		}
	})
	for _, arg := range shellRoundTripArgv {
		t.Run(fmt.Sprintf("%q", arg), func(t *testing.T) {
			joined := shJoinArgv([]string{arg})
			got := shellSplit(t, joined)
			if len(got) != 1 || got[0] != arg {
				t.Errorf("shJoinArgv([%q]) = %s\n  /bin/sh read that back as %q\n  want exactly one word, unchanged", arg, joined, got)
			}
		})
	}
}

// TestShJoinArgvLeavesSafeWordsBare pins the other half of the contract: the
// rendering an operator reads (and copy-pastes) stays unquoted for the ordinary
// CLI words every caller builds today, so hardening the quoting does not churn
// every step's displayed Cmd.
func TestShJoinArgvLeavesSafeWordsBare(t *testing.T) {
	argv := []string{"sudo", "apt-get", "install", "-y", "caddy", "PHX_HOST=api.barkpark.cloud"}
	const want = "sudo apt-get install -y caddy PHX_HOST=api.barkpark.cloud"
	if got := shJoinArgv(argv); got != want {
		t.Errorf("shJoinArgv(%q) = %q, want %q", argv, got, want)
	}
}
