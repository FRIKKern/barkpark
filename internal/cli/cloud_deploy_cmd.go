package cli

// cloud_deploy_cmd.go is `bp cloud deploy <target> [flags]` — the ONE verb that
// pushes any git ref to a Barkpark instance (the staging box is the whole point:
// try a build BEFORE the auto-deploy-on-merge train ships it everywhere). It is a
// thin driver over the SAME blue/green mechanics `deploy/instance-deploy.sh`
// already carries — it does NOT invent a second deploy system:
//
//   - it resolves the target's SSH host (— --host wins; else the control-plane
//     fleet row's Barkpark.Host when logged in; else BARKPARK_STAGING_HOST; else a
//     clear error),
//   - streams the LOCAL repo's deploy/instance-deploy.sh to the box over SSH
//     (so the CURRENT script — the one that understands DEPLOY_REF — runs even
//     when the box's own checkout is stale),
//   - runs it with the channel-seam env contract DEPLOY_REF / DEPLOY_REMOTE /
//     BARKPARK_HEALTH_HOST (the names the staging-w1-channel-seam slice reads),
//   - and prints the three golden-path smoke URLs on success.
//
// HARD INVARIANT — this verb NEVER writes config. It calls neither
// SetActiveServer nor RememberServer nor SaveConfig: deploying to staging must
// never repoint the ambient `bp` server (guerrilla stays the task-server default).
// The only persistence guard lives one door over in `bp use`, which refuses to
// make a Kind=="staging" entry the default without --force.
//
// The SSH exec + the local-script read + the fleet lookup are injectable package
// vars (newDeployFeeder / readDeployScript / resolveStagingHost), so the unit
// tests exercise host precedence, ref mapping, the remote-invocation transcript,
// and the no-config-write invariant WITHOUT ever shelling out to real ssh.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// deployRemoteAppDir is the on-box checkout instance-deploy.sh operates on — the
// same $APP default the script itself uses (deploy/instance-deploy.sh:24). The
// --clean lever removes THIS dir's .instance-deploy-last (the coalesce state file)
// to force a rebuild.
const deployRemoteAppDir = "/opt/barkpark"

// deployFeeder is the minimal seam `bp cloud deploy` needs from a per-host runner:
// feed the local deploy script over the ssh connection's stdin into a remote
// bootstrap command and return its combined output. The production
// *cloud.SSHStepRunner satisfies it via RunFeed (the StdinStepRunner capability
// the resurrect restore already uses); tests inject a recording fake so Run never
// touches real ssh.
type deployFeeder interface {
	RunFeed(ctx context.Context, title, script string, stdin io.Reader) (string, error)
}

// newDeployFeeder builds the production per-host feeder. A package var so the
// unit tests swap in a recorder — the freshen/EnsureFresh seam idiom.
var newDeployFeeder = func(host string) deployFeeder { return cloud.NewSSHStepRunner(host) }

// resolveStagingHost looks the target up in the user's fleet (needs `bp login`)
// and returns its SSH host + public URL. A package var so tests inject a fake
// fleet without an httptest server. A logged-OUT user (or a target not in the
// fleet) returns found=false with no error, so host resolution falls through to
// BARKPARK_STAGING_HOST; only a real control-plane failure returns an error.
var resolveStagingHost = func(cfg *Config, target string) (host, url string, found bool, err error) {
	if cfg == nil || !cfg.HasCloudToken() {
		return "", "", false, nil
	}
	list, lerr := cfg.CloudClient().ListBarkparks(cloudCtx())
	if lerr != nil {
		return "", "", false, lerr
	}
	// Exact id/slug/name first (an exact hit must never lose to a case-folded one),
	// then a case-insensitive name pass — the resolveOpenBarkparkID rule.
	for _, b := range list {
		if b.ID == target || b.Slug == target || b.Name == target {
			return b.Host, b.URL, true, nil
		}
	}
	for _, b := range list {
		if strings.EqualFold(b.Name, target) {
			return b.Host, b.URL, true, nil
		}
	}
	return "", "", false, nil
}

