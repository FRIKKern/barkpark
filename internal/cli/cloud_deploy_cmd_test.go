package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
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

// stubResolveStagingHost swaps resolveStagingHost for a fixed self-hosted answer
// (mode "" — an unknown mode is self-hosted, so every pre-existing caller keeps
// asserting the ssh path).
func stubResolveStagingHost(t *testing.T, host, url string, found bool, err error) {
	t.Helper()
	stubResolveStagingRow(t, deployFleetRow{Host: host, URL: url}, found, err)
}

// stubResolveStagingRow swaps resolveStagingHost for a whole fixed fleet row, so
// a test can name the ID and MODE the managed fork keys on.
func stubResolveStagingRow(t *testing.T, row deployFleetRow, found bool, err error) {
	t.Helper()
	prev := resolveStagingHost
	resolveStagingHost = func(cfg *Config, target string) (deployFleetRow, bool, error) {
		return row, found, err
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

// --- the read-back: proving the box advanced -------------------------------

// stubDeployStatus swaps the /status.json fetcher for a scripted sequence of
// responses (the LAST one repeats, so a retry loop can be driven precisely) and
// returns a pointer to the call counter so a test can prove reads happened —
// or, on the --host path, that NONE did.
type statusReply struct {
	code int
	body string
	err  error
}

func stubDeployStatus(t *testing.T, replies ...statusReply) *int {
	t.Helper()
	calls := 0
	prev := deployStatusFetch
	deployStatusFetch = func(host string) (int, string, error) {
		r := replies[len(replies)-1]
		if calls < len(replies) {
			r = replies[calls]
		}
		calls++
		return r.code, r.body, r.err
	}
	t.Cleanup(func() { deployStatusFetch = prev })
	return &calls
}

// stubDeployLsRemote swaps the expectation resolver's git call. Returns the call
// counter so a test can prove the --host path resolves nothing.
func stubDeployLsRemote(t *testing.T, out string, err error) *int {
	t.Helper()
	calls := 0
	prev := deployLsRemote
	deployLsRemote = func(fqref string) (string, error) {
		calls++
		return out, err
	}
	t.Cleanup(func() { deployLsRemote = prev })
	return &calls
}

// stubDeploySleep makes the read-back retry instant.
func stubDeploySleep(t *testing.T) {
	t.Helper()
	prev := deploySleep
	deploySleep = func(time.Duration) {}
	t.Cleanup(func() { deploySleep = prev })
}

const readbackSha = "c73f22a0b1f3d9e5a41c0b2d6e8f7a90b1c2d3e4"

func statusBody(commit string) string {
	if commit == "" {
		return `{"ok":true,"version":"1.2.3"}`
	}
	return `{"ok":true,"version":"1.2.3","commit":"` + commit + `"}`
}

// TestQualifyDeployRef pins that BOTH ref shapes are queried FULLY QUALIFIED —
// a bare `main` is suffix-matched by git ls-remote and can answer with a tag
// path that also ends in /main.
func TestQualifyDeployRef(t *testing.T) {
	cases := []struct{ ref, want string }{
		{"main", "refs/heads/main"},
		{"feature-x", "refs/heads/feature-x"},
		{"pull/42/head", "refs/pull/42/head"},
		{"refs/heads/already", "refs/heads/already"},
	}
	for _, c := range cases {
		if got := qualifyDeployRef(c.ref); got != c.want {
			t.Errorf("qualifyDeployRef(%q) = %q, want %q", c.ref, got, c.want)
		}
		if got := qualifyDeployRef(c.ref); !strings.HasPrefix(got, "refs/") {
			t.Errorf("qualifyDeployRef(%q) must never hand git a bare name, got %q", c.ref, got)
		}
	}
}

// TestPickLsRemoteSha proves the sha is taken by EXACT ref match, never "the
// first line" — ls-remote can answer with more than one row.
func TestPickLsRemoteSha(t *testing.T) {
	two := "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\trefs/tags/v1/main\n" +
		readbackSha + "\trefs/heads/main\n"
	if got := pickLsRemoteSha(two, "refs/heads/main"); got != readbackSha {
		t.Errorf("ambiguous ls-remote: got %q, want %q", got, readbackSha)
	}
	if got := pickLsRemoteSha("", "refs/heads/main"); got != "" {
		t.Errorf("empty ls-remote must yield no sha, got %q", got)
	}
}

// TestResolveExpectedDeployShaEmptyIsUnperformable is the anti-success-lie guard
// on the EXPECTATION itself: `git ls-remote origin refs/heads/nope` exits 0 with
// EMPTY output, so trusting the exit code would compare against "" and match
// nothing forever. Empty stdout must route to a stated problem.
func TestResolveExpectedDeployShaEmptyIsUnperformable(t *testing.T) {
	stubDeployLsRemote(t, "", nil) // exit 0, no output — the unknown-ref shape
	sha, problem := resolveExpectedDeploySha("no-such-branch")
	if sha != "" {
		t.Errorf("unknown ref must yield no sha, got %q", sha)
	}
	if problem == "" || !strings.Contains(problem, "refs/heads/no-such-branch") {
		t.Errorf("unknown ref must state the problem naming the ref, got %q", problem)
	}
}

// TestReadDeployCommitFourUnperformableShapes covers the FOUR live shapes with
// FOUR distinct sentences — collapsing them loses the actionable difference.
func TestReadDeployCommitFourUnperformableShapes(t *testing.T) {
	cases := []struct {
		name  string
		reply statusReply
		want  string
	}{
		{"host unresolvable", statusReply{err: errors.New("dial tcp: no such host")}, "could not reach"},
		{"route 404", statusReply{code: 404, body: "not found"}, "not served (404)"},
		{"commit key absent", statusReply{code: 200, body: statusBody("")}, "predates the status-commit build"},
		{"literal unknown", statusReply{code: 200, body: statusBody("unknown")}, `commit "unknown"`},
	}
	seen := map[string]bool{}
	for _, c := range cases {
		stubDeployStatus(t, c.reply)
		got := readDeployCommit("box.barkpark.cloud")
		if got.commit != "" {
			t.Errorf("%s: must yield no usable commit, got %q", c.name, got.commit)
		}
		if !strings.Contains(got.problem, c.want) {
			t.Errorf("%s: problem %q missing %q", c.name, got.problem, c.want)
		}
		if seen[got.problem] {
			t.Errorf("%s: reuses another shape's sentence %q", c.name, got.problem)
		}
		seen[got.problem] = true
	}
}

// TestReadDeployCommitOverHTTP drives the real fetcher shape against an httptest
// server, so the JSON path is exercised end to end and not just in the classifier.
func TestReadDeployCommitOverHTTP(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/status.json" {
			w.WriteHeader(404)
			return
		}
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(statusBody(readbackSha[:9])))
	}))
	t.Cleanup(srv.Close)

	prev := deployStatusFetch
	deployStatusFetch = func(host string) (int, string, error) {
		resp, err := http.Get(srv.URL + "/status.json")
		if err != nil {
			return 0, "", err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b), nil
	}
	t.Cleanup(func() { deployStatusFetch = prev })

	got := readDeployCommit("box.barkpark.cloud")
	if got.problem != "" || got.commit != readbackSha[:9] {
		t.Fatalf("httptest read-back = %+v", got)
	}
}

