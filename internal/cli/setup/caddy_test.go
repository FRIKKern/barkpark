package setup

import (
	"strings"
	"testing"
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

	// Exact rendered bytes — the Caddyfile cloud-15 will issue against.
	want := `# Managed by bp setup (cloud-4) — barkpark.cloud automatic TLS.
# Caddy's default ACME issues + renews the cert for acme.barkpark.cloud automatically
# once public DNS points acme.barkpark.cloud at this host. Do not edit by hand.
acme.barkpark.cloud {
	reverse_proxy localhost:4000
}
`
	if got != want {
		t.Fatalf("renderCaddyfile golden mismatch:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}

	// Substring guarantees the golden also encodes, kept explicit so a future
	// template tweak that still round-trips the golden can't silently drop them.
	for _, sub := range []string{
		"acme.barkpark.cloud",
		"reverse_proxy localhost:4000",
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

	// One install, one Caddyfile write, two env sets, one barkpark restart, one reload, one ufw deny.
	if len(steps) != 7 {
		t.Fatalf("caddySteps: want 7 steps, got %d", len(steps))
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

	// 3. PHX_HOST + PHX_SCHEME land in the app .env (LiveView-critical pair).
	mustContainOne(t, steps, "PHX_HOST=acme.barkpark.cloud")
	mustContainOne(t, steps, "PHX_SCHEME=https")
	if !strings.Contains(joined, appEnvFile) {
		t.Errorf("env steps must target the app env file %q; commands:\n%s", appEnvFile, joined)
	}

	// 4. restart Barkpark so it picks up the new PHX_HOST (check_origin footgun).
	mustContainOne(t, steps, "systemctl restart barkpark")

	// 5. reload Caddy.
	mustContainOne(t, steps, "systemctl reload caddy")

	// 5. close the public app port — only :443 stays public.
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
