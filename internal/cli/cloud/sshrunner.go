// SSHStepRunner is the per-host StepRunner that runs a CaddyStep's command ON
// the provisioned instance over SSH, instead of LOCALLY on the worker's own
// machine (which is what realStepRunner does). The warm-pool Provision chain
// assigns a host IP at step 1, so the Caddy/TLS + migrate steps must execute
// against THAT box — apt-get install caddy, the Caddyfile heredoc, PHX_HOST in
// the app .env, `mix ecto.migrate` — none of which make sense on the worker.
//
// The runner is the FAKE-injectable seam's production fill: tests inject a
// recording runner via the RunnerFor factory, production injects an
// SSHStepRunner factory bound to the assigned host. It shells out:
//
//	ssh -i <key> -o UserKnownHostsFile=/dev/null \
//	    -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
//	    -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
//	    <user>@<host> '<base64-decode-to-tempfile-and-run>'
//
// The step's command is base64-encoded and decoded to a temp file on the box,
// then run with `bash -l "$tmp" </dev/null` so the pipes / `&&` chains / heredocs
// the steps carry survive the SSH boundary intact AND no inner stdin-reading
// command eats the rest of the script (see sshStepArgv for both hazards). The
// ServerAlive options bound a hung connection so a dead box/long step fails
// instead of hanging forever. Narration-only steps (empty Argv/Cmd) are skipped,
// mirroring realStepRunner. On failure the captured ssh output is surfaced in the
// error (with per-step secrets scrubbed) — never a bare "exit status 1".
//
// YAGNI: no connection pooling, no retries — the warm-pool health gate is the
// catch for a half-applied box (it fails closed before register).
package cloud

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// StdinStepRunner is the OPTIONAL capability a per-host runner advertises when it
// can stream a reader into a remote script's STDIN — the resurrect restore
// (charter S14f) needs it to pipe a bundle's db.dump + media tarball into the
// on-box pg_restore/tar, the import-feed pattern lifted from the transfer command.
// The production *SSHStepRunner satisfies it; the ordinary Run keeps its
// `</dev/null` stdin for every non-feed step (so an inner stdin-reading command
// can never swallow the rest of the script). Tests inject a recorder that captures
// the fed script + stdin bytes so the round-trip proves offline.
type StdinStepRunner interface {
	RunFeed(ctx context.Context, title, script string, stdin io.Reader) (string, error)
}

// defaultSSHUser is the login used for provisioning when SSHStepRunner.User is
// empty — fresh Hetzner Ubuntu images land with a root key, and every setup step
// runs as root (apt-get, systemctl, tee /etc/caddy/…). A non-empty User is
// honored (sshStepArgv threads it into the ssh target).
const defaultSSHUser = "root"

// SSHStepRunner runs each CaddyStep ON Host over SSH. Host is the assigned
// instance IP (set per go-live by the runner factory); Key is the private-key
// path (BARKPARK_SSH_KEY_FILE, else ~/.ssh/barkpark_indx); User is the login,
// defaulting to root when empty. Run is the exec seam — nil falls back to
// runCapture (live ssh), tests inject a recorder.
type SSHStepRunner struct {
	Host string
	Key  string
	User string

	// Sudo sudo-wraps every step run through this runner (`sudo -n bash …` instead
	// of `bash …`). It is set ONLY on the per-host runner an AZURE resurrect builds
	// (restoreRunner): those boxes provision only the non-root `barkpark` admin (D56 —
	// the SSH key lands in /home/barkpark and stock Canonical images lock root), yet
	// azure-base-install + the on-box restore pipeline require root, so the steps SSH
	// as barkpark and reach root via passwordless sudo (waagent grants it). Every
	// other path — hetzner restore, warm-pool configure, the deploy feeder — leaves it
	// false, so their argv is byte-identical to before (`bash …`, root, no sudo).
	Sudo bool

	// Exec dispatches the ssh argv and returns combined stdout+stderr + the error.
	// nil → runCapture (the same exec mechanism provider.go / CloudDNS use). The
	// signature mirrors runCapture so the production runner is a one-line adapter;
	// tests inject a recorder so Run never shells out to real ssh.
	Exec func(ctx context.Context, name string, args ...string) (string, error)
}

// NewSSHStepRunner builds a runner targeting host, resolving the key path and
// defaulting the user to root. It is what the production RunnerFor factory
// returns per assigned host.
func NewSSHStepRunner(host string) *SSHStepRunner {
	return &SSHStepRunner{
		Host: host,
		Key:  sshKeyPath(),
		User: defaultSSHUser,
	}
}