// readDeployScript locates + reads the LOCAL deploy/instance-deploy.sh. A package
// var so tests supply fixed bytes. BARKPARK_INSTANCE_DEPLOY_SCRIPT overrides the
// path; otherwise it walks up from the working directory to the repo root.
var readDeployScript = func() (path, content string, err error) {
	p, ferr := findDeployScript()
	if ferr != nil {
		return "", "", ferr
	}
	b, rerr := os.ReadFile(p)
	if rerr != nil {
		return "", "", fmt.Errorf("read %s: %w", p, rerr)
	}
	return p, string(b), nil
}

// findDeployScript resolves the path to deploy/instance-deploy.sh:
// BARKPARK_INSTANCE_DEPLOY_SCRIPT when set (must exist), else the first
// deploy/instance-deploy.sh found walking up from the current directory.
func findDeployScript() (string, error) {
	if p := strings.TrimSpace(os.Getenv("BARKPARK_INSTANCE_DEPLOY_SCRIPT")); p != "" {
		if _, err := os.Stat(p); err != nil {
			return "", fmt.Errorf("BARKPARK_INSTANCE_DEPLOY_SCRIPT=%s: %w", p, err)
		}
		return p, nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("resolve working directory: %w", err)
	}
	for {
		cand := filepath.Join(dir, "deploy", "instance-deploy.sh")
		if _, serr := os.Stat(cand); serr == nil {
			return cand, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("could not find deploy/instance-deploy.sh from the current directory — run `bp cloud deploy` from inside a Barkpark checkout, or set BARKPARK_INSTANCE_DEPLOY_SCRIPT to the script path")
}

// runCloudDeploy is `bp cloud deploy <target> [--branch <x> | --pr <n>]
// [--host <ip>] [--clean] [--dry-run]`. It resolves the target host, computes the
// DEPLOY_REF, and streams the local deploy script to the box — or, with --dry-run,
// prints exactly what it WOULD do without connecting.
func runCloudDeploy(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudDeployHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudDeployHelp(out)
		return exitOK
	}

	const usage = "bp cloud deploy <target> [--branch <x> | --pr <n>] [--host <ip>] [--clean] [--dry-run]"
	// --dry-run is a GLOBAL flag (globals.go), so it is stripped into g.dryRun
	// before it ever reaches here — accept it locally too so a direct call still
	// honours it, and OR the two.
	a, perr := parseHzArgs(args, []string{"branch", "pr", "host"}, []string{"clean", "dry-run"}, usage)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <target> (usage: %s)", usage), exitUsage)
	}
	target := a.pos[0]
	dryRun := g.dryRun || a.bools["dry-run"]
	clean := a.bools["clean"]

	ref, rerr := resolveDeployRef(a.val("branch"), a.val("pr"))
	if rerr != nil {
		return useError(out, "usage", rerr.Error(), exitUsage)
	}

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}

	// Host resolution. --host short-circuits the network entirely; otherwise the
	// fleet lookup runs (a no-op when logged out). A control-plane FAILURE is
	// surfaced — but a plain miss falls through to the env knob below.
	hostFlag := strings.TrimSpace(a.val("host"))
	var cpHost, cpURL string
	var cpFound bool
	if hostFlag == "" {
		var lerr error
		cpHost, cpURL, cpFound, lerr = resolveStagingHost(cfg, target)
		if lerr != nil {
			return cloudFail(out, "resolve deploy target", lerr)
		}
	}
	envHost := strings.TrimSpace(os.Getenv("BARKPARK_STAGING_HOST"))
	host, healthHost, via, herr := resolveDeployHost(target, hostFlag, envHost, cpHost, cpURL, cpFound)
	if herr != nil {
		return useError(out, "usage", herr.Error(), exitUsage)
	}

	remoteScript := buildDeployRemoteScript(ref, "origin", healthHost, clean)

	if dryRun {
		return deployDryRun(out, target, host, healthHost, ref, via, clean, remoteScript)
	}

	path, script, serr := readDeployScript()
	if serr != nil {
		return useError(out, "failed", serr.Error(), exitGeneric)
	}

	out.outf("→ deploying %s to %s (ssh %s, via %s)", ref, healthHost, host, via)
	out.outf("  streaming %s to the box — this can take a few minutes…", path)

	// THE EXPECTATION, resolved BEFORE the box is touched. Before/after alone
	// cannot separate a coalesce (exit 0, no rebuild) from a stall (exit 0, no
	// advance) — both leave the served sha untouched — and a MISMATCH is not
	// derivable at all without knowing what SHOULD be running. `git ls-remote`
	// answers that unauthenticated for both ref shapes.
	//
	// The --host path is decided BEFORE any of it runs: --host INVENTS the health
	// FQDN (deriveHealthHost) while the box gates itself with curl --resolve, so
	// the CLI cannot confirm it would be reading the same box. That path performs
	// no reads at all and says so at the end.
	var expected, expectedProblem string
	var before deployCommitRead
	if via != "--host" {
		expected, expectedProblem = resolveExpectedDeploySha(ref)
		// The BEFORE read, so "advanced" can name what it advanced FROM and a
		// coalesce can be told apart from a stall.
		before = readDeployCommit(healthHost)
	}

	feeder := newDeployFeeder(host)
	output, derr := feeder.RunFeed(cloudCtx(), "instance-deploy", remoteScript, strings.NewReader(script))
	if s := strings.TrimRight(output, "\n"); strings.TrimSpace(s) != "" {
		out.outf("%s", s)
	}
	if derr != nil {
		return useError(out, "failed", "deploy failed: "+derr.Error(), exitGeneric)
	}

	// The ssh exit code is NOT the success claim — the box's own /status.json is.
	rb := performDeployReadback(via, healthHost, expected, expectedProblem, before)

	out.outf("")
	switch rb.outcome {
	case deployStall, deployMismatch:
		// A NAMED non-zero. The run exited 0; the box did not advance.
		return useError(out, "deploy-"+rb.outcome, rb.line(target, healthHost), exitGeneric)
	default:
		out.outf("%s", rb.line(target, healthHost))
	}
	out.outf("  smoke:")
	for _, u := range deploySmokeURLs(healthHost) {
		out.outf("    %s", u)
	}
	return exitOK
}