// TestDeployShaMatchesAdaptiveLength is the trap that would manufacture a false
// MISMATCH: the SAME commit is abbreviated to 7 chars in a --depth 1 clone and 9
// on a full one, while ls-remote answers 40. Comparison must be served-is-a-
// prefix-of-expected, and the reverse direction must NOT be accepted.
func TestDeployShaMatchesAdaptiveLength(t *testing.T) {
	for _, n := range []int{7, 9, 12, 40} {
		if !deployShaMatches(readbackSha[:n], readbackSha) {
			t.Errorf("%d-char abbreviation must MATCH the full sha", n)
		}
	}
	if deployShaMatches(readbackSha, readbackSha[:9]) {
		t.Error("expected-is-prefix-of-served is the wrong direction and must not match")
	}
	if deployShaMatches("", readbackSha) || deployShaMatches(readbackSha, "") {
		t.Error("an empty side must never match")
	}
}

// TestClassifyDeployReadbackOutcomes pins the four verdicts (plus the mismatch
// shape) off pure inputs.
func TestClassifyDeployReadbackOutcomes(t *testing.T) {
	old := "1111111111111111111111111111111111111111"
	cases := []struct {
		name                      string
		expected, expectedProblem string
		before, after             deployCommitRead
		want                      string
	}{
		{"advanced", readbackSha, "", deployCommitRead{commit: old[:9]}, deployCommitRead{commit: readbackSha[:7]}, deployAdvanced},
		{"already-at", readbackSha, "", deployCommitRead{commit: readbackSha[:9]}, deployCommitRead{commit: readbackSha[:7]}, deployAlreadyAt},
		{"stall", readbackSha, "", deployCommitRead{commit: old[:9]}, deployCommitRead{commit: old[:9]}, deployStall},
		{"mismatch", readbackSha, "", deployCommitRead{commit: old[:9]}, deployCommitRead{commit: "2222222222"}, deployMismatch},
		{"unperformable-expectation", "", "no such ref", deployCommitRead{commit: old}, deployCommitRead{commit: old}, deployUnperformable},
		{"unperformable-read", readbackSha, "", deployCommitRead{commit: old}, deployCommitRead{problem: "404"}, deployUnperformable},
	}
	for _, c := range cases {
		got := classifyDeployReadback(c.expected, c.expectedProblem, c.before, c.after)
		if got.outcome != c.want {
			t.Errorf("%s: outcome = %q, want %q", c.name, got.outcome, c.want)
		}
	}
}