// sshKeyPath resolves the provisioning private key: BARKPARK_SSH_KEY_FILE when
// set, else ~/.ssh/barkpark_indx (the key the warm pool seeds its hosts with)
// when that file exists, else "". An empty path means "no -i": ssh then offers
// the agent's keys and the default identities. Passing -i for a file that does
// not exist only printed "Identity file ... not accessible" on every step of an
// operator's run whose key sits in the agent (measured 2026-10-14 on fleet-1).
func sshKeyPath() string {
	if k := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY_FILE")); k != "" {
		return k
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	p := filepath.Join(home, ".ssh", "barkpark_indx")
	if _, err := os.Stat(p); err != nil {
		return ""
	}
	return p
}

// sshIdentityArgs is the "-i <key>" pair, or nothing when key is empty so ssh
// falls back to the agent and its default identities.
func sshIdentityArgs(key string) []string {
	if strings.TrimSpace(key) == "" {
		return nil
	}
	return []string{"-i", key}
}

// remoteCommand renders the single shell command to run on the box for a step.
// The steps come in two shapes:
//
//	["bash", "-lc", <script>]   → send <script> verbatim (it already IS the
//	                               shell command, pipes/heredocs/&& and all)
//	["ufw", "deny", "4000"]     → shell-join into "ufw deny 4000"
//
// Unwrapping the bash -lc form avoids double-wrapping the script (we send it to
// a remote `bash -lc` ourselves) and keeps heredocs byte-faithful. Falls back
// to s.Cmd only when there is no Argv to derive from.
func remoteCommand(s CaddyStep) string {
	// The bash -lc form is EXACTLY ["bash","-lc",<script>]: assert len==3 rather
	// than `>= 3` so an extra trailing arg (Argv[3:]) is never silently dropped —
	// a step that meant `bash -lc <script> arg0 …` would otherwise lose its
	// positional args. Such a shape is a builder bug; fall through to shell-join
	// so it is at least visible/runnable rather than truncated.
	if len(s.Argv) == 3 && s.Argv[0] == "bash" && s.Argv[1] == "-lc" {
		return s.Argv[2]
	}
	if len(s.Argv) > 0 {
		return shJoinArgv(s.Argv)
	}
	return s.Cmd
}

// shJoinArgv renders an argv as one shell-safe line — the package-local twin of
// setup.shJoin (kept here so the cloud seam carries no dependency on setup's
// unexported helper), and byte-for-byte the same rule. The joined line is fed to
// a remote `bash -l`, so the contract is a ROUND TRIP: whatever argv goes in,
// the shell on the far side must word-split back to exactly that argv.
func shJoinArgv(argv []string) string {
	parts := make([]string, len(argv))
	for i, a := range argv {
		parts[i] = shQuoteWord(a)
	}
	return strings.Join(parts, " ")
}

// shQuoteWord renders one argv element as a single POSIX shell word.
//
// It quotes by ALLOWLIST, not denylist: a token is left bare only when every
// byte is an ordinary shell-word character, and everything else — including the
// empty string, which must become an empty quoted pair or it vanishes from the
// line entirely — is single-quoted, with the standard POSIX close-escape-reopen
// dance for any single quote inside it.
//
// The predicate this replaced was a denylist (` \t"'`), which let $, backtick,
// ;, &, |, <, >, *, ?, [, (, {, \, ~, #, a newline and every non-ASCII byte
// through UNQUOTED into the remote shell. A denylist can only ever exclude the
// metacharacters its author thought of; the allowlist is closed by construction,
// so a rune nobody anticipated is quoted rather than executed. Every argv the
// current callers build is already made of allowlisted words, so their rendered
// lines are byte-unchanged.
func shQuoteWord(s string) string {
	if !shWordIsBare(s) {
		return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
	}
	return s
}

// shWordIsBare reports whether s survives a POSIX shell unquoted and unchanged.
// The safe set is [A-Za-z0-9_./:=@%+-]; the empty string is never bare.
func shWordIsBare(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '_', c == '.', c == '/', c == ':', c == '=', c == '@', c == '%', c == '+', c == '-':
		default:
			return false
		}
	}
	return true
}

// sshRunPrefix is the shell invocation that runs the decoded temp-file script on
// the box: `bash -l "$b"` for a root step (byte-unchanged), or `sudo -n bash -l
// "$b"` when the runner is sudo-wrapped — an azure restore's non-root `barkpark`
// admin reaching root through passwordless sudo (`-n` fails fast rather than
// prompting, matching the runner's BatchMode contract).
func sshRunPrefix(sudo bool) string {
	if sudo {
		return "sudo -n bash -l"
	}
	return "bash -l"
}

