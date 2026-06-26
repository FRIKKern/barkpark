package agent

import (
	"reflect"
	"sort"
	"testing"
)

// fakeRunner records every Run call and returns a canned output. It NEVER shells
// out — the test asserts the agent only ever asks it to run allowlisted argv.
type fakeRunner struct {
	calls  [][]string
	output string
	err    error
}

func (f *fakeRunner) Run(name string, args ...string) (string, error) {
	f.calls = append(f.calls, append([]string{name}, args...))
	return f.output, f.err
}

// TestAllowlistIsExactlyTheSix pins the approved surface to exactly the six
// documented actions — no more, no less. A new key cannot sneak in unnoticed.
func TestAllowlistIsExactlyTheSix(t *testing.T) {
	want := []string{"backup", "doctor", "logs", "rebuild", "restart", "update"}

	got := AllowedCommands()
	sort.Strings(got)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("AllowedCommands() = %v, want %v", got, want)
	}

	// The private map must agree with the public surface.
	if len(allowlist) != len(want) {
		t.Fatalf("allowlist has %d entries, want %d", len(allowlist), len(want))
	}
	for _, name := range want {
		if !IsApproved(name) {
			t.Errorf("IsApproved(%q) = false, want true", name)
		}
		if argv := allowlist[name]; len(argv) == 0 {
			t.Errorf("allowlist[%q] has empty argv", name)
		}
	}
}

// TestRunCommandRejectsNonAllowlisted is the SECURITY test: a command not on the
// allowlist (here "rm -rf /") is rejected outright — the runner is NEVER invoked,
// so nothing executes. This is the non-negotiable boundary.
func TestRunCommandRejectsNonAllowlisted(t *testing.T) {
	runner := &fakeRunner{}

	for _, bad := range []string{"rm -rf", "rm", "curl|sh", "bash", "../restart", "RESTART", ""} {
		res := runCommand(runner, Command{ID: "x", Name: bad})
		if res.Approved {
			t.Errorf("runCommand(%q) approved = true, want false", bad)
		}
		if res.Err == "" {
			t.Errorf("runCommand(%q) Err empty, want a rejection message", bad)
		}
		if res.Output != "" {
			t.Errorf("runCommand(%q) Output = %q, want empty (nothing ran)", bad, res.Output)
		}
	}

	if len(runner.calls) != 0 {
		t.Fatalf("runner was invoked %d times for rejected commands; want 0 (nothing must execute)", len(runner.calls))
	}
}

// TestRunCommandRunsApproved verifies each of the six approved commands resolves
// to its fixed argv and runs via the injected runner — never a shell, never the
// raw name.
func TestRunCommandRunsApproved(t *testing.T) {
	wantArgv := map[string][]string{
		"restart": {"systemctl", "restart", "barkpark"},
		"rebuild": {"make", "-C", "/opt/barkpark", "rebuild"},
		"backup":  {"make", "-C", "/opt/barkpark", "backup"},
		"update":  {"make", "-C", "/opt/barkpark", "deploy"},
		"doctor":  {"make", "-C", "/opt/barkpark", "doctor"},
		"logs":    {"journalctl", "-u", "barkpark", "--no-pager", "-n", "200"},
	}

	for name, argv := range wantArgv {
		runner := &fakeRunner{output: "ok"}
		res := runCommand(runner, Command{ID: "c-" + name, Name: name})

		if !res.Approved {
			t.Errorf("%q: Approved = false, want true", name)
		}
		if res.Err != "" {
			t.Errorf("%q: Err = %q, want empty", name, res.Err)
		}
		if res.Output != "ok" {
			t.Errorf("%q: Output = %q, want %q", name, res.Output, "ok")
		}
		if len(runner.calls) != 1 {
			t.Fatalf("%q: runner called %d times, want 1", name, len(runner.calls))
		}
		if !reflect.DeepEqual(runner.calls[0], argv) {
			t.Errorf("%q: ran argv %v, want %v", name, runner.calls[0], argv)
		}
	}
}
