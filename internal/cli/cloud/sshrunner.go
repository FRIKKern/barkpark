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
	"os"
	"path/filepath"
	"strings"
	"time"
)

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
// set, else ~/.ssh/barkpark_indx (the key the warm pool seeds its hosts with).
func sshKeyPath() string {
	if k := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY_FILE")); k != "" {
		return k
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ".ssh/barkpark_indx"
	}
	return filepath.Join(home, ".ssh", "barkpark_indx")
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
// unexported helper). Tokens with whitespace or quotes are single-quoted.
func shJoinArgv(argv []string) string {
	parts := make([]string, len(argv))
	for i, a := range argv {
		if strings.ContainsAny(a, " \t\"'") {
			parts[i] = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
		} else {
			parts[i] = a
		}
	}
	return strings.Join(parts, " ")
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
//	-i <key>                              the provisioning private key
//	-o UserKnownHostsFile=/dev/null       don't pollute ~/.ssh/known_hosts
//	-o StrictHostKeyChecking=accept-new   accept a fresh box's key, reject changes
//	-o BatchMode=yes                       never prompt (fail instead of hanging)
//	-o ConnectTimeout=20                   bounded connect
//	-o ServerAliveInterval=15             ping a quiet connection every 15s …
//	-o ServerAliveCountMax=4              … and give up after 4 missed (≈60s) so a
//	                                       dead box/long step fails instead of hanging
func sshStepArgv(user, host, key, cmd string) []string {
	if strings.TrimSpace(user) == "" {
		user = defaultSSHUser
	}
	b64 := base64.StdEncoding.EncodeToString([]byte(cmd))
	// Decode to a temp file and run with stdin closed (see the stdin-eating note).
	remote := `b=$(mktemp); echo ` + b64 + ` | base64 -d > "$b"; bash -l "$b" </dev/null; rc=$?; rm -f "$b"; exit $rc`
	return []string{
		"ssh",
		"-i", key,
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=20",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=4",
		user + "@" + host,
		remote,
	}
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
	argv := sshStepArgv(r.User, r.Host, key, cmd)
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

// sshReadyProbeInterval is the gap between WaitReady's SSH probes. A var (not a
// const) only so tests can shrink it; production never reassigns it.
var sshReadyProbeInterval = 5 * time.Second

// WaitReady polls until the host accepts an SSH command — sshd is up and the key
// is accepted — or timeout elapses. A freshly-CREATED cloud box is NOT SSH-ready
// the instant the provider's create call returns: the OS is still booting, so the
// very first provisioning step otherwise hits "connect to host … port 22:
// Connection refused" (the warm-pool path masked this with incidental seed→pop
// delay; the one-shot path creates-then-configures immediately and exposed it).
// WaitReady closes the race by running a trivial `true` over SSH on a fixed
// interval until it succeeds. It honors ctx cancellation and returns the last
// probe error on timeout. A warm/already-booted host passes the first probe, so
// the wait is effectively free there.
func (r *SSHStepRunner) WaitReady(ctx context.Context, timeout time.Duration) error {
	key := r.Key
	if strings.TrimSpace(key) == "" {
		key = sshKeyPath()
	}
	argv := sshStepArgv(r.User, r.Host, key, "true")
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		if _, err := r.run(ctx, argv[0], argv[1:]...); err == nil {
			return nil
		} else {
			lastErr = err
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("ssh not ready on %s after %s: %w", r.Host, timeout, lastErr)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(sshReadyProbeInterval):
		}
	}
}

// compile-time assertion that *SSHStepRunner satisfies the StepRunner seam.
var _ StepRunner = (*SSHStepRunner)(nil)
