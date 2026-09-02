package setup

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
)

// acmeOpts is the canonical single-server fixture: name=acme under barkpark.cloud,
// app on :4000 — the example the task pins the golden asserts to.
func acmeOpts() CaddyOpts {
	return CaddyOpts{Name: "acme", Domain: "barkpark.cloud", AppPort: 4000}
}

func TestRenderCaddyfile_AcmeGolden(t *testing.T) {
	got, err := renderCaddyfile(acmeOpts())
	if err != nil {
		t.Fatalf("renderCaddyfile: unexpected error: %v", err)
	}

	// Exact rendered bytes — the Caddyfile cloud-15 will issue against. The site
	// block carries the maintenance handler so a deploy's restart window serves a
	// branded 503, not a raw 502.
	want := "# Managed by bp setup (cloud-4) — barkpark.cloud automatic TLS.\n" +
		"# Caddy's default ACME issues + renews the cert for acme.barkpark.cloud automatically\n" +
		"# once public DNS points acme.barkpark.cloud at this host. Do not edit by hand.\n" +
		"acme.barkpark.cloud {\n" +
		"\treverse_proxy localhost:4000\n" +
		caddyfile.MaintenanceHandler("\t") +
		"}\n"
	if got != want {
		t.Fatalf("renderCaddyfile golden mismatch:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}

	// Substring guarantees the golden also encodes, kept explicit so a future
	// template tweak that still round-trips the golden can't silently drop them.
	for _, sub := range []string{
		"acme.barkpark.cloud",
		"reverse_proxy localhost:4000",
		"handle_errors {",
		"Retry-After",
	} {
		if !strings.Contains(got, sub) {
			t.Errorf("rendered Caddyfile missing %q:\n%s", sub, got)
		}
	}

	// No OTHER hardcoded domain leaked in (the bug a single-server template
	// invites: a stray prod hostname). Only the parameterised one may appear.
	for _, forbidden := range []string{
		"89.167.28.206", // the legacy prod IP
		"api.barkpark.cloud",
	} {
		if strings.Contains(got, forbidden) {
			t.Errorf("rendered Caddyfile leaked forbidden token %q:\n%s", forbidden, got)
		}
	}

	// The apex alone must never be a site key (only the <name>.<apex> FQDN may
	// open a block) — anchored to line start so the FQDN form does not trip it.
	for _, line := range strings.Split(got, "\n") {
		if strings.HasPrefix(line, "barkpark.cloud {") {
			t.Errorf("rendered Caddyfile uses the bare apex as a site key:\n%s", got)
		}
	}
}

func TestRenderCaddyfile_NameParameterised(t *testing.T) {
	got, err := renderCaddyfile(CaddyOpts{Name: "widgets", Domain: "barkpark.cloud", AppPort: 4000})
	if err != nil {
		t.Fatalf("renderCaddyfile: unexpected error: %v", err)
	}
	if !strings.Contains(got, "widgets.barkpark.cloud {") {
		t.Errorf("expected widgets.barkpark.cloud site key, got:\n%s", got)
	}
	if strings.Contains(got, "acme") {
		t.Errorf("rendered Caddyfile for name=widgets must not mention acme:\n%s", got)
	}
}

func TestRenderCaddyfile_RejectsBadOpts(t *testing.T) {
	cases := map[string]CaddyOpts{
		"empty name":   {Name: "", Domain: "barkpark.cloud", AppPort: 4000},
		"empty domain": {Name: "acme", Domain: "", AppPort: 4000},
		"zero port":    {Name: "acme", Domain: "barkpark.cloud", AppPort: 0},
	}
	for label, opts := range cases {
		if _, err := renderCaddyfile(opts); err == nil {
			t.Errorf("%s: expected an error, got nil", label)
		}
	}
}

func TestCaddySteps_CommandsAndEnv(t *testing.T) {
	steps := CaddySteps(acmeOpts())

	// One install, one Caddyfile write, three env sets (PHX_HOST, PHX_SCHEME,
	// BARKPARK_CLOUD_URL), one barkpark restart, one reload, one ufw deny.
	if len(steps) != 8 {
		t.Fatalf("caddySteps: want 8 steps, got %d", len(steps))
	}

	// Every shell-out step must carry a non-nil Argv whose Argv[0] is the binary,
	// and a non-empty rendered Cmd — that is provision.go's contract.
	for i, s := range steps {
		if len(s.Argv) == 0 {
			t.Errorf("step %d (%q): Argv is empty — every Caddy step shells out", i, s.Title)
		}
		if strings.TrimSpace(s.Cmd) == "" {
			t.Errorf("step %d (%q): Cmd is empty", i, s.Title)
		}
	}

	joined := allCmds(steps)

	// 1. install Caddy via the official apt repo.
	mustContainOne(t, steps, "apt-get install -y caddy")
	mustContainOne(t, steps, "caddy-stable.list")

	// 2. write the Caddyfile to /etc/caddy/Caddyfile.
	mustContainOne(t, steps, "/etc/caddy/Caddyfile")

	// 3. PHX_HOST + PHX_SCHEME land in the app .env (LiveView-critical pair),
	//    and BARKPARK_CLOUD_URL arms the "Log in with Barkpark Cloud" button on
	//    /login — unset at provision, managed instances render no button.
	mustContainOne(t, steps, "PHX_HOST=acme.barkpark.cloud")
	mustContainOne(t, steps, "PHX_SCHEME=https")
	mustContainOne(t, steps, "BARKPARK_CLOUD_URL=https://barkpark.cloud")
	if !strings.Contains(joined, appEnvFile) {
		t.Errorf("env steps must target the app env file %q; commands:\n%s", appEnvFile, joined)
	}

	// 4. restart Barkpark so it picks up the new PHX_HOST (check_origin footgun).
	mustContainOne(t, steps, "systemctl restart barkpark")

	// 5. reload Caddy.
	mustContainOne(t, steps, "systemctl reload caddy")

	// 5. close the public app port — only :443 stays public.
	mustContainOne(t, steps, "ufw deny 4000")

	// The install step is guarded: a box that already has Caddy (the baked
	// warm-pool image) skips the whole apt round instead of paying a keyring +
	// apt-get update round trip on every go-live.
	if !strings.Contains(steps[0].Cmd, "command -v caddy") {
		t.Errorf("install step must probe for an existing caddy before the apt path; got:\n%s", steps[0].Cmd)
	}

	// AND the apt path REFRESHES BEFORE IT INSTALLS (D-caddy-apt-404). A stock
	// Hetzner Ubuntu image carries a stale index pinning curl at a point release
	// the mirror has already deleted, so an install that leads resolves a .deb
	// that 404s and exits 100 — three managed provisions died exactly there on
	// 2026-09-02. Asserting the ORDER, not mere presence: the second `apt-get
	// update` (for the Caddy repo) has always been there and did not save it.
	install := steps[0].Cmd
	firstUpdate := strings.Index(install, "apt-get update")
	firstInstall := strings.Index(install, "apt-get install")
	if firstUpdate < 0 {
		t.Fatalf("install step must refresh the apt index; got:\n%s", install)
	}
	if firstInstall < 0 {
		t.Fatalf("install step must install packages; got:\n%s", install)
	}
	if firstUpdate > firstInstall {
		t.Errorf("apt-get update must come BEFORE the first apt-get install (a stale index 404s on a superseded curl); got:\n%s", install)
	}
}

// TestCaddySteps_SkipAppRestart pins the go-live single-restart contract: with
// SkipAppRestart the generator emits NO barkpark restart (the chain's
// secrets-install restarts once for the PHX_* pair AND the secrets), while every
// other step — including the caddy reload — survives unchanged.
func TestCaddySteps_SkipAppRestart(t *testing.T) {
	opts := acmeOpts()
	opts.SkipAppRestart = true
	steps := CaddySteps(opts)

	if len(steps) != 7 {
		t.Fatalf("caddySteps(SkipAppRestart): want 7 steps (no app restart), got %d", len(steps))
	}
	joined := allCmds(steps)
	if strings.Contains(joined, "systemctl restart barkpark") {
		t.Errorf("SkipAppRestart must omit the barkpark restart; commands:\n%s", joined)
	}
	// The env writes and the caddy reload still happen — only the restart moved.
	mustContainOne(t, steps, "PHX_HOST=acme.barkpark.cloud")
	mustContainOne(t, steps, "PHX_SCHEME=https")
	mustContainOne(t, steps, "BARKPARK_CLOUD_URL=https://barkpark.cloud")
	mustContainOne(t, steps, "systemctl reload caddy")
	mustContainOne(t, steps, "ufw deny 4000")
}

// fakeStepRunner records each step's Title/Cmd/Argv instead of SSHing — the
// fake-run seam. It never touches a box and never issues an ACME cert.
type fakeStepRunner struct {
	titles []string
	cmds   []string
	argvs  [][]string
}

func (f *fakeStepRunner) run(s step) {
	f.titles = append(f.titles, s.Title)
	f.cmds = append(f.cmds, s.Cmd)
	f.argvs = append(f.argvs, s.Argv)
}

func TestCaddySteps_FakeRunProducesConfigAndEnv(t *testing.T) {
	opts := acmeOpts()
	steps := CaddySteps(opts)

	// Drive every step through the fake runner — NO real box, NO real ACME.
	runner := &fakeStepRunner{}
	for _, s := range steps {
		runner.run(s)
	}

	if len(runner.cmds) != len(steps) {
		t.Fatalf("fake runner recorded %d steps, want %d", len(runner.cmds), len(steps))
	}

	all := strings.Join(runner.cmds, "\n")

	// The rendered Caddyfile we WOULD have written must be reconstructable from
	// the recorded write step — assert the FQDN + reverse_proxy survived into the
	// step Argv (the heredoc body), and that it matches renderCaddyfile exactly.
	wantCaddyfile, err := renderCaddyfile(opts)
	if err != nil {
		t.Fatalf("renderCaddyfile: %v", err)
	}
	writeArgv := findArgvContaining(runner.argvs, "/etc/caddy/Caddyfile")
	if writeArgv == nil {
		t.Fatalf("no recorded step wrote /etc/caddy/Caddyfile; cmds:\n%s", all)
	}
	heredocBody := strings.Join(writeArgv, " ")
	if !strings.Contains(heredocBody, wantCaddyfile) {
		t.Errorf("the recorded Caddyfile-write step does not carry the rendered Caddyfile.\n--- step argv ---\n%s\n--- want Caddyfile ---\n%s", heredocBody, wantCaddyfile)
	}

	// PHX_HOST=acme.barkpark.cloud + PHX_SCHEME=https were produced into the env.
	if !strings.Contains(all, "PHX_HOST=acme.barkpark.cloud") {
		t.Errorf("fake run did not produce PHX_HOST=acme.barkpark.cloud; cmds:\n%s", all)
	}
	if !strings.Contains(all, "PHX_SCHEME=https") {
		t.Errorf("fake run did not produce PHX_SCHEME=https; cmds:\n%s", all)
	}
	if !strings.Contains(all, "BARKPARK_CLOUD_URL=https://barkpark.cloud") {
		t.Errorf("fake run did not produce BARKPARK_CLOUD_URL=https://barkpark.cloud; cmds:\n%s", all)
	}

	// Sanity: nothing in the fake run resembles a real ACME issuance trigger —
	// we only RENDER the config; issuance is cloud-15. (Caddy issues implicitly
	// from the site key at reload; there is no explicit issue command, and the
	// fake run never executed Argv at all.)
	if strings.Contains(all, "caddy trust") || strings.Contains(all, "acme-server") {
		t.Errorf("fake run unexpectedly references explicit ACME machinery; cmds:\n%s", all)
	}
}

// ── tiny test helpers ──────────────────────────────────────────────────────

func allCmds(steps []step) string {
	cmds := make([]string, len(steps))
	for i, s := range steps {
		cmds[i] = s.Cmd + " :: " + strings.Join(s.Argv, " ")
	}
	return strings.Join(cmds, "\n")
}

// mustContainOne asserts at least one step's Cmd OR Argv contains sub.
func mustContainOne(t *testing.T, steps []step, sub string) {
	t.Helper()
	for _, s := range steps {
		if strings.Contains(s.Cmd, sub) || strings.Contains(strings.Join(s.Argv, " "), sub) {
			return
		}
	}
	t.Errorf("no step contained %q; steps:\n%s", sub, allCmds(steps))
}

func findArgvContaining(argvs [][]string, sub string) []string {
	for _, argv := range argvs {
		if strings.Contains(strings.Join(argv, " "), sub) {
			return argv
		}
	}
	return nil
}
