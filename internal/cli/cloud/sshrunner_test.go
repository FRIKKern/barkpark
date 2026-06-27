package cloud

import (
	"context"
	"encoding/base64"
	"fmt"
	"os/exec"
	"reflect"
	"strings"
	"testing"
	"time"
)

// TestSSHStepRunner_WaitReady_RetriesThenSucceeds proves WaitReady polls past a
// booting box's "connection refused" until sshd answers — the fresh-box race the
// one-shot path exposed live.
func TestSSHStepRunner_WaitReady_RetriesThenSucceeds(t *testing.T) {
	old := sshReadyProbeInterval
	sshReadyProbeInterval = time.Millisecond
	defer func() { sshReadyProbeInterval = old }()

	calls := 0
	r := &SSHStepRunner{Host: "10.0.0.9", Key: "/k", User: "root",
		Exec: func(_ context.Context, _ string, _ ...string) (string, error) {
			calls++
			if calls < 3 {
				return "ssh: connect to host 10.0.0.9 port 22: Connection refused", fmt.Errorf("exit status 255")
			}
			return "", nil
		}}
	if err := r.WaitReady(context.Background(), 5*time.Second); err != nil {
		t.Fatalf("WaitReady should succeed once SSH comes up, got: %v", err)
	}
	if calls != 3 {
		t.Errorf("want 3 probes (2 refused + 1 ok), got %d", calls)
	}
}

// TestSSHStepRunner_WaitReady_TimesOut proves WaitReady fails closed (and surfaces
// the last probe error) when SSH never comes up.
func TestSSHStepRunner_WaitReady_TimesOut(t *testing.T) {
	old := sshReadyProbeInterval
	sshReadyProbeInterval = time.Millisecond
	defer func() { sshReadyProbeInterval = old }()

	r := &SSHStepRunner{Host: "10.0.0.9", Key: "/k",
		Exec: func(_ context.Context, _ string, _ ...string) (string, error) {
			return "Connection refused", fmt.Errorf("exit status 255")
		}}
	err := r.WaitReady(context.Background(), 5*time.Millisecond)
	if err == nil {
		t.Fatal("WaitReady should time out when SSH never comes up")
	}
	if !strings.Contains(err.Error(), "not ready") {
		t.Errorf("timeout error should say 'not ready', got: %v", err)
	}
}

// TestSSHStepRunner_WaitReady_HonorsCancel proves a cancelled ctx aborts the wait
// (the per-job timeout cancels the ctx; the wait must not outlive it).
func TestSSHStepRunner_WaitReady_HonorsCancel(t *testing.T) {
	old := sshReadyProbeInterval
	sshReadyProbeInterval = time.Hour // force the select to block on ctx, not the timer
	defer func() { sshReadyProbeInterval = old }()

	r := &SSHStepRunner{Host: "10.0.0.9", Key: "/k",
		Exec: func(_ context.Context, _ string, _ ...string) (string, error) {
			return "refused", fmt.Errorf("exit status 255")
		}}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := r.WaitReady(ctx, time.Hour); err == nil {
		t.Fatal("WaitReady should return when ctx is cancelled")
	}
}

// decodeRemote extracts the original script from the runner's base64 remote
// command. The remote shape decodes the blob to a temp file and runs it with
// stdin closed:
//
//	b=$(mktemp); echo <b64> | base64 -d > "$b"; bash -l "$b" </dev/null; rc=$?; rm -f "$b"; exit $rc
//
// The base64 wrapping is what makes a multi-command script survive ssh's arg-join
// + the remote shell's re-parse; the temp-file + </dev/null is what stops an inner
// stdin-reading command from eating the rest of the script. This helper lets tests
// assert the DECODED command rather than a brittle hardcoded blob.
func decodeRemote(t *testing.T, remote string) string {
	t.Helper()
	const pre = `b=$(mktemp); echo `
	const post = ` | base64 -d > "$b"; bash -l "$b" </dev/null; rc=$?; rm -f "$b"; exit $rc`
	if !strings.HasPrefix(remote, pre) || !strings.HasSuffix(remote, post) {
		t.Fatalf("remote command not in the base64→tempfile→`bash -l \"$b\" </dev/null` form: %q", remote)
	}
	b64 := strings.TrimSuffix(strings.TrimPrefix(remote, pre), post)
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("remote b64 decode: %v", err)
	}
	return string(raw)
}