// ─── the read-back: proving the box advanced ────────────────────────────────
//
// `bp cloud deploy` used to gate its entire success message on `if derr != nil`
// over the ssh feed and then print a checkmark. Nothing read the box. This is
// the post-condition read that backs the claim — and, where it CANNOT be
// performed, says so in the same breath instead of printing a bare ✓.

// The four named outcomes. Nothing else may be printed as a success.
const (
	deployAdvanced      = "advanced"
	deployAlreadyAt     = "already-at"
	deployStall         = "stall"
	deployMismatch      = "mismatch"
	deployUnperformable = "unperformable"
)

// deployReadbackTries / deployReadbackWait: the AFTER read retries before it is
// willing to call a stall. instance-deploy.sh flips Caddy ~290 lines before it
// exits 0, so the window should be negative — but that conclusion is read off
// the script, not measured on a live deploy, so the retry is kept as cheap
// insurance against calling a healthy deploy a failure.
var (
	deployReadbackTries = 3
	deployReadbackWait  = 5 * time.Second
	deploySleep         = time.Sleep
)

// deployCommitRead is one /status.json read. Exactly one of commit / problem is
// set: problem carries the reason the read-back could not be performed, phrased
// for the owner, and there are FOUR distinct live shapes (see readDeployCommit).
type deployCommitRead struct {
	commit  string
	problem string
}

