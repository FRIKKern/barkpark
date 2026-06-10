package setup

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

// Provider slugs the provision target understands.
const (
	ProviderHetzner = "hetzner"
	ProviderAzure   = "azure"
)

// provisionDefaults supplies sane region/type fallbacks per provider so a bare
// `--provider hetzner` still renders a complete, copy-pasteable plan.
type provisionDefaults struct {
	region     string
	serverType string
	image      string
}

func defaultsFor(provider string) provisionDefaults {
	switch provider {
	case ProviderHetzner:
		return provisionDefaults{region: "nbg1", serverType: "cax11", image: "ubuntu-22.04"}
	case ProviderAzure:
		return provisionDefaults{region: "westeurope", serverType: "Standard_B2pts_v2", image: "Ubuntu2204"}
	default:
		return provisionDefaults{}
	}
}

// executeProvision is the STAGED cloud-provisioning seam. It ALWAYS defaults to a
// plan/dry-run: it prints the exact provider CLI commands that WOULD create a
// host plus a clear "needs <token> + --yes to create" line. Real creation runs
// ONLY when opts.Confirm AND the provider CLI + credential are present; on a
// successful create it captures the new IP and CHAINS into the DEPLOY target.
// When the CLI/credential is absent it prints install/auth guidance and returns
// a non-nil error so the caller exits non-zero cleanly.
func executeProvision(plan SetupPlan, opts Options) error {
	w := opts.out()

	if err := validateProvision(plan); err != nil {
		return err
	}

	def := defaultsFor(plan.Provider)
	region := firstNonEmpty(plan.Region, def.region)
	serverType := firstNonEmpty(plan.ServerType, def.serverType)

	var (
		createCmds []step
		cliName    string
		tokenHint  string
		authCmd    string
		haveAuth   bool
	)

	switch plan.Provider {
	case ProviderHetzner:
		cliName = "hcloud"
		tokenHint = "HCLOUD_TOKEN (or an `hcloud context` active)"
		authCmd = "hcloud context create barkpark   # paste an API token"
		haveAuth = os.Getenv("HCLOUD_TOKEN") != "" || hcloudContextActive()
		createCmds = []step{
			{
				Title: "create the server",
				Cmd: shJoin([]string{
					"hcloud", "server", "create",
					"--name", "barkpark",
					"--type", serverType,
					"--image", def.image,
					"--location", region,
					"--ssh-key", "<your-ssh-key-name>",
				}),
				Argv: []string{
					"hcloud", "server", "create",
					"--name", "barkpark",
					"--type", serverType,
					"--image", def.image,
					"--location", region,
					"--ssh-key", provisionSSHKey(),
				},
			},
			{
				Title: "read back the new server's public IPv4",
				Cmd:   shJoin([]string{"hcloud", "server", "ip", "barkpark"}),
				Argv:  []string{"hcloud", "server", "ip", "barkpark"},
			},
		}
	case ProviderAzure:
		cliName = "az"
		tokenHint = "an `az login` session + selected subscription"
		authCmd = "az login   # then: az account set --subscription <id>"
		haveAuth = azLoggedIn()
		createCmds = []step{
			{
				Title: "create the resource group (idempotent)",
				Cmd:   shJoin([]string{"az", "group", "create", "--name", "barkpark", "--location", region}),
				Argv:  []string{"az", "group", "create", "--name", "barkpark", "--location", region},
			},
			{
				Title: "create the VM",
				Cmd: shJoin([]string{
					"az", "vm", "create",
					"--resource-group", "barkpark",
					"--name", "barkpark",
					"--image", def.image,
					"--size", serverType,
					"--location", region,
					"--admin-username", "root",
					"--generate-ssh-keys",
				}),
				Argv: []string{
					"az", "vm", "create",
					"--resource-group", "barkpark",
					"--name", "barkpark",
					"--image", def.image,
					"--size", serverType,
					"--location", region,
					"--admin-username", "root",
					"--generate-ssh-keys",
				},
			},
			{
				Title: "read back the new VM's public IP",
				Cmd: shJoin([]string{
					"az", "vm", "show", "-d", "--resource-group", "barkpark",
					"--name", "barkpark", "--query", "publicIps", "-o", "tsv",
				}),
				Argv: []string{
					"az", "vm", "show", "-d", "--resource-group", "barkpark",
					"--name", "barkpark", "--query", "publicIps", "-o", "tsv",
				},
			},
		}
	}

	haveCLI := lookExec(cliName)

	// ── Always render the plan (this IS the default for provision). ──
	if opts.DryRun || !opts.Confirm {
		// JSON dry-run is rendered by the caller from BuildPlan; print nothing.
		if !opts.json() {
			heading := fmt.Sprintf("setup provision (%s) — would create a %s server in %s [STAGED]", plan.Provider, serverType, region)
			printPlan(w, heading, createCmds)
			fmt.Fprintf(w, "\n  then CHAIN into deploy: ssh root@<new-ip> '%sbash -s' < deploy.sh\n",
				chainedDeployEnv(firstNonEmpty(plan.Domain, "<domain>"), plan.Plugins))
			fmt.Fprintf(w, "  plugins: %s\n", PluginsSummary(plan.Plugins))
			fmt.Fprintf(w, "\n  needs: %s + --yes to actually create\n", tokenHint)
			fmt.Fprintf(w, "  cli:   %s %s\n", cliName, presence(haveCLI))
			fmt.Fprintf(w, "  auth:  %s %s\n", tokenHint, presence(haveAuth))
			if opts.DryRun {
				fmt.Fprintf(w, "  (no execution — dry run; nothing was created)\n")
			} else {
				fmt.Fprintf(w, "  (no --yes — plan only; nothing was created)\n")
			}
		}
		return nil
	}

	// ── Real creation path: opts.Confirm AND CLI+auth present. ──
	if !haveCLI {
		return fmt.Errorf("setup provision %s: `%s` CLI not found on PATH\n  install it, authenticate (%s), then re-run with --yes\n  e.g. %s", plan.Provider, cliName, tokenHint, authCmd)
	}
	if !haveAuth {
		return fmt.Errorf("setup provision %s: no credential found (need %s)\n  authenticate then re-run with --yes\n  e.g. %s", plan.Provider, tokenHint, authCmd)
	}
	if strings.TrimSpace(plan.Domain) == "" {
		return fmt.Errorf("setup provision %s: --domain is required to chain into deploy after the host is created", plan.Provider)
	}

	ctx := context.Background()
	if !opts.json() {
		fmt.Fprintf(w, ">> Provisioning a %s server on %s\n", serverType, plan.Provider)
	}

	// Run the create step(s); the LAST step's stdout is the IP read-back.
	var newIP string
	for i, s := range createCmds {
		if i == len(createCmds)-1 {
			out, err := runCapture(ctx, s.Argv[0], s.Argv[1:]...)
			if err != nil {
				return fmt.Errorf("setup provision %s: reading new server IP failed: %w", plan.Provider, err)
			}
			newIP = strings.TrimSpace(out)
			if !opts.json() {
				fmt.Fprintf(w, "   new server IP: %s\n", newIP)
			}
			continue
		}
		if err := runStep(ctx, w, s); err != nil {
			return fmt.Errorf("setup provision %s: %w", plan.Provider, err)
		}
	}
	if newIP == "" {
		return fmt.Errorf("setup provision %s: created the server but could not determine its public IP — deploy manually: bp setup --target deploy --ssh-host root@<ip> --domain %s", plan.Provider, plan.Domain)
	}

	// Brief settle before SSH is reachable.
	if !opts.json() {
		fmt.Fprintf(w, ">> Waiting for SSH on %s to come up…\n", newIP)
	}
	time.Sleep(5 * time.Second)

	// CHAIN into deploy.
	if !opts.json() {
		fmt.Fprintf(w, ">> Chaining into deploy on root@%s\n", newIP)
	}
	deployPlan := plan
	deployPlan.Target = TargetDeploy
	deployPlan.SSHHost = "root@" + newIP
	deployPlan.Scheme = firstNonEmpty(plan.Scheme, "https")
	if err := executeDeploy(deployPlan, opts); err != nil {
		return err
	}
	if opts.Result != nil {
		opts.Result.Target = TargetProvision
	}
	return nil
}

