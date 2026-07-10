package cli

import (
	"bytes"
	"context"
	"io"
	"os"
	"strings"
	"testing"
)

// recordFeeder is the fake per-host runner the deploy tests inject in place of
// the live ssh feeder — it records the remote bootstrap script and the fed
// local deploy-script bytes so a test asserts the transcript without any ssh.
type recordFeeder struct {
	host         string
	calls        int
	title        string
	remoteScript string
	fedScript    string
	out          string
	err          error
}

func (r *recordFeeder) RunFeed(ctx context.Context, title, script string, stdin io.Reader) (string, error) {
	r.calls++
	r.title = title
	r.remoteScript = script
	b, _ := io.ReadAll(stdin)
	r.fedScript = string(b)
	if r.out == "" {
		return "instance-deploy: done\n", r.err
	}
	return r.out, r.err
}

// stubDeployFeeder swaps newDeployFeeder for a recorder capturing the host, and
// restores it after the test.
func stubDeployFeeder(t *testing.T) *recordFeeder {
	t.Helper()
	rec := &recordFeeder{}
	prev := newDeployFeeder
	newDeployFeeder = func(host string) deployFeeder {
		rec.host = host
		return rec
	}
	t.Cleanup(func() { newDeployFeeder = prev })
	return rec
}

// stubDeployScript swaps readDeployScript for a fixed path+content.
func stubDeployScript(t *testing.T, path, content string) {
	t.Helper()
	prev := readDeployScript
	readDeployScript = func() (string, string, error) { return path, content, nil }
	t.Cleanup(func() { readDeployScript = prev })
}

// stubResolveStagingHost swaps resolveStagingHost for a fixed answer.
func stubResolveStagingHost(t *testing.T, host, url string, found bool, err error) {
	t.Helper()
	prev := resolveStagingHost
	resolveStagingHost = func(cfg *Config, target string) (string, string, bool, error) {
		return host, url, found, err
	}
	t.Cleanup(func() { resolveStagingHost = prev })
}

// configBytes reads the raw config file (empty when it does not exist) so a test
// can prove the deploy path wrote nothing.
func configBytes(t *testing.T) []byte {
	t.Helper()
	p, err := ConfigPath()
	if err != nil {
		t.Fatalf("ConfigPath: %v", err)
	}
	b, rerr := os.ReadFile(p)
	if rerr != nil {
		if os.IsNotExist(rerr) {
			return nil
		}
		t.Fatalf("read config: %v", rerr)
	}
	return b
}