// runReadbackDeploy drives a full non-dry-run deploy through the fleet path
// (via=control-plane, so the read-back is performable) with every seam stubbed.
func runReadbackDeploy(t *testing.T) (string, string, int) {
	t.Helper()
	withTempConfigHome(t)
	stubResolveStagingHost(t, "5.6.7.8", "https://guerrilla.barkpark.cloud", true, nil)
	stubDeployScript(t, "deploy/instance-deploy.sh", "#!/usr/bin/env bash\n")
	stubDeployFeeder(t)
	stubDeploySleep(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	code := runCloudDeploy(w, globals{}, []string{"guerrilla"})
	return stdout.String(), stderr.String(), code
}

// TestRunCloudDeployAdvancedNamesTheSha proves the success line is backed by a
// post-condition read: it names the served sha and what it advanced FROM.
func TestRunCloudDeployAdvancedNamesTheSha(t *testing.T) {
	stubDeployLsRemote(t, readbackSha+"\trefs/heads/main\n", nil)
	stubDeployStatus(t,
		statusReply{code: 200, body: statusBody("1111111111")}, // before
		statusReply{code: 200, body: statusBody(readbackSha[:9])},
	)
	stdout, stderr, code := runReadbackDeploy(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stderr)
	}
	for _, want := range []string{"ADVANCED", readbackSha[:9], "1111111111"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("advanced line missing %q:\n%s", want, stdout)
		}
	}
}

// TestRunCloudDeployStallIsNamedNonZero proves an ssh exit 0 with an unmoved box
// FAILS — the flagship success-lie this slice kills.
func TestRunCloudDeployStallIsNamedNonZero(t *testing.T) {
	stubDeployLsRemote(t, readbackSha+"\trefs/heads/main\n", nil)
	stubDeployStatus(t, statusReply{code: 200, body: statusBody("1111111111")})
	stdout, stderr, code := runReadbackDeploy(t)
	if code == exitOK {
		t.Fatalf("a stalled deploy must not exit 0\n%s", stdout)
	}
	if !strings.Contains(stderr, "STALL") {
		t.Errorf("stall must be NAMED:\n%s", stderr)
	}
	if strings.Contains(stdout, "✓") {
		t.Errorf("no checkmark may survive a stall:\n%s", stdout)
	}
}