// TestSSHStepArgv_Exact pins the ssh flags + that the remote command is the
// base64-pipe form whose decoded payload is the step's script. The base64
// wrapping is the contract (the naive `bash -lc <script>` is broken — ssh+shell
// re-split it), so drift fails here rather than silently on a live box.
func TestSSHStepArgv_Exact(t *testing.T) {
	cmd := "cd /opt/barkpark/api && mix ecto.migrate"
	got := sshStepArgv("root", "203.0.113.7", "/keys/barkpark_indx", cmd)
	wantPrefix := []string{
		"ssh",
		"-i", "/keys/barkpark_indx",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=20",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=4",
		"root@203.0.113.7",
	}
	if len(got) != len(wantPrefix)+1 {
		t.Fatalf("want the host options + a single remote-command arg, got %d args: %#v", len(got), got)
	}
	if !reflect.DeepEqual(got[:len(wantPrefix)], wantPrefix) {
		t.Errorf("ssh flag prefix mismatch:\n got: %#v\nwant: %#v", got[:len(wantPrefix)], wantPrefix)
	}
	if dec := decodeRemote(t, got[len(got)-1]); dec != cmd {
		t.Errorf("decoded remote command = %q, want %q", dec, cmd)
	}
}

// TestRemoteTransport_StdinClosed_TailSurvives proves the base64→tempfile→
// `bash -l "$b" </dev/null` transport runs the WHOLE script even when an inner
// command reads stdin. With the old `… | base64 -d | bash -l` (script on stdin),
// the first stdin-reading command ate the rest of the script; closing stdin fixes
// it. This runs the EXACT remote string the runner builds through a LOCAL bash
// (no ssh, no box, no spend) and asserts the tail line — after a `cat` that would
// have eaten the rest — still executes.
func TestRemoteTransport_StdinClosed_TailSurvives(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not on PATH — skipping the local transport harness")
	}
	// A two-line script: the first line reads stdin (would eat the tail under the
	// old pipe transport); the second line is the tail we assert survives.
	script := "cat >/dev/null\necho TAIL_SURVIVED"

	// Build the remote command exactly as the runner does, then run it locally.
	// The remote is the last argv element; we feed local bash the SAME data on
	// stdin that ssh would, to prove the script's </dev/null isolates it.
	argv := sshStepArgv("root", "10.0.0.5", "/keys/k", script)
	remote := argv[len(argv)-1]

	cmd := exec.Command("bash", "-c", remote)
	cmd.Stdin = strings.NewReader("DATA_THAT_MUST_NOT_BE_EATEN\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("local transport harness failed: %v\noutput: %s", err, out)
	}
	if !strings.Contains(string(out), "TAIL_SURVIVED") {
		t.Errorf("tail line did not run — stdin-eating regressed; output: %q", out)
	}
}

// fakeSSHExec records every argv handed to it and can be told to fail with a
// canned combined-output blob — the exec seam for SSHStepRunner.Run so no real
// ssh is invoked.
type fakeSSHExec struct {
	calls   [][]string
	failOut string // when non-empty, run returns this output + an error
}

func (f *fakeSSHExec) run(_ context.Context, name string, args ...string) (string, error) {
	argv := append([]string{name}, args...)
	f.calls = append(f.calls, argv)
	if f.failOut != "" {
		return f.failOut, fmt.Errorf("exit status 1")
	}
	return "ok", nil
}

