package setup

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cli/setup/assets"
)

// BPVersion is the bp binary version the deploy dry-run shows on the
// "(embedded in bp <version>)" label. The cli package stamps it from its
// ldflags-injected cliVersion at init; "dev" for plain go-build binaries.
var BPVersion = "dev"

// executeDeploy deploys Barkpark to a server the operator already owns over SSH,
// by streaming the repo's deploy.sh into `bash -s` on the remote with the
// DOMAIN / PHX_SCHEME / BARKPARK_PLUGINS env the script reads.
//
// DRY-RUN-FIRST: a dry run prints the EXACT ssh invocation, the env that rides
// with it, and the local deploy.sh path — WITHOUT connecting to anything. A real
// run requires opts.Confirm (it provisions/restarts a live server), streams the
// installer with live progress, verifies the new server's /v1/capabilities +
// /studio, then points bp at https://<domain>.
func executeDeploy(plan SetupPlan, opts Options) error {
	w := opts.out()

	if err := validateDeploy(plan); err != nil {
		return err
	}

	host := normalizeSSHHost(plan.SSHHost)
	scheme := firstNonEmpty(plan.Scheme, "https")
	envValue, envSet := PluginsEnvValue(plan.Plugins)
	profile := plan.profileOrDefault()

	scriptPath, _ := locateDeployScript()
	// A checkout's script wins (operators testing local edits); a curl-installed
	// bp falls back to the go:embedded copy. The dry-run labels the fallback.
	displayScript := scriptPath
	embedded := false
	if displayScript == "" {
		displayScript = fmt.Sprintf("deploy.sh (embedded in bp %s)", BPVersion)
		embedded = true
	}

	// Build the env prefix the remote bash sees: the display form (token
	// redacted) and, on a real clean run, the live form with the generated
	// admin token. The seed step inherits BARKPARK_SEED_* from this prefix —
	// deploy.sh itself never generates tokens.
	envParts := []string{
		"DOMAIN=" + plan.Domain,
		"PHX_SCHEME=" + scheme,
		"BARKPARK_SEED_PROFILE=" + profile,
	}
	if profile == ProfileClean {
		envParts = append(envParts, "BARKPARK_SEED_ADMIN_TOKEN=****")
	}
	if envSet {
		envParts = append(envParts, "BARKPARK_PLUGINS="+envValue)
	}
	displayPrefix := strings.Join(envParts, " ")

	// The remote command: `ssh <host> '<env> bash -s' < deploy.sh`.
	sshArgv := []string{"ssh", host, displayPrefix + " bash -s"}
	rendered := shJoin(sshArgv) + " < " + displayScript

	publicURL := scheme + "://" + plan.Domain

	if opts.DryRun {
		// JSON dry-run is rendered by the caller from BuildPlan; print nothing.
		if !opts.json() {
			fmt.Fprintf(w, "setup deploy — would install Barkpark on %s\n", host)
			fmt.Fprintf(w, "  1. stream the installer into the remote shell:\n")
			fmt.Fprintf(w, "      $ %s\n", rendered)
			fmt.Fprintf(w, "  2. env handed to the remote bash:\n")
			fmt.Fprintf(w, "      DOMAIN=%s\n", plan.Domain)
			fmt.Fprintf(w, "      PHX_SCHEME=%s\n", scheme)
			fmt.Fprintf(w, "      BARKPARK_SEED_PROFILE=%s\n", profile)
			if profile == ProfileClean {
				fmt.Fprintf(w, "      BARKPARK_SEED_ADMIN_TOKEN=**** (generated at run time, never shown in a plan)\n")
			}
			if envSet {
				fmt.Fprintf(w, "      BARKPARK_PLUGINS=%s\n", envValue)
			} else {
				fmt.Fprintf(w, "      (BARKPARK_PLUGINS unset — server discovers all plugins)\n")
			}
			fmt.Fprintf(w, "  3. installer script: %s\n", displayScript)
			fmt.Fprintf(w, "  4. verify %s/v1/capabilities + %s/studio\n", publicURL, publicURL)
			fmt.Fprintf(w, "  5. connect bp to %s\n", publicURL)
			fmt.Fprintf(w, "\n  profile: %s\n", profileSummary(profile))
			fmt.Fprintf(w, "  plugins: %s\n", PluginsSummary(plan.Plugins))
			fmt.Fprintf(w, "  (no execution — dry run; nothing was sent to %s)\n", host)
		}
		return nil
	}

	// Real run gate.
	if !opts.Confirm {
		return fmt.Errorf("setup deploy provisions and restarts a live server (%s) — re-run with --yes to confirm, or --dry-run to preview", host)
	}
	if !lookExec("ssh") {
		return fmt.Errorf("setup deploy: `ssh` not found on PATH")
	}
	if embedded {
		tmp, cleanup, werr := writeEmbeddedDeployScript()
		if werr != nil {
			return fmt.Errorf("setup deploy: %w", werr)
		}
		defer cleanup()
		scriptPath = tmp
	}

	// Clean profile: mint the admin token at execute time and thread it into
	// the seed via the ssh env prefix; the chained connect persists it verified.
	adminToken := ""
	realPrefix := displayPrefix
	if profile == ProfileClean {
		tok, terr := GenerateAdminToken()
		if terr != nil {
			return fmt.Errorf("setup deploy: %w", terr)
		}
		adminToken = tok
		realPrefix = strings.Replace(displayPrefix, "BARKPARK_SEED_ADMIN_TOKEN=****", "BARKPARK_SEED_ADMIN_TOKEN="+adminToken, 1)
	}

	// Stream the installer (the rendered line keeps the redacted prefix).
	if !opts.json() {
		fmt.Fprintf(w, ">> Deploying to %s\n", host)
		fmt.Fprintf(w, "   %s\n", rendered)
	}
	ctx := context.Background()
	if err := streamSSHInstaller(ctx, w, host, realPrefix, scriptPath); err != nil {
		return fmt.Errorf("setup deploy: installer failed: %w", err)
	}

	// One-time admin-token banner — before verify/connect so a flaky network
	// never swallows the only echo of the credential the seed installed.
	if adminToken != "" && !opts.json() {
		fmt.Fprintf(w, "\n  admin token (shown once — store it now):\n")
		fmt.Fprintf(w, "    %s\n", adminToken)
		fmt.Fprintf(w, "  it is also saved to %s (0600) by the connect step below\n", configHint())
	}

	// Verify the new server.
	if !opts.json() {
		fmt.Fprintf(w, "\n>> Verifying %s\n", publicURL)
	}
	if err := verifyServer(publicURL, plan.Token); err != nil {
		return fmt.Errorf("setup deploy: post-install verification failed: %w\n  the installer ran but the server is not answering; check `make logs` on %s", err, host)
	}
	if !opts.json() {
		fmt.Fprintf(w, "   /v1/capabilities OK\n")
		fmt.Fprintf(w, "   /studio OK\n")

		// Point bp here.
		fmt.Fprintf(w, "\n>> Connecting bp to %s\n", publicURL)
	}
	connectPlan := SetupPlan{
		Target:    TargetConnect,
		Server:    publicURL,
		Token:     plan.Token,
		Workspace: plan.Workspace,
		Project:   plan.Project,
		Dataset:   plan.Dataset,
		Profile:   profile,
	}
	if adminToken != "" {
		connectPlan.Token = adminToken
	}
	connOpts := opts
	var connResult Result
	if connOpts.Result == nil {
		connOpts.Result = &connResult
	}
	if err := executeConnect(connectPlan, connOpts); err != nil {
		return err
	}
	if adminToken != "" {
		if tier := connOpts.Result.Tier; tier != "admin" {
			return fmt.Errorf("setup deploy: generated admin token resolved tier %q, want admin — the seed may have skipped the token bootstrap (an unrevoked admin token already exists on %s?)", tier, host)
		}
	}
	if opts.Result != nil {
		opts.Result.Target = TargetDeploy
	}
	return nil
}

