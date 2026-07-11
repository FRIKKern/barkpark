package cloud

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"
)

// azure_restore_ssh_test.go proves the D56 azure-restore ssh-user fix: an AZURE
// resurrect SSHes as the non-root `barkpark` admin and sudo-wraps every restore
// step (azure boxes provision only that admin; azure-base-install + the on-box
// restore pipeline need root), while HETZNER — and the warm-pool / deploy-feeder
// paths that share the same runner factory — stay byte-identical (root, no sudo).

// decodeSudoPayload extracts the original script from the base64→tempfile remote
// command regardless of the run prefix (`bash -l` or `sudo -n bash -l`), so a test
// can assert the wrapped script's bytes.
func decodeSudoPayload(t *testing.T, remote string) string {
	t.Helper()
	const pre = `b=$(mktemp); echo `
	const mid = ` | base64 -d > "$b"; `
	i := strings.Index(remote, pre)
	j := strings.Index(remote, mid)
	if i != 0 || j < 0 {
		t.Fatalf("remote not in the base64→tempfile form: %q", remote)
	}
	b64 := remote[len(pre):j]
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("remote b64 decode: %v", err)
	}
	return string(raw)
}

// TestRestoreRunner_AzurePicksBarkparkSudo proves restoreRunner sets the non-root
// admin + sudo for an azure kind and leaves every other kind byte-identical (root,
// no sudo) — the REFUTE guard at the policy-selection seam.
func TestRestoreRunner_AzurePicksBarkparkSudo(t *testing.T) {
	e := &RestoreExecutor{RunnerFor: func(host string) StepRunner {
		return NewSSHStepRunner(host) // production factory: User=root, Sudo=false
	}}

	az, ok := e.restoreRunner(ProviderAzure, "10.0.0.7").(*SSHStepRunner)
	if !ok {
		t.Fatalf("azure restoreRunner is not an *SSHStepRunner")
	}
	if az.User != azureRestoreUser {
		t.Errorf("azure ssh user = %q, want %q (the box's only admin)", az.User, azureRestoreUser)
	}
	if az.User != "barkpark" {
		t.Errorf("azure ssh user = %q, want the literal barkpark admin", az.User)
	}
	if !az.Sudo {
		t.Error("azure restore runner must sudo-wrap (barkpark reaches root via passwordless sudo)")
	}

	// Hetzner and an empty/legacy kind keep the byte-identical root/no-sudo path.
	for _, kind := range []string{ProviderHetzner, ""} {
		r, ok := e.restoreRunner(kind, "10.0.0.8").(*SSHStepRunner)
		if !ok {
			t.Fatalf("%q restoreRunner is not an *SSHStepRunner", kind)
		}
		if r.User != "root" {
			t.Errorf("kind %q ssh user = %q, want root (unchanged)", kind, r.User)
		}
		if r.Sudo {
			t.Errorf("kind %q must NOT sudo-wrap (root path is byte-identical)", kind)
		}
	}
}

// TestRestoreExecutor_AzureFreshenSSHesAsBarkparkWithSudo drives the executor's
// freshen step through a RECORDING ssh exec and asserts the argv: the target user
// is barkpark, the remote command sudo-wraps, and the azure-base-install script
// rides inside the sudo-wrapped payload — the criterion-1 proof end to end.
func TestRestoreExecutor_AzureFreshenSSHesAsBarkparkWithSudo(t *testing.T) {
	rec := &fakeSSHExec{}
	e := &RestoreExecutor{RunnerFor: func(host string) StepRunner {
		return &SSHStepRunner{Host: host, Key: "/k", Exec: rec.run}
	}}

	if err := e.Freshen(context.Background(), ProviderAzure, "10.0.0.7"); err != nil {
		t.Fatalf("azure Freshen: %v", err)
	}
	if len(rec.calls) != 1 {
		t.Fatalf("want exactly 1 ssh call, got %d", len(rec.calls))
	}
	argv := rec.calls[0]
	if target := argv[len(argv)-2]; target != "barkpark@10.0.0.7" {
		t.Errorf("azure freshen ssh target = %q, want barkpark@10.0.0.7", target)
	}
	remote := argv[len(argv)-1]
	if !strings.Contains(remote, "sudo -n bash -l") {
		t.Errorf("azure freshen must sudo-wrap the step (barkpark→root); remote = %q", remote)
	}
	if dec := decodeSudoPayload(t, remote); !strings.Contains(dec, AzureBaseInstallScript) {
		t.Errorf("the sudo-wrapped payload must run %s; decoded = %q", AzureBaseInstallScript, dec)
	}
}

