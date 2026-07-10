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
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

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

	feeder := newDeployFeeder(host)
	output, derr := feeder.RunFeed(cloudCtx(), "instance-deploy", remoteScript, strings.NewReader(script))
	if s := strings.TrimRight(output, "\n"); strings.TrimSpace(s) != "" {
		out.outf("%s", s)
	}
	if derr != nil {
		return useError(out, "failed", "deploy failed: "+derr.Error(), exitGeneric)
	}

	out.outf("")
	out.outf("✓ %s deployed — https://%s", target, healthHost)
	out.outf("  smoke:")
	for _, u := range deploySmokeURLs(healthHost) {
		out.outf("    %s", u)
	}
	return exitOK
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

FLAGS
  --clean        remove .instance-deploy-last first (force a rebuild, no coalesce)
  --dry-run      print the resolved host, ref, and exact remote invocation; connect to nothing
  -o json        emit the plan (with --dry-run) or the result as an envelope`
	out.outf("%s", help)
}