// TestSSHStepRunner_Run_RecordsArgv proves Run dispatches the right ssh argv for
// a real step: the bash -lc script is unwrapped and re-sent as the single remote
// command, and the host/key/user are wired in.
func TestSSHStepRunner_Run_RecordsArgv(t *testing.T) {
	exec := &fakeSSHExec{}
	r := &SSHStepRunner{Host: "10.0.0.5", Key: "/keys/k", User: "root", Exec: exec.run}

	step := CaddyStep{
		Title: "set PHX_HOST",
		Cmd:   "bash -lc '…'",
		Argv:  []string{"bash", "-lc", "echo 'PHX_HOST=acme.barkpark.cloud' >> /opt/barkpark/api/.env"},
	}
	if err := r.Run(context.Background(), step); err != nil {
		t.Fatalf("Run: unexpected error: %v", err)
	}
	if len(exec.calls) != 1 {
		t.Fatalf("want exactly 1 ssh call, got %d", len(exec.calls))
	}
	got := exec.calls[0]
	wantPrefix := []string{
		"ssh",
		"-i", "/keys/k",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=20",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=4",
		"root@10.0.0.5",
	}
	if !reflect.DeepEqual(got[:len(wantPrefix)], wantPrefix) {
		t.Errorf("ssh flag prefix mismatch:\n got: %#v\nwant: %#v", got[:len(wantPrefix)], wantPrefix)
	}
	if dec := decodeRemote(t, got[len(got)-1]); dec != "echo 'PHX_HOST=acme.barkpark.cloud' >> /opt/barkpark/api/.env" {
		t.Errorf("decoded remote command = %q", dec)
	}
}

// TestSSHStepRunner_Run_BareBinaryStep proves a non-bash-lc step (e.g. ufw deny
// 4000) is shell-joined into one remote command rather than mangled.
func TestSSHStepRunner_Run_BareBinaryStep(t *testing.T) {
	exec := &fakeSSHExec{}
	r := &SSHStepRunner{Host: "10.0.0.5", Key: "/keys/k", Exec: exec.run}

	step := CaddyStep{Title: "ufw deny", Cmd: "ufw deny 4000", Argv: []string{"ufw", "deny", "4000"}}
	if err := r.Run(context.Background(), step); err != nil {
		t.Fatalf("Run: unexpected error: %v", err)
	}
	got := exec.calls[0]
	// The remote command (last arg) decodes to the shell-joined bare binary.
	if dec := decodeRemote(t, got[len(got)-1]); dec != "ufw deny 4000" {
		t.Errorf("decoded remote command = %q, want %q", dec, "ufw deny 4000")
	}
}

// TestSSHStepRunner_Run_SurfacesStderr proves a failed step surfaces the captured
// ssh output in the error — never a bare "exit status 1".
func TestSSHStepRunner_Run_SurfacesStderr(t *testing.T) {
	exec := &fakeSSHExec{failOut: "Permission denied (publickey)."}
	r := &SSHStepRunner{Host: "10.0.0.5", Key: "/keys/k", Exec: exec.run}

	step := CaddyStep{Title: "install Caddy", Argv: []string{"bash", "-lc", "apt-get install -y caddy"}}
	err := r.Run(context.Background(), step)
	if err == nil {
		t.Fatal("Run: want an error when ssh fails, got nil")
	}
	if !strings.Contains(err.Error(), "Permission denied (publickey)") {
		t.Errorf("error must surface captured ssh output, got: %v", err)
	}
	if !strings.Contains(err.Error(), "install Caddy") {
		t.Errorf("error should name the step title, got: %v", err)
	}
	if !strings.Contains(err.Error(), "10.0.0.5") {
		t.Errorf("error should name the host, got: %v", err)
	}
}

