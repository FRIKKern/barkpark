package deploy

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// boxAptFiles is every committed file whose apt-get calls run ON a managed box:
// the shell scripts streamed or run there, and the Go files that build shell
// commands sent there over SSH. The list is explicit on purpose. A new box
// script or a new Go-built box command that installs packages must be added
// here, and then it must wait for the dpkg lock like the rest.
//
// Left out, on purpose: Dockerfiles (apt runs in a build container, where no
// unattended-upgrades runs), the CI scripts and workflows (GitHub runners), and
// internal/cli/setup/local.go (install hints printed for a developer machine).
var boxAptFiles = []string{
	"deploy.sh",
	"internal/cli/setup/assets/deploy.sh",
	"deploy/site-runtime-install.sh",
	"deploy/azure-base-install.sh",
	"deploy/bake-server-image.sh",
	"internal/cli/setup/caddy.go",
	"internal/provisioner/support.go",
	"internal/cli/cloud_support_cmd.go",
}

// bareAptCall matches an apt-get, apt or dpkg call that changes packages or
// refreshes the lists, i.e. one that takes the dpkg or lists lock. bp_apt_get
// does not match: `_` before "apt" is excluded. `apt-get clean` is not listed;
// bake-server-image.sh runs it best-effort with `|| true`.
var bareAptCall = regexp.MustCompile(`(^|[^_[:alnum:]-])(apt-get|apt)(\s+-\S+)*\s+(install|update|upgrade|dist-upgrade|full-upgrade|purge|remove|autoremove|reinstall)\b|(^|[^_[:alnum:]-])dpkg\s+(-i|--install|-r|--remove|-P|--purge|--configure)\b`)

func repoFile(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(b)
}

// TestBoxAptCallsWaitForTheDpkgLock is the census for task-aa4ef6ce7298ef70.
// On 2026-11-19 a cold box's go-live died at step 7c: site-runtime-install.sh's
// bare `apt-get install` exited 100 on "Could not get lock
// /var/lib/dpkg/lock-frontend ... (unattended-upgr)". Every box apt call must go
// through bp_apt_get, and every copy of bp_apt_get must be the same bytes.
func TestBoxAptCallsWaitForTheDpkgLock(t *testing.T) {
	fn := AptGetFunc()
	if fn == "" {
		t.Fatal("bp_apt_get BEGIN/END markers not found in deploy/site-runtime-install.sh")
	}
	for _, want := range []string{"bp_apt_get() {", "-o DPkg::Lock::Timeout=600", "Could not get lock"} {
		if !strings.Contains(fn, want) {
			t.Errorf("bp_apt_get lacks %q", want)
		}
	}
	for _, rel := range boxAptFiles {
		src := repoFile(t, rel)
		isGo := strings.HasSuffix(rel, ".go")
		inBlock := false
		for n, line := range strings.Split(src, "\n") {
			trimmed := strings.TrimSpace(line)
			switch {
			case trimmed == "# bp_apt_get BEGIN":
				inBlock = true
				continue
			case trimmed == "# bp_apt_get END":
				inBlock = false
				continue
			case inBlock, strings.HasPrefix(trimmed, "#"), isGo && strings.HasPrefix(trimmed, "//"):
				continue
			}
			if bareAptCall.MatchString(line) {
				t.Errorf("%s:%d: apt call without the lock wait; use bp_apt_get: %s", rel, n+1, trimmed)
			}
		}
		if !strings.Contains(src, "bp_apt_get ") {
			continue
		}
		if isGo {
			if !strings.Contains(src, "deploy.AptGetFunc()") {
				t.Errorf("%s calls bp_apt_get but never prepends deploy.AptGetFunc(), so the box shell has no such function", rel)
			}
		} else if !strings.Contains(src, fn) {
			t.Errorf("%s calls bp_apt_get but does not carry the byte-identical bp_apt_get block; copy it from deploy/site-runtime-install.sh", rel)
		}
	}
}

// TestAptGetFuncRetriesOnlyLockRefusals runs bp_apt_get in bash against a fake
// apt-get and a fake sleep that advances $SECONDS, so no test waits.
func TestAptGetFuncRetriesOnlyLockRefusals(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not on PATH")
	}
	const fakes = `
sleep() { SECONDS=$((SECONDS + $1)); }
apt-get() {
  # bp_apt_get calls apt-get in a command substitution (a subshell), so the
  # call count lives in the log file, not in a shell variable.
  local calls=1
  if [ -f "$LOG" ]; then while read -r _; do calls=$((calls + 1)); done < "$LOG"; fi
  echo "call $calls: $*" >> "$LOG"
  if [ "$calls" -le "$LOCKED_CALLS" ]; then
    echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1 (unattended-upgr)" >&2
    return 100
  fi
  [ -z "$FAIL" ] || { echo "E: Unable to locate package nope" >&2; return 100; }
  echo "installed"
}
`
	run := func(t *testing.T, locked, fail string) (out string, rc int, log string) {
		t.Helper()
		logPath := filepath.Join(t.TempDir(), "apt.log")
		cmd := exec.Command(bash, "-c", "set -euo pipefail\n"+AptGetFunc()+fakes+"bp_apt_get install -y git")
		cmd.Env = append(os.Environ(), "LOG="+logPath, "LOCKED_CALLS="+locked, "FAIL="+fail)
		b, err := cmd.CombinedOutput()
		if ee, ok := err.(*exec.ExitError); ok {
			rc = ee.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		lb, _ := os.ReadFile(logPath)
		return string(b), rc, string(lb)
	}
	t.Run("waits out a held lock, then succeeds", func(t *testing.T) {
		out, rc, log := run(t, "3", "")
		if rc != 0 || !strings.Contains(out, "installed") || strings.Count(log, "\n") != 4 {
			t.Fatalf("rc=%d out=%q log=%q; want rc 0 after 3 lock refusals and a 4th call", rc, out, log)
		}
		if !strings.Contains(log, "call 1: -o DPkg::Lock::Timeout=600 install -y git") {
			t.Errorf("apt-get was not called with DPkg::Lock::Timeout: %q", log)
		}
	})
	t.Run("returns any other failure at once", func(t *testing.T) {
		out, rc, log := run(t, "0", "1")
		if rc != 100 || strings.Count(log, "\n") != 1 || !strings.Contains(out, "Unable to locate package") {
			t.Fatalf("rc=%d out=%q log=%q; want rc 100 after one call, stderr kept", rc, out, log)
		}
	})
	t.Run("gives up after 600 s of lock refusals", func(t *testing.T) {
		_, rc, log := run(t, "1000", "")
		n := strings.Count(log, "\n")
		if rc != 100 || n < 60 || n > 62 {
			t.Fatalf("rc=%d calls=%d; want rc 100 after about 61 calls (600 s at 10 s each)", rc, n)
		}
	})
}