// sshStepArgv builds the EXACT ssh argv that runs cmd as user on host over SSH.
// PURE function (no exec, no env) so a test asserts the argv without invoking
// ssh — the hcloudCreateArgv / hcloudZoneRRSetArgv pattern.
//
// The remote command is BASE64-ENCODED, decoded to a TEMP FILE on the box, and
// run with stdin closed:
//
//	b=$(mktemp); echo <b64> | base64 -d > "$b"; bash -l "$b" </dev/null; rc=$?; rm -f "$b"; exit $rc
//
// This is the robust way to ship a multi-command script across SSH. Two hazards
// it avoids:
//
//   - ARG-SPLITTING: the naive `ssh root@host -- bash -lc <script>` is broken —
//     ssh concatenates the remote args with spaces and the LOGIN shell on the box
//     re-splits them, so `bash -lc` receives only the script's FIRST word (e.g.
//     `apt-get` with no subcommand → usage dump). The base64 blob is a single
//     whitespace-free token that survives ssh's join and the remote shell's parse
//     untouched.
//   - STDIN-EATING: piping the script straight into `bash -l` on stdin
//     (`… | bash -l`) hands the script's OWN stdin to the pipe, so the first inner
//     command that reads stdin (apt prompts, `read`, a heredoc-less tool) swallows
//     the rest of the script. Decoding to a temp file and running `bash -l "$b"
//     </dev/null` gives the script a clean, empty stdin; `rc=$?` + `rm -f` + `exit
//     $rc` preserve the script's exit status while always cleaning up the temp file.
//
// `bash -l` runs the script as a login shell, but the deploy.sh image only adds
// asdf to PATH for INTERACTIVE shells (~/.bashrc), which a login non-interactive
// ssh shell skips — so the steps themselves source asdf explicitly (the migrate
// and admin-token scripts `. /root/.asdf/asdf.sh`); `-l` alone is not enough.
//
// Host options are non-interactive, keepalive-bounded, and tolerant of a fresh
// box's unknown key:
//
//	-i <key>                              the provisioning private key (omitted
//	                                       when no key file resolves: the agent)
//	-o UserKnownHostsFile=/dev/null       don't pollute ~/.ssh/known_hosts
//	-o StrictHostKeyChecking=accept-new   accept a fresh box's key, reject changes
//	-o BatchMode=yes                       never prompt (fail instead of hanging)
//	-o ConnectTimeout=20                   bounded connect
//	-o ServerAliveInterval=15             ping a quiet connection every 15s …
//	-o ServerAliveCountMax=4              … and give up after 4 missed (≈60s) so a
//	                                       dead box/long step fails instead of hanging
func sshStepArgv(user, host, key, cmd string, sudo bool) []string {
	if strings.TrimSpace(user) == "" {
		user = defaultSSHUser
	}
	b64 := base64.StdEncoding.EncodeToString([]byte(cmd))
	// Decode to a temp file and run with stdin closed (see the stdin-eating note).
	// `sudo -n bash …` when the runner is sudo-wrapped (an azure restore's non-root
	// `barkpark` admin reaching root); a bare `bash …` — byte-unchanged — otherwise.
	remote := `b=$(mktemp); echo ` + b64 + ` | base64 -d > "$b"; ` + sshRunPrefix(sudo) + ` "$b" </dev/null; rc=$?; rm -f "$b"; exit $rc`
	argv := append([]string{"ssh"}, sshIdentityArgs(key)...)
	return append(argv,
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=20",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=4",
		user+"@"+host,
		remote,
	)
}

// sshFeedArgv is sshStepArgv's stdin-KEEPING twin: it runs the base64-decoded
// script the SAME way (temp file + `bash -l`) but WITHOUT the `</dev/null`
// redirect, so the ssh connection's real stdin flows into the remote script — the
// resurrect restore pipes the bundle tar into `tar -xzf -` this way. The
// arg-splitting hazard is still dodged (single base64 token). PURE (no exec) so a
// test asserts the argv without invoking ssh.
func sshFeedArgv(user, host, key, cmd string, sudo bool) []string {
	if strings.TrimSpace(user) == "" {
		user = defaultSSHUser
	}
	b64 := base64.StdEncoding.EncodeToString([]byte(cmd))
	// No `</dev/null` here: the script READS stdin (the fed bundle bytes). sudo passes
	// stdin through, so the sudo-wrapped azure feed still receives the bundle tar.
	remote := `b=$(mktemp); echo ` + b64 + ` | base64 -d > "$b"; ` + sshRunPrefix(sudo) + ` "$b"; rc=$?; rm -f "$b"; exit $rc`
	argv := append([]string{"ssh"}, sshIdentityArgs(key)...)
	return append(argv,
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=20",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=4",
		user+"@"+host,
		remote,
	)
}

