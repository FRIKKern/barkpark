package cli

// Tests for the `bp cloud support add` fixes measured on fleet-1 (2026-10-14):
// the --ssh-key flag, the permission-denied vs not-up wait-ready failure, and
// the re-run that reuses the labeled box and resumes from its progress file.

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// supportResumeMain serves a main whose roster row reads online with capacity.
func supportResumeMain(t *testing.T) (*supportMainRecorder, string) {
	t.Helper()
	main := newSupportMainRecorder()
	main.rosterRow = map[string]any{
		"worker": "hex", "status": "idle",
		"capacity": map[string]any{"size_class": "standard", "slots_total": 1, "slots_free": 1},
	}
	srv := main.serve(t)
	supportSeedCP(t, srv.URL)
	return main, srv.URL
}

// TestCloudSupportAddHelpNamesSSHKey: --help names the flag and the env var.
func TestCloudSupportAddHelpNamesSSHKey(t *testing.T) {
	supportEnvIsolate(t)
	stdout, _, code := runSupport(t, globals{help: true}, "add")
	if code != exitOK {
		t.Fatalf("help exit %d", code)
	}
	for _, want := range []string{"--ssh-key <hetzner-key-name>", "BARKPARK_SSH_KEY", "BARKPARK_SSH_KEY_FILE", "RE-RUN AFTER A FAILURE"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("help should name %q\n%s", want, stdout)
		}
	}
}

// TestCloudSupportAddSSHKeyFlag: --ssh-key sets BARKPARK_SSH_KEY for the create
// (both Hetzner providers read it there) and the create line names the key.
func TestCloudSupportAddSSHKeyFlag(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	supportSSHKeyName = func(context.Context) (string, bool, error) {
		return os.Getenv("BARKPARK_SSH_KEY"), false, nil
	}
	var keyAtCreate string
	supportCreateServer = func(_ context.Context, _ cloud.CloudProvider, _ string, name string) (cloud.Server, error) {
		keyAtCreate = os.Getenv("BARKPARK_SSH_KEY")
		return cloud.Server{Name: "warm-cafe01", IP: "203.0.113.9", Labels: map[string]string{cloud.FleetSupportLabelKey: name}}, nil
	}
	_, url := supportResumeMain(t)

	stdout, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--ssh-key", "frikk-mac", "--parent", "cp-row-7")
	if code != exitOK {
		t.Fatalf("want OK, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if keyAtCreate != "frikk-mac" {
		t.Fatalf("create should see BARKPARK_SSH_KEY=frikk-mac, saw %q", keyAtCreate)
	}
	if !strings.Contains(stdout, `the box will trust Hetzner ssh key "frikk-mac"`) {
		t.Fatalf("create should name the key\nstdout:\n%s", stdout)
	}

	_, stderr, code = runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--ssh-key", "bad key;rm")
	if code != exitUsage || !strings.Contains(stderr, "invalid --ssh-key") {
		t.Fatalf("an unsafe key name must be a usage error, got %d\n%s", code, stderr)
	}
}

// TestCloudSupportAddAutoKeyWarns: a key picked only because it is the project's
// single key is called out before the box bills.
func TestCloudSupportAddAutoKeyWarns(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	supportSSHKeyName = func(context.Context) (string, bool, error) { return "barkpark-indx", true, nil }
	_, url := supportResumeMain(t)

	_, stderr, _ := runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
	if !strings.Contains(stderr, `Hetzner ssh key "barkpark-indx", the only key in the project`) || !strings.Contains(stderr, "--ssh-key") || !strings.Contains(stderr, "BARKPARK_SSH_KEY") {
		t.Fatalf("auto-selected key should be named with the way out\nstderr:\n%s", stderr)
	}
}

// TestCloudSupportAddWaitReadyPermissionDenied: sshd refusing this machine reads
// as permission denied, names the key the box trusts, and says how to pass one.
func TestCloudSupportAddWaitReadyPermissionDenied(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	runner.waitErr = &cloud.SSHPermissionDeniedError{Host: "203.0.113.9", Output: "root@203.0.113.9: Permission denied (publickey,password)."}
	supportSSHKeyName = func(context.Context) (string, bool, error) { return "barkpark-indx", true, nil }
	main, url := supportResumeMain(t)

	_, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
	if code == exitOK {
		t.Fatal("want a wait-ready failure")
	}
	for _, want := range []string{"permission denied", `trusts Hetzner ssh key "barkpark-indx"`, "--ssh-key", "BARKPARK_SSH_KEY", "reuses this box"} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("stderr should carry %q\n%s", want, stderr)
		}
	}
	if strings.Contains(stderr, "not up") {
		t.Fatalf("a permission-denied box must not read as not up\n%s", stderr)
	}
	if main.count("POST") != 0 {
		t.Fatalf("nothing may be written to the main: %v", main.requests)
	}
}