func TestResolveDeployRef(t *testing.T) {
	cases := []struct {
		branch, pr string
		want       string
		wantErr    bool
	}{
		{"", "", "main", false},
		{"feature-x", "", "feature-x", false},
		{"", "123", "pull/123/head", false},
		{"  spaced  ", "", "spaced", false},
		{"feature-x", "5", "", true}, // mutually exclusive
		{"", "0", "", true},          // non-positive
		{"", "-3", "", true},         // non-positive
		{"", "notnum", "", true},     // non-numeric
	}
	for _, c := range cases {
		got, err := resolveDeployRef(c.branch, c.pr)
		if c.wantErr {
			if err == nil {
				t.Errorf("resolveDeployRef(%q,%q) want error, got %q", c.branch, c.pr, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("resolveDeployRef(%q,%q) unexpected error: %v", c.branch, c.pr, err)
			continue
		}
		if got != c.want {
			t.Errorf("resolveDeployRef(%q,%q) = %q, want %q", c.branch, c.pr, got, c.want)
		}
	}
}

func TestResolveDeployHostPrecedence(t *testing.T) {
	// --host wins outright, even when a control-plane row and env are present.
	host, health, via, err := resolveDeployHost("staging", "1.2.3.4", "9.9.9.9", "5.6.7.8", "https://staging.barkpark.cloud", true)
	if err != nil {
		t.Fatalf("--host path errored: %v", err)
	}
	if host != "1.2.3.4" || via != "--host" {
		t.Errorf("--host precedence: host=%q via=%q", host, via)
	}
	if health != "staging.barkpark.cloud" {
		t.Errorf("health host from cpURL: got %q", health)
	}

	// No --host: the control-plane row wins over env.
	host, health, via, err = resolveDeployHost("staging", "", "9.9.9.9", "5.6.7.8", "https://staging.barkpark.cloud", true)
	if err != nil {
		t.Fatalf("control-plane path errored: %v", err)
	}
	if host != "5.6.7.8" || via != "control-plane" {
		t.Errorf("control-plane precedence: host=%q via=%q", host, via)
	}

	// No --host, no fleet row: env wins, health derives from the target name.
	host, health, via, err = resolveDeployHost("staging", "", "9.9.9.9", "", "", false)
	if err != nil {
		t.Fatalf("env path errored: %v", err)
	}
	if host != "9.9.9.9" || via != "BARKPARK_STAGING_HOST" {
		t.Errorf("env precedence: host=%q via=%q", host, via)
	}
	if health != "staging.barkpark.cloud" {
		t.Errorf("health host from target name: got %q", health)
	}

	// Nothing resolves: a clear error.
	if _, _, _, err = resolveDeployHost("staging", "", "", "", "", false); err == nil {
		t.Error("no host source should error")
	}
}

func TestDeriveHealthHost(t *testing.T) {
	cases := []struct{ target, cpURL, want string }{
		{"staging", "https://staging.barkpark.cloud", "staging.barkpark.cloud"},
		{"staging", "https://staging.barkpark.cloud:4000/x", "staging.barkpark.cloud"},
		{"staging", "", "staging.barkpark.cloud"},
		{"staging.example.com", "", "staging.example.com"}, // already an fqdn
		{"", "", ""},
	}
	for _, c := range cases {
		if got := deriveHealthHost(c.target, c.cpURL); got != c.want {
			t.Errorf("deriveHealthHost(%q,%q) = %q, want %q", c.target, c.cpURL, got, c.want)
		}
	}
}

func TestBuildDeployRemoteScript(t *testing.T) {
	s := buildDeployRemoteScript("pull/42/head", "origin", "staging.barkpark.cloud", false)
	for _, want := range []string{
		"DEPLOY_REF='pull/42/head'",
		"DEPLOY_REMOTE='origin'",
		"BARKPARK_HEALTH_HOST='staging.barkpark.cloud'",
		`cat > "$tmp"`,
		`bash "$tmp"`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("remote script missing %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, ".instance-deploy-last") {
		t.Errorf("no --clean should not touch the state file:\n%s", s)
	}

	// --clean prepends the state-file removal.
	sc := buildDeployRemoteScript("main", "origin", "staging.barkpark.cloud", true)
	if !strings.Contains(sc, "rm -f "+deployRemoteAppDir+"/.instance-deploy-last") {
		t.Errorf("--clean must remove .instance-deploy-last first:\n%s", sc)
	}
}

// TestRunCloudDeployDryRunNoConnect proves --dry-run prints the plan (host, ref,
// remote invocation) and NEVER touches the feeder or writes config.
func TestRunCloudDeployDryRunNoConnect(t *testing.T) {
	withTempConfigHome(t)
	if err := SaveConfig(&Config{Server: "https://guerrilla.barkpark.cloud", Token: "tok"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	before := configBytes(t)

	rec := stubDeployFeeder(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	code := runCloudDeploy(w, globals{dryRun: true}, []string{"staging", "--host", "1.2.3.4", "--pr", "123"})
	if code != exitOK {
		t.Fatalf("dry-run exit = %d, want %d\n%s", code, exitOK, stderr.String())
	}
	if rec.calls != 0 {
		t.Errorf("dry-run must NOT connect: feeder called %d times", rec.calls)
	}
	out := stdout.String()
	for _, want := range []string{"1.2.3.4", "staging.barkpark.cloud", "pull/123/head", "DEPLOY_REF", `bash "$tmp"`} {
		if !strings.Contains(out, want) {
			t.Errorf("dry-run output missing %q:\n%s", want, out)
		}
	}
	if !bytes.Equal(before, configBytes(t)) {
		t.Error("dry-run must not write config")
	}
}

// TestRunCloudDeployStreamsScriptNoConfigWrite proves a (mocked) real deploy
// streams the LOCAL deploy script bytes to the box, runs it under the env
// contract, and writes NO config.
func TestRunCloudDeployStreamsScriptNoConfigWrite(t *testing.T) {
	withTempConfigHome(t)
	if err := SaveConfig(&Config{Server: "https://guerrilla.barkpark.cloud", Token: "tok"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	before := configBytes(t)

	const scriptBody = "#!/usr/bin/env bash\necho instance-deploy\n"
	stubDeployScript(t, "deploy/instance-deploy.sh", scriptBody)
	rec := stubDeployFeeder(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	code := runCloudDeploy(w, globals{}, []string{"staging", "--host", "1.2.3.4", "--branch", "feature-x", "--clean"})
	if code != exitOK {
		t.Fatalf("deploy exit = %d, want %d\n%s", code, exitOK, stderr.String())
	}
	if rec.calls != 1 {
		t.Fatalf("feeder should run once, ran %d", rec.calls)
	}
	if rec.host != "1.2.3.4" {
		t.Errorf("feeder host = %q, want 1.2.3.4", rec.host)
	}
	if rec.fedScript != scriptBody {
		t.Errorf("fed script mismatch:\n got %q\nwant %q", rec.fedScript, scriptBody)
	}
	for _, want := range []string{
		"DEPLOY_REF='feature-x'",
		"DEPLOY_REMOTE='origin'",
		"BARKPARK_HEALTH_HOST='staging.barkpark.cloud'",
		"rm -f " + deployRemoteAppDir + "/.instance-deploy-last",
		`bash "$tmp"`,
	} {
		if !strings.Contains(rec.remoteScript, want) {
			t.Errorf("remote invocation missing %q:\n%s", want, rec.remoteScript)
		}
	}
	// The three smoke URLs land on success.
	out := stdout.String()
	for _, u := range deploySmokeURLs("staging.barkpark.cloud") {
		if !strings.Contains(out, u) {
			t.Errorf("success output missing smoke URL %q:\n%s", u, out)
		}
	}
	if !bytes.Equal(before, configBytes(t)) {
		t.Error("deploy must not write config (guerrilla stays the default)")
	}
}

// TestRunCloudDeployControlPlaneResolution proves the fleet lookup seam feeds
// host + FQDN when no --host is given.
func TestRunCloudDeployControlPlaneResolution(t *testing.T) {
	withTempConfigHome(t)
	stubResolveStagingHost(t, "5.6.7.8", "https://staging.barkpark.cloud", true, nil)
	stubDeployFeeder(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	code := runCloudDeploy(w, globals{dryRun: true}, []string{"staging"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{"5.6.7.8", "control-plane", "staging.barkpark.cloud", "main"} {
		if !strings.Contains(out, want) {
			t.Errorf("control-plane dry-run missing %q:\n%s", want, out)
		}
	}
}

// TestRunCloudDeployEnvFallback proves BARKPARK_STAGING_HOST is used when the
// fleet has no match and no --host is given.
func TestRunCloudDeployEnvFallback(t *testing.T) {
	withTempConfigHome(t)
	stubResolveStagingHost(t, "", "", false, nil)
	stubDeployFeeder(t)
	t.Setenv("BARKPARK_STAGING_HOST", "9.9.9.9")

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	code := runCloudDeploy(w, globals{dryRun: true}, []string{"staging"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{"9.9.9.9", "BARKPARK_STAGING_HOST"} {
		if !strings.Contains(out, want) {
			t.Errorf("env-fallback dry-run missing %q:\n%s", want, out)
		}
	}
}

// TestRunCloudDeployNoHostErrors proves a clear error when nothing resolves.
func TestRunCloudDeployNoHostErrors(t *testing.T) {
	withTempConfigHome(t)
	stubResolveStagingHost(t, "", "", false, nil)
	t.Setenv("BARKPARK_STAGING_HOST", "")

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	code := runCloudDeploy(w, globals{dryRun: true}, []string{"staging"})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
}

func TestRunCloudDeployRejectsBothRefFlags(t *testing.T) {
	withTempConfigHome(t)
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	code := runCloudDeploy(w, globals{dryRun: true}, []string{"staging", "--host", "1.2.3.4", "--branch", "x", "--pr", "9"})
	if code != exitUsage {
		t.Fatalf("both --branch and --pr should be a usage error, got exit %d", code)
	}
}

// --- bp use staging guard ------------------------------------------------

// TestUseRefusesStagingWithoutForce proves `bp use <staging>` refuses to persist
// a Kind=="staging" entry without --force, names the -s path, and writes nothing.
func TestUseRefusesStagingWithoutForce(t *testing.T) {
	withTempConfigHome(t)
	cfg := &Config{
		Server: "https://guerrilla.barkpark.cloud",
		KnownServers: []ServerEntry{
			{Name: "guerrilla", Server: "https://guerrilla.barkpark.cloud"},
			{Name: "staging", Server: "https://staging.barkpark.cloud", Kind: "staging"},
		},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	before := configBytes(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	code := runUse(w, []string{"staging"})
	if code != exitUsage {
		t.Fatalf("refusal exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "-s staging") {
		t.Errorf("refusal must name the `bp -s staging` path:\n%s", stderr.String())
	}
	if !bytes.Equal(before, configBytes(t)) {
		t.Error("refused `bp use staging` must not change the active server")
	}
	// The active server is still guerrilla.
	got, _ := LoadConfig()
	if got.Server != "https://guerrilla.barkpark.cloud" {
		t.Errorf("active server changed on refusal: %q", got.Server)
	}
}

// TestUseStagingWithForce proves --force overrides the guard and switches.
func TestUseStagingWithForce(t *testing.T) {
	withTempConfigHome(t)
	cfg := &Config{
		Server: "https://guerrilla.barkpark.cloud",
		KnownServers: []ServerEntry{
			{Name: "guerrilla", Server: "https://guerrilla.barkpark.cloud"},
			{Name: "staging", Server: "https://staging.barkpark.cloud", Kind: "staging"},
		},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	if code := runUse(w, []string{"staging", "--force"}); code != exitOK {
		t.Fatalf("--force exit = %d, want %d\n%s", code, exitOK, stderr.String())
	}
	got, _ := LoadConfig()
	if got.Server != "https://staging.barkpark.cloud" {
		t.Errorf("--force did not switch to staging: %q", got.Server)
	}
}

// TestUseNonStagingUnaffected proves the guard only bites staging entries.
func TestUseNonStagingUnaffected(t *testing.T) {
	withTempConfigHome(t)
	cfg := &Config{
		Server: "https://guerrilla.barkpark.cloud",
		KnownServers: []ServerEntry{
			{Name: "guerrilla", Server: "https://guerrilla.barkpark.cloud"},
			{Name: "prod", Server: "https://api.barkpark.cloud"},
		},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	if code := runUse(w, []string{"prod"}); code != exitOK {
		t.Fatalf("switching to a normal server should succeed, got %d\n%s", code, stderr.String())
	}
	got, _ := LoadConfig()
	if got.Server != "https://api.barkpark.cloud" {
		t.Errorf("did not switch to prod: %q", got.Server)
	}
}