// TestRunCloudDeployRetriesBeforeStall proves the AFTER read is retried before a
// stall is declared — a slow Caddy flip must not be reported as a failure.
func TestRunCloudDeployRetriesBeforeStall(t *testing.T) {
	stubDeployLsRemote(t, readbackSha+"\trefs/heads/main\n", nil)
	calls := stubDeployStatus(t,
		statusReply{code: 200, body: statusBody("1111111111")}, // before
		statusReply{code: 200, body: statusBody("1111111111")}, // after #1: not yet flipped
		statusReply{code: 200, body: statusBody(readbackSha[:7])},
	)
	stdout, stderr, code := runReadbackDeploy(t)
	if code != exitOK {
		t.Fatalf("the retry must rescue a slow flip: exit %d\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "ADVANCED") {
		t.Errorf("retried read must report ADVANCED:\n%s", stdout)
	}
	if *calls < 3 {
		t.Errorf("expected a retried read, got %d status reads", *calls)
	}
}

// TestRunCloudDeployCoalescePrintsAlreadyAt proves a no-op run is not dressed as
// a deploy.
func TestRunCloudDeployCoalescePrintsAlreadyAt(t *testing.T) {
	stubDeployLsRemote(t, readbackSha+"\trefs/heads/main\n", nil)
	stubDeployStatus(t, statusReply{code: 200, body: statusBody(readbackSha[:9])})
	stdout, stderr, code := runReadbackDeploy(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stderr)
	}
	if !strings.Contains(stdout, "already at "+readbackSha[:9]) {
		t.Errorf("coalesce must print `already at <sha>`:\n%s", stdout)
	}
	if strings.Contains(stdout, "deployed") || strings.Contains(stdout, "ADVANCED") {
		t.Errorf("a coalesce must not claim a deploy:\n%s", stdout)
	}
}

// TestRunCloudDeployUnperformableSaysSo proves a box that cannot be read back
// gets an explicit UNPERFORMABLE sentence instead of a bare checkmark.
func TestRunCloudDeployUnperformableSaysSo(t *testing.T) {
	stubDeployLsRemote(t, readbackSha+"\trefs/heads/main\n", nil)
	stubDeployStatus(t, statusReply{code: 200, body: statusBody("")}) // pre-dependency box
	stdout, stderr, code := runReadbackDeploy(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stderr)
	}
	if !strings.Contains(stdout, "UNPERFORMABLE") || !strings.Contains(stdout, "predates the status-commit build") {
		t.Errorf("unperformable read-back must say so in the same breath:\n%s", stdout)
	}
	if strings.Contains(stdout, "✓") {
		t.Errorf("no bare checkmark may back an unperformable read-back:\n%s", stdout)
	}
}

// TestRunCloudDeployHostFlagDeclaresUnperformable proves --host never borrows the
// on-box gate's confidence: the health FQDN is INVENTED there, the box gates
// itself with curl --resolve, so the CLI reads nothing and says so.
func TestRunCloudDeployHostFlagDeclaresUnperformable(t *testing.T) {
	withTempConfigHome(t)
	stubDeployScript(t, "deploy/instance-deploy.sh", "#!/usr/bin/env bash\n")
	stubDeployFeeder(t)
	lsCalls := stubDeployLsRemote(t, readbackSha+"\trefs/heads/main\n", nil)
	statusCalls := stubDeployStatus(t, statusReply{code: 200, body: statusBody(readbackSha)})

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	code := runCloudDeploy(w, globals{}, []string{"staging", "--host", "1.2.3.4"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stderr.String())
	}
	if !strings.Contains(stdout.String(), "UNPERFORMABLE") || !strings.Contains(stdout.String(), "--host") {
		t.Errorf("--host must declare UNPERFORMABLE:\n%s", stdout.String())
	}
	if *lsCalls != 0 || *statusCalls != 0 {
		t.Errorf("--host must perform no reads, got ls=%d status=%d", *lsCalls, *statusCalls)
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