// buildProvisionPlan builds the structured dry-run plan for provision. It mirrors
// the human plan: the provider-CLI create steps, the chained-deploy env, the
// plugin selection, and the two prerequisite needs (the provider CLI on PATH and
// the credential). Provision is STAGED — destructive + requires-confirm.
func buildProvisionPlan(plan SetupPlan, _ Options) (Plan, error) {
	if err := validateProvision(plan); err != nil {
		return Plan{}, err
	}
	def := defaultsFor(plan.Provider)
	region := firstNonEmpty(plan.Region, def.region)
	serverType := firstNonEmpty(plan.ServerType, def.serverType)

	var (
		cliName   string
		tokenHint string
		haveAuth  bool
		steps     []step
	)
	switch plan.Provider {
	case ProviderHetzner:
		cliName = "hcloud"
		tokenHint = "HCLOUD_TOKEN (or an `hcloud context` active)"
		haveAuth = os.Getenv("HCLOUD_TOKEN") != "" || hcloudContextActive()
		steps = []step{
			{Title: "create the server", Cmd: shJoin([]string{
				"hcloud", "server", "create", "--name", "barkpark",
				"--type", serverType, "--image", def.image, "--location", region,
				"--ssh-key", "<your-ssh-key-name>",
			})},
			{Title: "read back the new server's public IPv4", Cmd: shJoin([]string{"hcloud", "server", "ip", "barkpark"})},
		}
	case ProviderAzure:
		cliName = "az"
		tokenHint = "an `az login` session + selected subscription"
		haveAuth = azLoggedIn()
		steps = []step{
			{Title: "create the resource group (idempotent)", Cmd: shJoin([]string{"az", "group", "create", "--name", "barkpark", "--location", region})},
			{Title: "create the VM", Cmd: shJoin([]string{
				"az", "vm", "create", "--resource-group", "barkpark", "--name", "barkpark",
				"--image", def.image, "--size", serverType, "--location", region,
				"--admin-username", "root", "--generate-ssh-keys",
			})},
			{Title: "read back the new VM's public IP", Cmd: shJoin([]string{
				"az", "vm", "show", "-d", "--resource-group", "barkpark",
				"--name", "barkpark", "--query", "publicIps", "-o", "tsv",
			})},
		}
	}
	haveCLI := lookExec(cliName)

	p := Plan{
		Target:          TargetProvision,
		DryRun:          true,
		Destructive:     true, // creates a billable cloud host, then chains into deploy
		RequiresConfirm: true,
		Plugins:         planPlugins(plan.Plugins),
		Profile:         plan.profileOrDefault(),
		Provider:        plan.Provider,
		Region:          region,
		ServerType:      serverType,
		Env:             map[string]string{},
		Needs: []PlanNeed{
			{What: cliName, Present: haveCLI},
			{What: tokenHint, Present: haveAuth},
		},
	}
	if value, set := PluginsEnvValue(plan.Plugins); set {
		p.Env["BARKPARK_PLUGINS"] = value
	}
	for _, s := range steps {
		p.addStep(s.Title, s.Cmd)
	}
	return p, nil
}