// writeEmbeddedDeployScript materialises the go:embedded deploy.sh into a 0700
// temp file for the ssh stream and returns its path plus the remover.
func writeEmbeddedDeployScript() (string, func(), error) {
	f, err := os.CreateTemp("", "bp-deploy-*.sh")
	if err != nil {
		return "", nil, fmt.Errorf("write embedded deploy.sh: %w", err)
	}
	path := f.Name()
	cleanup := func() { _ = os.Remove(path) }
	if _, err := f.Write(assets.DeployScript); err != nil {
		f.Close()
		cleanup()
		return "", nil, fmt.Errorf("write embedded deploy.sh: %w", err)
	}
	if err := f.Close(); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("write embedded deploy.sh: %w", err)
	}
	if err := os.Chmod(path, 0o700); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("chmod embedded deploy.sh: %w", err)
	}
	return path, cleanup, nil
}

// buildDeployPlan builds the structured dry-run plan for deploy. It re-derives
// the same host/scheme/env/script the executor would use and lays out the five
// ordered steps. It is destructive + outbound (provisions/restarts a live
// server) and requires --yes for the real run.
func buildDeployPlan(plan SetupPlan, _ Options) (Plan, error) {
	if err := validateDeploy(plan); err != nil {
		return Plan{}, err
	}
	host := normalizeSSHHost(plan.SSHHost)
	scheme := firstNonEmpty(plan.Scheme, "https")
	envValue, envSet := PluginsEnvValue(plan.Plugins)
	profile := plan.profileOrDefault()

	scriptPath, _ := locateDeployScript()
	displayScript := scriptPath
	if displayScript == "" {
		displayScript = fmt.Sprintf("deploy.sh (embedded in bp %s)", BPVersion)
	}

	envParts := []string{"DOMAIN=" + plan.Domain, "PHX_SCHEME=" + scheme, "BARKPARK_SEED_PROFILE=" + profile}
	if profile == ProfileClean {
		envParts = append(envParts, "BARKPARK_SEED_ADMIN_TOKEN=****")
	}
	if envSet {
		envParts = append(envParts, "BARKPARK_PLUGINS="+envValue)
	}
	envPrefix := strings.Join(envParts, " ")
	sshArgv := []string{"ssh", host, envPrefix + " bash -s"}
	rendered := shJoin(sshArgv) + " < " + displayScript
	publicURL := scheme + "://" + plan.Domain

	p := Plan{
		Target:          TargetDeploy,
		DryRun:          true,
		Destructive:     true, // provisions/restarts a live server
		RequiresConfirm: true,
		Plugins:         planPlugins(plan.Plugins),
		Profile:         profile,
		ConnectTo:       publicURL,
		Env: map[string]string{
			"DOMAIN":                plan.Domain,
			"PHX_SCHEME":            scheme,
			"BARKPARK_SEED_PROFILE": profile,
		},
	}
	if profile == ProfileClean {
		// Generated at execute time; the plan only ever shows the redaction.
		p.Env["BARKPARK_SEED_ADMIN_TOKEN"] = "****"
	}
	if envSet {
		p.Env["BARKPARK_PLUGINS"] = envValue
	}
	p.addStep("stream the installer into the remote shell", rendered)
	p.addStep("installer script: "+displayScript, "")
	p.addStep(fmt.Sprintf("verify %s/v1/capabilities + %s/studio", publicURL, publicURL), "")
	p.addStep("connect bp to "+publicURL, "")
	return p, nil
}