// TestRestoreExecutor_HetznerFreshenStaysRootNoSudo is the REFUTE twin: the same
// executor step on a hetzner kind SSHes as root and runs `bash -l "$b"` with NO
// sudo — byte-identical to the pre-fix behaviour.
func TestRestoreExecutor_HetznerFreshenStaysRootNoSudo(t *testing.T) {
	rec := &fakeSSHExec{}
	e := &RestoreExecutor{RunnerFor: func(host string) StepRunner {
		return &SSHStepRunner{Host: host, Key: "/k", User: "root", Exec: rec.run}
	}}

	if err := e.Freshen(context.Background(), ProviderHetzner, "10.0.0.9"); err != nil {
		t.Fatalf("hetzner Freshen: %v", err)
	}
	argv := rec.calls[0]
	if target := argv[len(argv)-2]; target != "root@10.0.0.9" {
		t.Errorf("hetzner freshen ssh target = %q, want root@10.0.0.9", target)
	}
	remote := argv[len(argv)-1]
	if strings.Contains(remote, "sudo") {
		t.Errorf("hetzner freshen must NOT sudo-wrap (byte-identical root path); remote = %q", remote)
	}
	if !strings.Contains(remote, `bash -l "$b" </dev/null`) {
		t.Errorf("hetzner freshen must keep the byte-identical `bash -l \"$b\" </dev/null` form; remote = %q", remote)
	}
}

// TestSSHArgvSudoPrefix pins the transport-level contract both restore paths ride:
// sudo=true wraps `sudo -n bash -l` (step + feed), sudo=false is byte-identical to
// the pre-fix root form.
func TestSSHArgvSudoPrefix(t *testing.T) {
	// Step path (stdin closed).
	sudoStep := sshStepArgv("barkpark", "1.2.3.4", "/k", "true", true)
	if !strings.Contains(sudoStep[len(sudoStep)-1], `sudo -n bash -l "$b" </dev/null`) {
		t.Errorf("sudo step must run `sudo -n bash -l \"$b\" </dev/null`; got %q", sudoStep[len(sudoStep)-1])
	}
	rootStep := sshStepArgv("root", "1.2.3.4", "/k", "true", false)
	if strings.Contains(rootStep[len(rootStep)-1], "sudo") {
		t.Errorf("root step must NOT carry sudo; got %q", rootStep[len(rootStep)-1])
	}

	// Feed path (stdin kept open for the bundle tar). sudo passes stdin through.
	sudoFeed := sshFeedArgv("barkpark", "1.2.3.4", "/k", "tar -xzf -", true)
	last := sudoFeed[len(sudoFeed)-1]
	if !strings.Contains(last, `sudo -n bash -l "$b"`) {
		t.Errorf("sudo feed must run `sudo -n bash -l \"$b\"`; got %q", last)
	}
	if strings.Contains(last, "</dev/null") {
		t.Errorf("the feed must keep stdin open (no </dev/null) so the bundle tar reaches the box; got %q", last)
	}
	rootFeed := sshFeedArgv("root", "1.2.3.4", "/k", "tar -xzf -", false)
	if strings.Contains(rootFeed[len(rootFeed)-1], "sudo") {
		t.Errorf("root feed must NOT carry sudo; got %q", rootFeed[len(rootFeed)-1])
	}
}