// RunFeed runs script ON r.Host over SSH with stdin streamed from r — the
// StdinStepRunner capability the resurrect restore uses to pipe the bundle's
// db.dump + media tarball into the on-box restore pipeline. It shells out
// DIRECTLY (not through r.Exec, whose signature carries no stdin), mirroring the
// transfer command's instSSHFeed: combined output rides back in the error on
// failure and is returned on success so a caller can look for a sentinel line. No
// per-step secret redaction — the restore script carries no secrets (the sealed
// identity is installed by InstallSecrets, a separate `</dev/null` step).
func (r *SSHStepRunner) RunFeed(ctx context.Context, title, script string, stdin io.Reader) (string, error) {
	key := r.Key
	if strings.TrimSpace(key) == "" {
		key = sshKeyPath()
	}
	argv := sshFeedArgv(r.User, r.Host, key, script, r.Sudo)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Stdin = stdin
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("ssh feed %q on %s: %w: %s", title, r.Host, err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// run dispatches the ssh argv via the injected Exec, falling back to runCapture
// (live ssh) when nil — the CloudDNS.run idiom.
func (r *SSHStepRunner) run(ctx context.Context, name string, args ...string) (string, error) {
	if r.Exec != nil {
		return r.Exec(ctx, name, args...)
	}
	return runCapture(ctx, name, args...)
}

// Run executes step s ON r.Host over SSH. Narration-only steps (empty Argv AND
// Cmd) are skipped, mirroring realStepRunner. On failure the captured ssh output
// is surfaced in the error — never a bare "exit status 1".
func (r *SSHStepRunner) Run(ctx context.Context, s CaddyStep) error {
	cmd := remoteCommand(s)
	if strings.TrimSpace(cmd) == "" {
		return nil // narration-only step
	}
	key := r.Key
	if strings.TrimSpace(key) == "" {
		key = sshKeyPath()
	}
	argv := sshStepArgv(r.User, r.Host, key, cmd, r.Sudo)
	if out, err := r.run(ctx, argv[0], argv[1:]...); err != nil {
		// Scrub any per-step secrets from the captured ssh output before it lands
		// in the error — the error flows to the worker's fail() POST and the
		// journal. scrubStepOutput applies BOTH the literal Redact (e.g. the minted
		// admin token) AND, for .env-sourcing steps (RedactEnvSecrets), pattern-based
		// redaction of the DB password / SECRET_KEY_BASE / cloak key shapes the
		// worker can't enumerate.
		return fmt.Errorf("ssh caddy step %q on %s: %w: %s", s.Title, r.Host, err, strings.TrimSpace(scrubStepOutput(out, s)))
	}
	return nil
}

// RunOutput runs an arbitrary shell script ON r.Host over SSH and RETURNS its
// combined stdout+stderr — the hostCommandRunner capability the freshen step
// (dwb-17) needs but the error-only Run cannot give (it must READ `git rev-parse`
// / `git describe` output to decide whether to rebuild and to narrate the version
// delta). It reuses the SAME base64-to-tempfile ssh plumbing as Run, so the
// multi-line freshen scripts survive the SSH boundary intact. No per-step secret
// redaction is applied — the freshen scripts carry no secrets (git/rev-parse/
// describe/merge/deploy-rebuild), and the caller wraps any error itself.
func (r *SSHStepRunner) RunOutput(ctx context.Context, script string) (string, error) {
	key := r.Key
	if strings.TrimSpace(key) == "" {
		key = sshKeyPath()
	}
	argv := sshStepArgv(r.User, r.Host, key, script, r.Sudo)
	return r.run(ctx, argv[0], argv[1:]...)
}

// sshReadyProbeInterval is the gap between WaitReady's SSH probes. A var (not a
// const) only so tests can shrink it; production never reassigns it.
var sshReadyProbeInterval = 5 * time.Second

// sshDeniedGrace is how long WaitReady keeps probing while sshd answers
// "Permission denied" before it gives up early. A freshly booted box can refuse
// a key for a few seconds while cloud-init writes authorized_keys, so a single
// refusal is not proof. A refusal that lasts this long is: the box trusts a key
// this machine does not hold, and waiting out the full timeout only hides that.
var sshDeniedGrace = 45 * time.Second

// SSHPermissionDeniedError is WaitReady's answer when sshd is up but refuses
// every key this machine offers. It is a different failure from "not up": the
// box is reachable and billing, and only a key change can fix it. Callers
// type-assert it (errors.As) to name the key the box trusts.
type SSHPermissionDeniedError struct {
	Host   string
	Key    string // the -i file offered, "" when only the agent was offered
	Output string // ssh's last refusal, trimmed
}

func (e *SSHPermissionDeniedError) Error() string {
	offered := "the ssh agent's keys"
	if e.Key != "" {
		offered = e.Key + " and the ssh agent's keys"
	}
	return fmt.Sprintf("ssh permission denied on %s: sshd is up but refuses %s (%s)", e.Host, offered, lastLine(e.Output))
}

// sshPermissionDenied reports whether a probe's captured output is sshd
// refusing authentication, as opposed to a connection that never opened.
func sshPermissionDenied(out string) bool {
	return strings.Contains(out, "Permission denied (")
}

// lastLine returns the last non-blank line of s, trimmed.
func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return l
		}
	}
	return ""
}