// TestCloudSupportAddWaitReadyNotUp: a box that never answers reads as not up.
func TestCloudSupportAddWaitReadyNotUp(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	runner.waitErr = errors.New("ssh not ready on 203.0.113.9 after 3m0s (not up: Connection refused): exit status 255")
	_, url := supportResumeMain(t)

	_, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
	if code == exitOK {
		t.Fatal("want a wait-ready failure")
	}
	if !strings.Contains(stderr, "the box is not up yet") || strings.Contains(stderr, "permission denied") {
		t.Fatalf("not-up should read as not up\n%s", stderr)
	}
}

// TestCloudSupportAddRecordsProgress: each resumable step appends done=<step>
// to the box's progress file, with the credentials it carries redacted.
func TestCloudSupportAddRecordsProgress(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	_, url := supportResumeMain(t)

	stdout, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
	if code != exitOK {
		t.Fatalf("want OK, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	seen := map[string]cloud.CaddyStep{}
	for _, s := range runner.steps {
		if strings.HasPrefix(s.Title, "record support-add progress (") {
			seen[strings.TrimSuffix(strings.TrimPrefix(s.Title, "record support-add progress ("), ")")] = s
		}
	}
	for _, step := range []string{"roster-row", "configure", "bind", "dataset", "runtime"} {
		s, ok := seen[step]
		if !ok {
			t.Fatalf("no progress record for %s; steps: %s", step, runner.scripts())
		}
		if !strings.Contains(strings.Join(s.Argv, " "), "'done="+step+"'") {
			t.Fatalf("%s record should append done=%s: %v", step, step, s.Argv)
		}
	}
	if len(seen) != 5 {
		t.Fatalf("only resumable steps record progress, got %v", seen)
	}
	cfg := seen["configure"]
	if len(cfg.Redact) != 1 || cfg.Redact[0] != "box-admin-tok-xyz" || !strings.Contains(strings.Join(cfg.Argv, " "), "admin_token=box-admin-tok-xyz") {
		t.Fatalf("configure record should carry the admin token, redacted: redact=%v", cfg.Redact)
	}
	bind := seen["bind"]
	if len(bind.Redact) == 0 || !strings.Contains(strings.Join(bind.Argv, " "), "ledger_token=") {
		t.Fatalf("bind record should carry the ledger token, redacted: redact=%d argv=%v", len(bind.Redact), bind.Argv)
	}
}

// TestCloudSupportAddResumeReusesLabeledBox: with a box already labeled for the
// name, the re-run never creates, skips the steps its progress file records,
// restores their credentials, and continues to online.
func TestCloudSupportAddResumeReusesLabeledBox(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	p := supportSeedBox(t, nil, "warm-2432af65", "hex")
	supportCreateServer = func(context.Context, cloud.CloudProvider, string, string) (cloud.Server, error) {
		t.Fatal("a labeled box exists: the re-run must not create another")
		return cloud.Server{}, nil
	}
	supportConfigureHost = func(context.Context, cloud.SupportRunner, cloud.SupportConfigureOpts) (cloud.Secrets, error) {
		t.Fatal("configure is recorded as done: it must be skipped")
		return cloud.Secrets{}, nil
	}
	var dialed string
	supportRunnerFor = func(ip string) cloud.SupportRunner { dialed = ip; return runner }
	runner.outputs[supportProgressReadScript] = "Warning: Permanently added '10.0.0.1' (ED25519) to the list of known hosts.\n" +
		"done=roster-row\ndone=configure\nadmin_token=bp_admin_RESUMEtok123\n"
	main, url := supportResumeMain(t)

	stdout, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
	if code != exitOK {
		t.Fatalf("want OK, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	boxes, _ := p.ListByLabel(context.Background(), cloud.FleetSupportLabelKey, "hex")
	if len(boxes) != 1 || dialed != boxes[0].IP {
		t.Fatalf("want the one seeded box reused (dialed %q, boxes %v)", dialed, boxes)
	}
	for _, want := range []string{"reusing warm-2432af65", "this box already finished: roster-row, configure",
		"✓ roster-row — already done on this box", "✓ configure — already done on this box"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout should carry %q\n%s", want, stdout)
		}
	}
	if main.count("POST /v1/data/mutate/") != 0 {
		t.Fatalf("roster-row is recorded as done: no mutate expected, got %v", main.requests)
	}
	if main.count("POST /v1/fleet/support-tokens") != 1 {
		t.Fatalf("bind is not done: it must run once, got %v", main.requests)
	}
	// The dataset step used the admin token restored from the progress file.
	if !strings.Contains(runner.scripts(), "bp_admin_RESUMEtok123") {
		t.Fatalf("the dataset step should use the restored admin token\n%s", runner.scripts())
	}
}

// TestCloudSupportAddResumeBadTokenReruns: a configure record without a usable
// admin token is not trusted; configure runs again.
func TestCloudSupportAddResumeBadTokenReruns(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	supportSeedBox(t, nil, "warm-2432af65", "hex")
	configured := false
	supportConfigureHost = func(context.Context, cloud.SupportRunner, cloud.SupportConfigureOpts) (cloud.Secrets, error) {
		configured = true
		return cloud.Secrets{AdminToken: "bp_admin_fresh"}, nil
	}
	runner.outputs[supportProgressReadScript] = "done=configure\n"
	_, url := supportResumeMain(t)

	stdout, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
	if code != exitOK || !configured {
		t.Fatalf("configure should re-run (configured=%v code=%d)\nstdout:\n%s\nstderr:\n%s", configured, code, stdout, stderr)
	}
}

// TestCloudSupportAddResumeRefusesTwoBoxes: two boxes with the same label are an
// anomaly; the run refuses and creates nothing.
func TestCloudSupportAddResumeRefusesTwoBoxes(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	p := supportSeedBox(t, nil, "", "")
	p.foreign = []cloud.Server{
		{Name: "warm-a", IP: "10.0.0.1", Labels: map[string]string{cloud.FleetSupportLabelKey: "hex"}},
		{Name: "warm-b", IP: "10.0.0.2", Labels: map[string]string{cloud.FleetSupportLabelKey: "hex"}},
	}
	created := false
	supportCreateServer = func(context.Context, cloud.CloudProvider, string, string) (cloud.Server, error) {
		created = true
		return cloud.Server{}, nil
	}
	main, url := supportResumeMain(t)

	_, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
	if code == exitOK || created {
		t.Fatalf("two labeled boxes must refuse without creating (code=%d created=%v)", code, created)
	}
	if !strings.Contains(stderr, "2 boxes carry") {
		t.Fatalf("refusal should name the anomaly\n%s", stderr)
	}
	if main.count("POST") != 0 {
		t.Fatalf("nothing may be written to the main: %v", main.requests)
	}
}