// TestSSHStepRunner_Run_RedactsSecretsInError proves the secret-redaction
// contract: when a step carries Redact substrings and the ssh exec returns
// output CONTAINING one of them (e.g. the remote elixir echoed the admin token
// on error), Run scrubs it from the captured output BEFORE wrapping it in the
// error — so the token never reaches the worker's fail() POST or the journal.
func TestSSHStepRunner_Run_RedactsSecretsInError(t *testing.T) {
	const token = "bp_admin_supersecretvalue123456789012"
	exec := &fakeSSHExec{failOut: "create_token failed; BP_TOK=" + token + " rejected"}
	r := &SSHStepRunner{Host: "10.0.0.5", Key: "/keys/k", Exec: exec.run}

	step := adminTokenStep(token) // carries Redact: [token]
	err := r.Run(context.Background(), step)
	if err == nil {
		t.Fatal("Run: want an error when the admin-token step fails, got nil")
	}
	if strings.Contains(err.Error(), token) {
		t.Errorf("error leaked the raw admin token (redaction failed): %v", err)
	}
	if !strings.Contains(err.Error(), "[REDACTED]") {
		t.Errorf("error should carry the scrubbed placeholder where the token was, got: %v", err)
	}
}

// TestSSHStepRunner_Run_HonorsUser proves a non-root User on the runner is
// threaded into the ssh target rather than silently hardcoded to root.
func TestSSHStepRunner_Run_HonorsUser(t *testing.T) {
	exec := &fakeSSHExec{}
	r := &SSHStepRunner{Host: "10.0.0.5", Key: "/keys/k", User: "deploy", Exec: exec.run}

	step := CaddyStep{Title: "x", Argv: []string{"bash", "-lc", "true"}}
	if err := r.Run(context.Background(), step); err != nil {
		t.Fatalf("Run: %v", err)
	}
	got := exec.calls[0]
	target := got[len(got)-2] // the user@host arg sits just before the remote command
	if target != "deploy@10.0.0.5" {
		t.Errorf("ssh target = %q, want deploy@10.0.0.5 (User must be honored)", target)
	}
}

// TestRemoteCommand_ExactBashLC proves remoteCommand unwraps the EXACT
// ["bash","-lc",<script>] form to <script>, but does NOT silently drop trailing
// args on a malformed longer argv — it falls through to a shell-join so the extra
// args remain visible/runnable instead of being truncated to script-only.
func TestRemoteCommand_ExactBashLC(t *testing.T) {
	if got := remoteCommand(CaddyStep{Argv: []string{"bash", "-lc", "echo hi"}}); got != "echo hi" {
		t.Errorf("exact bash -lc form: got %q, want %q", got, "echo hi")
	}
	// A 4-element argv must NOT be unwrapped to Argv[2] (that would drop "extra").
	got := remoteCommand(CaddyStep{Argv: []string{"bash", "-lc", "echo hi", "extra"}})
	if got == "echo hi" {
		t.Errorf("remoteCommand dropped trailing argv: got %q (Argv[3:] was silently lost)", got)
	}
	if !strings.Contains(got, "extra") {
		t.Errorf("remoteCommand should preserve the trailing arg, got %q", got)
	}
}

// TestAdminTokenStep_GuardAndRedact asserts at the Go string-construction level
// (we cannot run elixir here) that the admin-token step's script halts non-zero
// unless create_token returns {:ok, _} — the fail-loud guard that stops a
// swallowed error from bricking the instance to zero admin tokens — and that the
// step carries the token in Redact so any captured output is scrubbed.
func TestAdminTokenStep_GuardAndRedact(t *testing.T) {
	const token = "bp_admin_examplexampleexampleexample12"
	step := adminTokenStep(token)
	script := step.Argv[2]

	// The fail-loud guard: a case on create_token's result that halts non-zero.
	for _, want := range []string{"case Barkpark.Auth.create_token(", "{:ok, _} -> :ok", "System.halt(1)"} {
		if !strings.Contains(script, want) {
			t.Errorf("admin-token script missing fail-loud guard fragment %q; script:\n%s", want, script)
		}
	}
	// Redact carries the token so a failure scrubs it.
	if len(step.Redact) != 1 || step.Redact[0] != token {
		t.Errorf("admin-token step Redact = %v, want [%s]", step.Redact, token)
	}
	// The human-facing Title/Cmd must not carry the raw token.
	if strings.Contains(step.Title, token) || strings.Contains(step.Cmd, token) {
		t.Errorf("admin-token step Title/Cmd leaked the token: title=%q cmd=%q", step.Title, step.Cmd)
	}
}