// WaitReady polls until the host accepts an SSH command — sshd is up and the key
// is accepted — or timeout elapses. A freshly-CREATED cloud box is NOT SSH-ready
// the instant the provider's create call returns: the OS is still booting, so the
// very first provisioning step otherwise hits "connect to host … port 22:
// Connection refused" (the warm-pool path masked this with incidental seed→pop
// delay; the one-shot path creates-then-configures immediately and exposed it).
// WaitReady closes the race by running a trivial `true` over SSH on a fixed
// interval until it succeeds. It honors ctx cancellation. A warm/already-booted
// host passes the first probe, so the wait is effectively free there.
//
// It tells two failures apart. When sshd keeps answering "Permission denied" for
// sshDeniedGrace, it returns *SSHPermissionDeniedError early instead of waiting
// out the timeout. Otherwise, on timeout, it returns "ssh not ready" with the
// last probe's own output, so "Connection refused" or "timed out" reads as the
// box not being up yet.
func (r *SSHStepRunner) WaitReady(ctx context.Context, timeout time.Duration) error {
	key := r.Key
	if strings.TrimSpace(key) == "" {
		key = sshKeyPath()
	}
	// Pure connectivity probe: SSH as r.User and run `true` WITHOUT sudo, so a fresh
	// azure box's readiness turns on sshd + key acceptance for `barkpark`, not on
	// waagent having finished writing sudoers (the first real step fails loudly if
	// passwordless sudo is missing). Hetzner keeps its byte-identical root probe.
	argv := sshStepArgv(r.User, r.Host, key, "true", false)
	deadline := time.Now().Add(timeout)
	var lastErr error
	var lastOut string
	var deniedSince time.Time
	for {
		out, err := r.run(ctx, argv[0], argv[1:]...)
		if err == nil {
			return nil
		}
		lastErr, lastOut = err, out
		if sshPermissionDenied(out) {
			if deniedSince.IsZero() {
				deniedSince = time.Now()
			}
			if time.Since(deniedSince) >= sshDeniedGrace {
				return &SSHPermissionDeniedError{Host: r.Host, Key: key, Output: out}
			}
		} else {
			deniedSince = time.Time{}
		}
		if !time.Now().Before(deadline) {
			if sshPermissionDenied(lastOut) {
				return &SSHPermissionDeniedError{Host: r.Host, Key: key, Output: lastOut}
			}
			if l := lastLine(lastOut); l != "" {
				return fmt.Errorf("ssh not ready on %s after %s (not up: %s): %w", r.Host, timeout, l, lastErr)
			}
			return fmt.Errorf("ssh not ready on %s after %s: %w", r.Host, timeout, lastErr)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(sshReadyProbeInterval):
		}
	}
}

// compile-time assertion that *SSHStepRunner satisfies the StepRunner seam AND the
// hostCommandRunner capture capability the freshen step (dwb-17) type-asserts.
var (
	_ StepRunner        = (*SSHStepRunner)(nil)
	_ hostCommandRunner = (*SSHStepRunner)(nil)
	_ StdinStepRunner   = (*SSHStepRunner)(nil)
)