// validateDeploy enforces the deploy-target invariants: an SSH host and a public
// DOMAIN are both required (deploy.sh hard-fails without DOMAIN — bake the same
// guard CLI-side so the error is fast and local).
func validateDeploy(plan SetupPlan) error {
	if strings.TrimSpace(plan.SSHHost) == "" {
		return fmt.Errorf("setup deploy: --ssh-host is required (e.g. root@1.2.3.4)")
	}
	if strings.TrimSpace(plan.Domain) == "" {
		return fmt.Errorf("setup deploy: --domain is required (the public DNS hostname; deploy.sh refuses to run without it — see docs/ops/studio-nav-bug-2026-04-19.md)")
	}
	if s := strings.TrimSpace(plan.Scheme); s != "" && s != "http" && s != "https" {
		return fmt.Errorf("setup deploy: --scheme %q must be http or https", s)
	}
	return nil
}

// normalizeSSHHost defaults a bare host to root@<host> (deploy.sh assumes root)
// while leaving an explicit user@host untouched.
func normalizeSSHHost(h string) string {
	h = strings.TrimSpace(h)
	if h == "" {
		return h
	}
	if strings.Contains(h, "@") {
		return h
	}
	return "root@" + h
}

// locateDeployScript walks up from cwd to find deploy.sh at a repo root. Returns
// the absolute path, or "" + error when not found within the bounded walk.
func locateDeployScript() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for i := 0; i < 8; i++ {
		cand := filepath.Join(dir, "deploy.sh")
		if st, serr := os.Stat(cand); serr == nil && !st.IsDir() {
			return cand, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("deploy.sh not found above %s", dir)
}

// streamSSHInstaller runs `ssh <host> '<env> bash -s'` with deploy.sh piped on
// stdin, streaming the remote output live to w. This is the real outbound action
// — only reached behind opts.Confirm.
func streamSSHInstaller(ctx context.Context, w writerLike, host, envPrefix, scriptPath string) error {
	f, err := os.Open(scriptPath)
	if err != nil {
		return fmt.Errorf("open deploy.sh: %w", err)
	}
	defer f.Close()

	s := step{
		Title: "stream deploy.sh into the remote shell",
		Argv:  []string{"ssh", host, envPrefix + " bash -s"},
	}
	// runStep does not feed stdin; build the command directly here so we can
	// wire the script as stdin.
	return runStepWithStdin(ctx, asWriter(w), s, f)
}