// validateProvision enforces a known provider; region/type fall back to
// provider defaults so they are optional.
func validateProvision(plan SetupPlan) error {
	switch plan.Provider {
	case ProviderHetzner, ProviderAzure:
		return nil
	case "":
		return fmt.Errorf("setup provision: --provider is required (hetzner|azure)")
	default:
		return fmt.Errorf("setup provision: unknown provider %q (want hetzner|azure)", plan.Provider)
	}
}

// chainedDeployEnv renders the env prefix (with a trailing space) for the chained
// deploy line in the provision plan: DOMAIN + PHX_SCHEME always, BARKPARK_PLUGINS
// only when the selection is set, so an unset selection leaves no dangling space.
func chainedDeployEnv(domain string, selected []string) string {
	parts := []string{"DOMAIN=" + domain, "PHX_SCHEME=https"}
	if value, set := PluginsEnvValue(selected); set {
		parts = append(parts, "BARKPARK_PLUGINS="+value)
	}
	return strings.Join(parts, " ") + " "
}

// provisionSSHKey resolves the ssh-key name to pass to `hcloud server create`.
// It honours BARKPARK_SSH_KEY when set; otherwise a placeholder the operator
// must replace (real creation is behind --yes, so a wrong key fails fast there,
// never in dry-run).
func provisionSSHKey() string {
	if k := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY")); k != "" {
		return k
	}
	return "barkpark"
}

// hcloudContextActive reports whether an `hcloud` context is configured (a cheap
// proxy for "the operator authenticated"). It never errors loudly — absence
// just means we treat auth as missing.
func hcloudContextActive() bool {
	if !lookExec("hcloud") {
		return false
	}
	out, err := runCapture(context.Background(), "hcloud", "context", "active")
	return err == nil && strings.TrimSpace(out) != ""
}

// azLoggedIn reports whether `az account show` succeeds (the operator has an
// active az login + subscription).
func azLoggedIn() bool {
	if !lookExec("az") {
		return false
	}
	_, err := runCapture(context.Background(), "az", "account", "show")
	return err == nil
}

// presence renders a ✓/✗ marker for the plan's cli/auth readiness lines.
func presence(ok bool) string {
	if ok {
		return "(present)"
	}
	return "(MISSING)"
}