// deployStatusFetch GETs https://<host>/status.json. A package var so tests
// point it at an httptest server without any network.
var deployStatusFetch = func(host string) (status int, body string, err error) {
	req, rerr := http.NewRequestWithContext(cloudCtx(), http.MethodGet, "https://"+host+"/status.json", nil)
	if rerr != nil {
		return 0, "", rerr
	}
	resp, derr := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if derr != nil {
		return 0, "", derr
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, string(b), nil
}

// readDeployCommit reads the box's running commit out of /status.json and
// classifies every way that read can fail to produce a usable sha. The four
// shapes get four DISTINCT sentences — collapsing them to "couldn't read it" is
// itself a mild information-lie, because three of them are actionable and only
// one is "the box is unreachable":
//
//	host unreachable  — DNS/TLS/connect error (or a non-2xx that is not 404)
//	route 404         — this box serves no /status.json at all
//	key ABSENT        — a post-dependency build renders "unknown" rather than
//	                    omitting the key, so an ABSENT key PROVES a build from
//	                    before the status-commit read path landed
//	literal "unknown" — a current build that has no git metadata to report
func readDeployCommit(healthHost string) deployCommitRead {
	code, body, err := deployStatusFetch(healthHost)
	switch {
	case err != nil:
		return deployCommitRead{problem: fmt.Sprintf("could not reach https://%s/status.json (%v)", healthHost, err)}
	case code == http.StatusNotFound:
		return deployCommitRead{problem: fmt.Sprintf("https://%s/status.json is not served (404) — this box has no status route", healthHost)}
	case code < 200 || code > 299:
		return deployCommitRead{problem: fmt.Sprintf("https://%s/status.json answered HTTP %d", healthHost, code)}
	}
	var doc map[string]any
	if jerr := json.Unmarshal([]byte(body), &doc); jerr != nil {
		return deployCommitRead{problem: fmt.Sprintf("https://%s/status.json did not parse as JSON (%v)", healthHost, jerr)}
	}
	raw, ok := doc["commit"]
	if !ok || raw == nil {
		return deployCommitRead{problem: fmt.Sprintf("https://%s/status.json carries no `commit` key — this box predates the status-commit build; deploy it once and the read-back works from then on", healthHost)}
	}
	commit := strings.TrimSpace(fmt.Sprintf("%v", raw))
	switch {
	case commit == "" || commit == "unknown":
		return deployCommitRead{problem: fmt.Sprintf("https://%s/status.json reports commit \"unknown\" — the running build carries no git sha to compare", healthHost)}
	case len(commit) < 7:
		return deployCommitRead{problem: fmt.Sprintf("https://%s/status.json reports commit %q — too short to compare against a full sha", healthHost, commit)}
	}
	return deployCommitRead{commit: commit}
}

// resolveExpectedDeploySha asks the REMOTE what the deployed ref points at.
// Both DEPLOY_REF shapes are queried FULLY QUALIFIED — `git ls-remote <url> main`
// suffix-matches and returns TWO lines when a tag path also ends in /main.
// A missing ref EXITS 0 WITH EMPTY OUTPUT, so gating on err != nil would be a
// success-claim on an exit code inside the slice whose whole point is refusing
// those: empty output routes to a problem, never to a comparison against "".
func resolveExpectedDeploySha(ref string) (sha, problem string) {
	fq := qualifyDeployRef(ref)
	out, err := deployLsRemote(fq)
	if err != nil {
		return "", fmt.Sprintf("could not resolve %s on origin (%v) — no expected sha to compare against", fq, err)
	}
	sha = pickLsRemoteSha(out, fq)
	if sha == "" {
		return "", fmt.Sprintf("origin has no %s (git ls-remote returned nothing) — no expected sha to compare against", fq)
	}
	return sha, ""
}

// qualifyDeployRef maps a DEPLOY_REF onto its fully-qualified remote ref:
// pull/N/head → refs/pull/N/head, anything else → refs/heads/<branch>. An
// already-qualified ref is passed through.
func qualifyDeployRef(ref string) string {
	ref = strings.TrimSpace(ref)
	switch {
	case strings.HasPrefix(ref, "refs/"):
		return ref
	case strings.HasPrefix(ref, "pull/"):
		return "refs/" + ref
	default:
		return "refs/heads/" + ref
	}
}

// deployLsRemote runs `git ls-remote origin <fully-qualified-ref>`. A package
// var so tests supply output without a network round-trip. The repo is public,
// so this needs no credentials.
var deployLsRemote = func(fqref string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "ls-remote", "origin", fqref)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	b, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// pickLsRemoteSha takes the sha whose ref column EXACTLY equals the requested
// ref — never "the first line", because ls-remote can answer with more than one.
func pickLsRemoteSha(out, fqref string) string {
	for _, ln := range strings.Split(out, "\n") {
		f := strings.Fields(strings.TrimSpace(ln))
		if len(f) == 2 && f[1] == fqref {
			return f[0]
		}
	}
	return ""
}

// deployReadback is the classified verdict plus everything its sentence needs.
type deployReadback struct {
	outcome  string
	served   string
	previous string
	expected string
	problem  string
}

// performDeployReadback runs the AFTER read (with retries) and classifies. The
// --host path never gets here with a real answer: --host INVENTS the health FQDN
// (deriveHealthHost) while the box's own gate curls with --resolve, so the CLI
// and the box do not resolve the same name — that path declares UNPERFORMABLE
// rather than borrowing the script's confidence.
func performDeployReadback(via, healthHost, expected, expectedProblem string, before deployCommitRead) deployReadback {
	if via == "--host" {
		return deployReadback{
			outcome:  deployUnperformable,
			expected: expected,
			problem: fmt.Sprintf("--host was used, so %s is a GUESSED health FQDN — the box gates itself with curl --resolve and the CLI cannot confirm it is reading the same box; re-run by fleet name for a proven read-back",
				healthHost),
		}
	}
	after := readDeployCommit(healthHost)
	for i := 1; i < deployReadbackTries; i++ {
		if rb := classifyDeployReadback(expected, expectedProblem, before, after); rb.outcome != deployStall && rb.outcome != deployMismatch {
			break
		}
		deploySleep(deployReadbackWait)
		after = readDeployCommit(healthHost)
	}
	return classifyDeployReadback(expected, expectedProblem, before, after)
}

// classifyDeployReadback is the PURE verdict. Comparison is prefix-based in ONE
// direction — the SERVED sha must be a prefix of the EXPECTED full sha — because
// short-sha length is adaptive (7 in a depth-1 clone, 9 elsewhere, 40 from
// ls-remote) for the SAME commit; `==` would manufacture a false MISMATCH, and
// the reverse direction would compare a 40-char expectation against a 9-char
// prefix and never match.
func classifyDeployReadback(expected, expectedProblem string, before, after deployCommitRead) deployReadback {
	rb := deployReadback{expected: expected, served: after.commit, previous: before.commit}
	switch {
	case expectedProblem != "":
		rb.outcome, rb.problem = deployUnperformable, expectedProblem
		return rb
	case after.problem != "":
		rb.outcome, rb.problem = deployUnperformable, after.problem
		return rb
	}
	if deployShaMatches(after.commit, expected) {
		if before.problem == "" && deployShaMatches(before.commit, expected) {
			rb.outcome = deployAlreadyAt
			return rb
		}
		rb.outcome = deployAdvanced
		return rb
	}
	if before.problem == "" && before.commit == after.commit {
		rb.outcome = deployStall
		return rb
	}
	rb.outcome = deployMismatch
	return rb
}

// deployShaMatches is served-is-a-prefix-of-expected, the only safe direction.
func deployShaMatches(served, expected string) bool {
	if served == "" || expected == "" {
		return false
	}
	return strings.HasPrefix(expected, served)
}

// line renders the outcome. There is no bare checkmark anywhere: every ✓ names
// the sha the box actually serves, and an unperformable read-back is stated in
// the same breath as the deploy that could not be verified.
func (rb deployReadback) line(target, healthHost string) string {
	switch rb.outcome {
	case deployAdvanced:
		was := rb.previous
		if was == "" {
			was = "unknown"
		}
		return fmt.Sprintf("✓ %s ADVANCED — now serves %s (was %s) — https://%s", target, rb.served, was, healthHost)
	case deployAlreadyAt:
		return fmt.Sprintf("✓ %s already at %s — the box did not rebuild (coalesce); pass --clean to force one — https://%s", target, rb.served, healthHost)
	case deployStall:
		return fmt.Sprintf("STALL: the deploy exited 0 but %s still serves %s (expected %s) — nothing advanced", target, rb.served, shortSha(rb.expected))
	case deployMismatch:
		return fmt.Sprintf("MISMATCH: %s serves %s, not the requested %s", target, rb.served, shortSha(rb.expected))
	default:
		return fmt.Sprintf("→ %s deploy ran and exited 0, but the read-back is UNPERFORMABLE, so this is NOT a proof it advanced: %s", target, rb.problem)
	}
}

// shortSha trims a full sha to 12 for reading; anything shorter is untouched.
func shortSha(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}

// resolveDeployRef maps the ref flags onto the DEPLOY_REF the box fetches:
// --branch x → x; --pr n → pull/n/head; neither → main. --branch and --pr are
// mutually exclusive, and --pr must be a positive integer.
func resolveDeployRef(branch, pr string) (string, error) {
	branch = strings.TrimSpace(branch)
	pr = strings.TrimSpace(pr)
	if branch != "" && pr != "" {
		return "", fmt.Errorf("--branch and --pr are mutually exclusive — pick one")
	}
	if pr != "" {
		n, err := strconv.Atoi(pr)
		if err != nil || n <= 0 {
			return "", fmt.Errorf("--pr wants a positive PR number, got %q", pr)
		}
		return fmt.Sprintf("pull/%d/head", n), nil
	}
	if branch != "" {
		return branch, nil
	}
	return "main", nil
}

// resolveDeployHost applies the host-resolution precedence and derives the health
// FQDN. PURE (no network, no env reads) so the precedence is unit-tested directly:
// the caller passes the already-resolved control-plane row (cpHost/cpURL/cpFound)
// and the already-read BARKPARK_STAGING_HOST value.
//
//	--host            wins outright
//	control-plane     the fleet row's Barkpark.Host (when found)
//	env               BARKPARK_STAGING_HOST
//	otherwise         a clear error naming all three paths
//
// healthHost (→ BARKPARK_HEALTH_HOST) is the PUBLIC FQDN the deploy script health-
// gates against, derived from the fleet row's URL when known, else from the target
// name — never the raw SSH IP, and never the guerrilla default the script would
// otherwise fall back to.
func resolveDeployHost(target, hostFlag, envHost, cpHost, cpURL string, cpFound bool) (host, healthHost, via string, err error) {
	healthHost = deriveHealthHost(target, cpURL)
	switch {
	case strings.TrimSpace(hostFlag) != "":
		return strings.TrimSpace(hostFlag), healthHost, "--host", nil
	case cpFound && strings.TrimSpace(cpHost) != "":
		return strings.TrimSpace(cpHost), healthHost, "control-plane", nil
	case strings.TrimSpace(envHost) != "":
		return strings.TrimSpace(envHost), healthHost, "BARKPARK_STAGING_HOST", nil
	default:
		return "", "", "", fmt.Errorf("can't resolve a host for %q — pass --host <ip>, or run `bp login` so the fleet can resolve it by name, or set BARKPARK_STAGING_HOST", target)
	}
}

// deriveHealthHost picks the public FQDN for BARKPARK_HEALTH_HOST: the fleet row's
// URL host when known; else the target verbatim when it already looks like an FQDN
// (contains a dot); else <target>.barkpark.cloud. This keeps the staging health
// check off guerrilla's default and on the box actually being deployed.
func deriveHealthHost(target, cpURL string) string {
	if h := hostOf(cpURL); h != "" {
		return h
	}
	t := strings.TrimSpace(target)
	if t == "" {
		return ""
	}
	if strings.Contains(t, ".") {
		return t
	}
	return t + ".barkpark.cloud"
}

// buildDeployRemoteScript renders the bootstrap the box runs. It reads the fed
// local instance-deploy.sh off stdin into a temp file, then runs it under the
// channel-seam env contract (DEPLOY_REF / DEPLOY_REMOTE / BARKPARK_HEALTH_HOST).
// With clean it first removes .instance-deploy-last (the force-rebuild lever) so
// a same-SHA re-run rebuilds instead of coalescing to a no-op. PURE so the exact
// remote invocation is asserted in a test (and printed by --dry-run).
func buildDeployRemoteScript(ref, remote, healthHost string, clean bool) string {
	var b strings.Builder
	b.WriteString("set -uo pipefail\n")
	if clean {
		b.WriteString("rm -f " + deployRemoteAppDir + "/.instance-deploy-last\n")
	}
	b.WriteString(`tmp="$(mktemp /tmp/bp-instance-deploy.XXXXXX.sh)"` + "\n")
	b.WriteString(`cat > "$tmp"` + "\n")
	b.WriteString(`chmod +x "$tmp"` + "\n")
	b.WriteString("DEPLOY_REF=" + shSingleQuote(ref) +
		" DEPLOY_REMOTE=" + shSingleQuote(remote) +
		" BARKPARK_HEALTH_HOST=" + shSingleQuote(healthHost) +
		` bash "$tmp"` + "\n")
	b.WriteString("rc=$?\n")
	b.WriteString(`rm -f "$tmp"` + "\n")
	b.WriteString("exit $rc\n")
	return b.String()
}

// shSingleQuote wraps s in single quotes, escaping any embedded single quote —
// the shell-safe rendering for an env value (mirrors shJoinArgv's quoting).
func shSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// deploySmokeURLs is the three golden-path checks printed on success — the SAME
// trio the router card documents (API answers · Studio gated · documents query).
func deploySmokeURLs(fqdn string) []string {
	base := "https://" + fqdn
	return []string{
		base + "/api/schemas",
		base + "/studio",
		base + "/v1/data/query/production/post",
	}
}

// deployDryRun prints the resolved plan without connecting: host, health FQDN,
// DEPLOY_REF, and the exact remote invocation. -o json/yaml emit the plan as a
// machine envelope.
func deployDryRun(out *writer, target, host, healthHost, ref, via string, clean bool, remoteScript string) int {
	if out.output == "json" || out.output == "yaml" {
		payload := map[string]any{
			"ok":                true,
			"dry_run":           true,
			"target":            target,
			"host":              host,
			"health_host":       healthHost,
			"deploy_ref":        ref,
			"deploy_remote":     "origin",
			"via":               via,
			"clean":             clean,
			"remote_invocation": remoteScript,
			"smoke_urls":        deploySmokeURLs(healthHost),
		}
		if out.output == "yaml" {
			out.renderYAML(toGeneric(payload))
		} else {
			out.renderJSON(payload)
		}
		return exitOK
	}

	out.outf("dry-run — nothing was sent to the box.")
	out.outf("  target:        %s", target)
	out.outf("  ssh host:      %s  (via %s)", host, via)
	out.outf("  health host:   %s", healthHost)
	out.outf("  DEPLOY_REF:    %s", ref)
	out.outf("  DEPLOY_REMOTE: origin")
	if clean {
		out.outf("  --clean:       rm -f %s/.instance-deploy-last first", deployRemoteAppDir)
	}
	out.outf("")
	out.outf("remote invocation (the box runs this, fed the local deploy/instance-deploy.sh):")
	for _, ln := range strings.Split(strings.TrimRight(remoteScript, "\n"), "\n") {
		out.outf("  %s", ln)
	}
	return exitOK
}

// printCloudDeployHelp writes `bp cloud deploy` usage.
func printCloudDeployHelp(out *writer) {
	const help = `bp cloud deploy — push any git ref to a Barkpark instance (staging's whole point).

USAGE
  bp cloud deploy <target> [--branch <x> | --pr <n>] [--host <ip>] [--clean] [--dry-run]

WHAT IT DOES
  Streams the LOCAL deploy/instance-deploy.sh to the target box over SSH and runs
  it with DEPLOY_REF / DEPLOY_REMOTE / BARKPARK_HEALTH_HOST — the same blue/green
  mechanics that deploy guerrilla, pointed at any ref. Try a build on staging
  BEFORE the auto-deploy-on-merge train ships it everywhere.

  It NEVER changes your active server: deploying to staging cannot repoint the
  ambient bp target. (To keep bp off staging for good, note that ` + "`bp use`" + ` refuses
  to default to a staging server without --force — use ` + "`bp -s <name>`" + ` instead.)

HOST RESOLUTION (first match wins)
  --host <ip>            deploy straight to this box, no network lookup
  the fleet              the instance's host, resolved by name (needs ` + "`bp login`" + `)
  BARKPARK_STAGING_HOST  a pinned staging box IP
  otherwise              a clear error naming all three paths

REF
  --branch <x>   deploy branch x           (DEPLOY_REF=x)
  --pr <n>       deploy PR n's head        (DEPLOY_REF=pull/n/head)
  (neither)      deploy main               (DEPLOY_REF=main)

PROOF (the ssh exit code is not the success claim)
  After the run it resolves the ref's sha with ` + "`git ls-remote`" + ` and reads the box's
  own https://<health-host>/status.json. Exactly one of four outcomes is printed:
    ADVANCED        now serves <sha> (was <old>)
    already at      the box already ran that sha — no rebuild happened (--clean forces one)
    STALL/MISMATCH  the run exited 0 but the box did not advance — a NAMED non-zero
    UNPERFORMABLE   the read-back could not be done (said outright, never a bare ✓)
  --host makes the health FQDN a guess, so that path is always UNPERFORMABLE —
  deploy by fleet name for a proven read-back.

FLAGS
  --clean        remove .instance-deploy-last first (force a rebuild, no coalesce)
  --dry-run      print the resolved host, ref, and exact remote invocation; connect to nothing
  -o json        emit the plan (with --dry-run) or the result as an envelope`
	out.outf("%s", help)
}