// TestSSHStepRunner_Run_SkipsNarration proves a narration-only step (empty Argv
// AND Cmd) never reaches the exec seam — mirroring realStepRunner.
func TestSSHStepRunner_Run_SkipsNarration(t *testing.T) {
	exec := &fakeSSHExec{}
	r := &SSHStepRunner{Host: "10.0.0.5", Key: "/keys/k", Exec: exec.run}

	if err := r.Run(context.Background(), CaddyStep{Title: "narration only"}); err != nil {
		t.Fatalf("Run: narration step should be a no-op, got error: %v", err)
	}
	if len(exec.calls) != 0 {
		t.Errorf("narration-only step must not shell out; got %d ssh calls", len(exec.calls))
	}
}

// TestProvision_PerHostRunner proves the warm-pool chain builds the runner FOR
// the assigned host's IP and runs the Caddy + migrate steps through it. The
// factory receives exactly the popped host IP — the whole point of the per-host
// seam (the steps must target the new box, not the worker).
func TestProvision_PerHostRunner(t *testing.T) {
	spec := acmeSpec()
	prov := NewFakeProvider()
	dns := NewFakeDNS()
	reg := NewFakeRegistry()
	pool, err := SeedPool(context.Background(), prov, 1, ServerSpec{Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"})
	if err != nil {
		t.Fatalf("SeedPool: %v", err)
	}

	before, _ := prov.List(context.Background())
	assignedIP := before[0].IP

	// Capture the host the factory is asked to build for, and record steps.
	var gotHost string
	runner := &recordingRunner{}
	wp := &WarmPool{
		Pool: pool,
		DNS:  dns,
		RunnerFor: func(host string) StepRunner {
			gotHost = host
			return runner
		},
		Health:   greenGate(spec.healthTarget()),
		Registry: reg,
	}

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if gotHost != assignedIP {
		t.Errorf("RunnerFor got host %q, want the popped host IP %q", gotHost, assignedIP)
	}
	all := runner.joined()
	if !strings.Contains(all, "PHX_HOST=acme.barkpark.cloud") {
		t.Errorf("Caddy steps did not run through the per-host runner; ran:\n%s", all)
	}
	if !strings.Contains(all, "ecto.migrate") {
		t.Errorf("migrate step did not run through the per-host runner; ran:\n%s", all)
	}
}

// TestProvision_DefaultsToSSHRunnerFactory proves that with no runner injected,
// withDefaults wires the production SSH factory — the default RunnerFor returns
// an *SSHStepRunner bound to the assigned host.
func TestProvision_DefaultsToSSHRunnerFactory(t *testing.T) {
	wp := &WarmPool{}
	wp.withDefaults()
	if wp.RunnerFor == nil {
		t.Fatal("withDefaults left RunnerFor nil")
	}
	r := wp.RunnerFor("198.51.100.9")
	ssh, ok := r.(*SSHStepRunner)
	if !ok {
		t.Fatalf("default RunnerFor returned %T, want *SSHStepRunner", r)
	}
	if ssh.Host != "198.51.100.9" {
		t.Errorf("default SSH runner Host = %q, want the assigned host", ssh.Host)
	}
	if ssh.User != "root" {
		t.Errorf("default SSH runner User = %q, want root", ssh.User)
	}
}

// TestProvision_LegacyRunnerBackCompat proves a legacy host-agnostic Runner
// (injected, no RunnerFor) is still honored — wrapped in a host-ignoring factory
// so old callers and fakes keep working.
func TestProvision_LegacyRunnerBackCompat(t *testing.T) {
	runner := &recordingRunner{}
	wp := &WarmPool{Runner: runner}
	wp.withDefaults()
	if wp.RunnerFor == nil {
		t.Fatal("withDefaults left RunnerFor nil despite a legacy Runner")
	}
	if got := wp.RunnerFor("any-host"); got != StepRunner(runner) {
		t.Errorf("legacy Runner not honored: factory returned %v, want the injected runner", got)
	}
}
