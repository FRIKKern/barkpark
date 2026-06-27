package cli

import (
	"context"
	"fmt"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// This file is the CONTROL-PLANE half of the bp Cloud commands (cloud-12) — the
// counterparts to cloud_cmd.go's local-only surface. Where cloud_cmd.go reads and
// writes on-disk config without ever touching the network, everything here drives
// the Barkpark Cloud control plane through internal/cloudclient:
//
//   - bp login                     — authenticate the user, store the session token
//   - bp barkparks  (when logged in) — the AUTHORITATIVE fleet from the registry
//   - bp provider add hetzner …    — connect a cloud account to provision into
//   - bp launch hetzner --name …   — provision a Barkpark into a provider
//   - bp go-live --name …          — provision a fully-managed Barkpark
//
// Each authed command resolves the saved CloudURL + CloudToken via
// Config.CloudClient and fails fast with "run `bp login` first" when no token is
// present. The commands stay thin: parse flags, call one cloudclient method,
// render the result through the shared writer. No retries, no wizards (beyond the
// password prompt), no client-side provisioning — the control plane owns that.

// cloudCtx is the context every control-plane call runs under. A package var so a
// future caller (or test) can swap in a cancellable / deadlined context without
// threading one through every signature; today it is the process background.
var cloudCtx = context.Background

// runLoginCloud is the `bp login` built-in — it REPLACES the v1 token-stub. It
// reads an email (--email/--user flag or prompt) and a password (--password flag,
// BARKPARK_PASSWORD env, or a non-echoed prompt), authenticates against the
// control plane, and stores CloudToken + CloudURL (+ team) in config 0600.
//
// --url overrides the control-plane URL (default https://api.barkpark.cloud) and
// is persisted so subsequent Cloud commands hit the same plane. When no control
// plane is reachable / configured the error is surfaced verbatim.
func runLoginCloud(out *writer, args []string) int {
	jsonOut := out.output == "json"

	for _, a := range args {
		if a == "-h" || a == "--help" {
			printLoginHelp(out)
			return exitOK
		}
	}

	email, password, url, perr := parseLoginArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	// URL precedence: explicit --url > saved CloudURL > the baked default. Persist
	// whichever we end up using so the rest of the session is consistent.
	base := strings.TrimSpace(url)
	if base == "" {
		base = strings.TrimSpace(cfg.CloudURL)
	}
	if base == "" {
		base = cloudclient.DefaultBaseURL
	}

	// Email: flag wins, else prompt on a TTY. No silent default — an empty email is
	// a usage error so we never POST a blank credential.
	if email == "" {
		email = promptLine(out, "Email: ")
	}
	if strings.TrimSpace(email) == "" {
		return useError(out, "usage", "email required — pass --email <addr> or answer the prompt", exitUsage)
	}

	// Password: flag > env > non-echoed prompt.
	if password == "" {
		password = os.Getenv("BARKPARK_PASSWORD")
	}
	if password == "" {
		password = promptPassword(out, "Password: ")
	}
	if password == "" {
		return useError(out, "usage", "password required — pass --password, set BARKPARK_PASSWORD, or answer the prompt", exitUsage)
	}

	client := &cloudclient.Client{BaseURL: base}
	resp, lerr := client.Login(cloudCtx(), email, password)
	if lerr != nil {
		// A login failure is an auth problem (bad creds) or a connectivity one; both
		// map to exit 3 here so scripts can branch on "could not authenticate".
		return useError(out, "auth", "login failed: "+lerr.Error(), exitAuth)
	}

	cfg.CloudURL = base
	cfg.CloudToken = resp.Token
	cfg.CloudTeam = resp.TeamID
	if serr := SaveConfig(cfg); serr != nil {
		return useError(out, "failed", "save config: "+serr.Error(), exitGeneric)
	}

	if jsonOut {
		out.renderJSON(map[string]any{
			"ok":        true,
			"cloud_url": base,
			"team_id":   resp.TeamID,
		})
		return exitOK
	}

	out.outf("✓ logged in to %s", base)
	if resp.TeamID != "" {
		out.outf("  team: %s", resp.TeamID)
	}
	out.outf("  run 'bp barkparks' to see your fleet")
	return exitOK
}

// runSignupCloud is the `bp signup` built-in — the registration sibling of
// `bp login`. It reads an email (--email flag or prompt), an optional team name
// (--team), and a password (--password flag, BARKPARK_PASSWORD env, or a
// non-echoed prompt typed TWICE that must match), POSTs /v1/auth/register, and on
// 201 stores CloudToken + CloudURL (+ team) in config 0600 exactly like a
// successful login — the new user is logged in immediately.
//
// The confirm-mismatch guard fires BEFORE any network call, so a typo never
// reaches the server. A 409 surfaces the "email already registered — run
// bp login instead" hint; a 422 surfaces the validation message verbatim.
func runSignupCloud(out *writer, args []string) int {
	jsonOut := out.output == "json"

	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSignupHelp(out)
			return exitOK
		}
	}

	email, password, team, url, perr := parseSignupArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	// URL precedence mirrors login: explicit --url > saved CloudURL > the baked
	// default. Persist whichever we end up using.
	base := strings.TrimSpace(url)
	if base == "" {
		base = strings.TrimSpace(cfg.CloudURL)
	}
	if base == "" {
		base = cloudclient.DefaultBaseURL
	}

	// Email is required — flag wins, else prompt on a TTY. No silent default.
	if email == "" {
		email = promptLine(out, "Email: ")
	}
	if strings.TrimSpace(email) == "" {
		return useError(out, "usage", "email required — pass --email <addr> or answer the prompt", exitUsage)
	}

	// Password: flag > env > a non-echoed prompt asked TWICE (must match). When the
	// password comes from a flag/env there is nothing to confirm; only the
	// interactive prompt path asks for a confirmation.
	if password == "" {
		password = os.Getenv("BARKPARK_PASSWORD")
	}
	if password == "" {
		password = promptPassword(out, "Password: ")
		confirm := promptPassword(out, "Confirm password: ")
		if password != confirm {
			// Fail BEFORE any network call — a typo'd password must never be POSTed.
			return useError(out, "usage", "passwords do not match — nothing was sent, try again", exitUsage)
		}
	}
	if password == "" {
		return useError(out, "usage", "password required — pass --password, set BARKPARK_PASSWORD, or answer the prompt", exitUsage)
	}

	client := &cloudclient.Client{BaseURL: base}
	resp, rerr := client.Register(cloudCtx(), email, password, team)
	if rerr != nil {
		// 409 email_taken → point the user at login; everything else (422 validation,
		// connectivity) surfaces verbatim. We match on the message cloudError carried.
		msg := rerr.Error()
		if strings.Contains(msg, "email_taken") {
			return useError(out, "failed", "email already registered — run `bp login` instead", exitGeneric)
		}
		return useError(out, "failed", "signup failed: "+msg, exitGeneric)
	}

	cfg.CloudURL = base
	cfg.CloudToken = resp.Token
	cfg.CloudTeam = resp.TeamID
	if serr := SaveConfig(cfg); serr != nil {
		return useError(out, "failed", "save config: "+serr.Error(), exitGeneric)
	}

	if jsonOut {
		out.renderJSON(map[string]any{
			"ok":        true,
			"cloud_url": base,
			"team_id":   resp.TeamID,
		})
		return exitOK
	}

	out.outf("✓ account created — logged in to %s", base)
	if resp.TeamID != "" {
		out.outf("  team: %s", resp.TeamID)
	}
	out.outf("  run 'bp go-live --name <name>' to provision your first Barkpark")
	return exitOK
}

// runBarkparksCloud is the control-plane path of `bp barkparks`: it fetches the
// AUTHORITATIVE fleet from the registry (GET /v1/barkparks) and renders it. It is
// only reached when a CloudToken is present (runBarkparks branches to it); the
// local KnownServers view (cloud-11) is the no-token fallback.
func runBarkparksCloud(out *writer, cfg *Config) int {
	client := cfg.CloudClient()
	list, err := client.ListBarkparks(cloudCtx())
	if err != nil {
		return useError(out, "failed", "list barkparks: "+err.Error(), exitGeneric)
	}

	if out.output == "json" {
		rows := make([]map[string]any, 0, len(list))
		for _, b := range list {
			rows = append(rows, cloudBarkparkRow(b))
		}
		out.renderJSON(map[string]any{
			"barkparks": rows,
			"source":    "control-plane",
		})
		return exitOK
	}

	if len(list) == 0 {
		out.outf("no Barkparks yet — launch one with 'bp launch hetzner --name <name>' or 'bp go-live --name <name>'")
		return exitOK
	}

	renderCloudBarkparksTable(out, list)
	return exitOK
}

// cloudBarkparkRow projects a control-plane Barkpark onto the JSON row shape — a
// flat map so the -o json output is stable and self-describing.
func cloudBarkparkRow(b cloudclient.Barkpark) map[string]any {
	return map[string]any{
		"id":            b.ID,
		"name":          b.Name,
		"slug":          b.Slug,
		"url":           b.URL,
		"host":          b.Host,
		"mode":          b.Mode,
		"health_status": b.HealthStatus,
		"agent_status":  b.AgentStatus,
		"version":       b.Version,
		"git_commit":    b.GitCommit,
		"team_id":       b.TeamID,
	}
}

// renderCloudBarkparksTable prints the aligned fleet table: NAME · URL · MODE ·
// HEALTH · AGENT. Column widths are computed from the data so the output is
// stable for golden comparison. URL falls back to the host when the server has no
// URL yet (still provisioning).
func renderCloudBarkparksTable(out *writer, list []cloudclient.Barkpark) {
	const (
		hName   = "NAME"
		hURL    = "URL"
		hMode   = "MODE"
		hHealth = "HEALTH"
		hAgent  = "AGENT"
	)
	nameW, urlW, modeW, healthW := len(hName), len(hURL), len(hMode), len(hHealth)
	display := make([]string, len(list))
	for i, b := range list {
		u := b.URL
		if u == "" {
			u = b.Host
		}
		display[i] = u
		if n := len(b.Name); n > nameW {
			nameW = n
		}
		if n := len(u); n > urlW {
			urlW = n
		}
		if n := len(b.Mode); n > modeW {
			modeW = n
		}
		if n := len(b.HealthStatus); n > healthW {
			healthW = n
		}
	}

	out.outf("%-*s  %-*s  %-*s  %-*s  %s", nameW, hName, urlW, hURL, modeW, hMode, healthW, hHealth, hAgent)
	for i, b := range list {
		out.outf("%-*s  %-*s  %-*s  %-*s  %s",
			nameW, b.Name, urlW, display[i], modeW, b.Mode, healthW, b.HealthStatus, b.AgentStatus)
	}
}

// runProvider is the `bp provider <verb>` built-in. Today the only verb is `add`:
//
//	bp provider add hetzner --token <t> [--label <l>]
//
// It connects a cloud account to the control plane (POST /v1/providers) so a
// later `bp launch` can provision into it. Requires a Cloud token.
func runProvider(out *writer, args []string) int {
	jsonOut := out.output == "json"

	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		printProviderHelp(out)
		if len(args) == 0 {
			return exitUsage
		}
		return exitOK
	}

	verb := args[0]
	if verb != "add" {
		out.errf("barkpark: unknown provider command %q", verb)
		out.errf("usage: bp provider add hetzner --token <token> [--label <label>]")
		return exitUsage
	}

	kind, token, label, perr := parseProviderAddArgs(args[1:])
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if kind == "" {
		return useError(out, "usage", "missing provider kind — e.g. bp provider add hetzner --token <token>", exitUsage)
	}
	if token == "" {
		return useError(out, "usage", "--token required — bp provider add "+kind+" --token <token>", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	prov, err := cfg.CloudClient().ConnectProvider(cloudCtx(), kind, token, label)
	if err != nil {
		return useError(out, "failed", "connect provider: "+err.Error(), exitGeneric)
	}

	if jsonOut {
		out.renderJSON(map[string]any{
			"ok": true,
			"provider": map[string]any{
				"id":      prov.ID,
				"kind":    prov.Kind,
				"label":   prov.Label,
				"team_id": prov.TeamID,
			},
		})
		return exitOK
	}

	label = prov.Label
	if label == "" {
		label = prov.Kind
	}
	out.outf("✓ connected %s provider %q (id %s)", prov.Kind, label, prov.ID)
	out.outf("  launch into it with 'bp launch %s --name <name>'", prov.Kind)
	return exitOK
}

// runLaunch is the `bp launch <provider> --name <name>` built-in — provision a
// Barkpark into a connected provider (POST /v1/launch). The provider positional
// (e.g. "hetzner") is passed through to the control plane, which resolves it to
// the Team's connected provider of that kind. Requires a Cloud token.
func runLaunch(out *writer, args []string) int {
	jsonOut := out.output == "json"

	for _, a := range args {
		if a == "-h" || a == "--help" {
			printLaunchHelp(out)
			return exitOK
		}
	}

	provider, name, perr := parseLaunchArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if name == "" {
		return useError(out, "usage", "--name required — bp launch hetzner --name <name>", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	bp, err := cfg.CloudClient().Launch(cloudCtx(), provider, name)
	if err != nil {
		return useError(out, "failed", "launch: "+err.Error(), exitGeneric)
	}

	if jsonOut {
		out.renderJSON(map[string]any{"ok": true, "barkpark": cloudBarkparkRow(bp)})
		return exitOK
	}
	renderProvisioned(out, "launching", bp)
	return exitOK
}

// runGoLive is the `bp go-live --name <name> [--plan <plan>]` built-in —
// provision a fully-managed Barkpark (POST /v1/go-live), the zero-config path
// where the control plane owns the infra (no BYO provider). A missing name
// surfaces the control plane's 422 "name_required". Requires a Cloud token.
func runGoLive(out *writer, args []string) int {
	jsonOut := out.output == "json"

	for _, a := range args {
		if a == "-h" || a == "--help" {
			printGoLiveHelp(out)
			return exitOK
		}
	}

	name, plan, perr := parseGoLiveArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if name == "" {
		return useError(out, "usage", "--name required — bp go-live --name <name> [--plan pro]", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	bp, err := cfg.CloudClient().GoLive(cloudCtx(), name, plan)
	if err != nil {
		return useError(out, "failed", "go-live: "+err.Error(), exitGeneric)
	}

	if jsonOut {
		out.renderJSON(map[string]any{"ok": true, "barkpark": cloudBarkparkRow(bp)})
		return exitOK
	}
	renderProvisioned(out, "going live", bp)
	return exitOK
}

// renderProvisioned prints the human confirmation for a freshly-launched /
// gone-live Barkpark: the control plane returns a provisioning row (health
// "unknown" until the agent phones home), so we show what it gave us and make
// clear provisioning continues server-side.
func renderProvisioned(out *writer, verb string, bp cloudclient.Barkpark) {
	target := bp.URL
	if target == "" {
		target = bp.Host
	}
	out.outf("✓ %s %q", verb, bp.Name)
	if bp.ID != "" {
		out.outf("  id:     %s", bp.ID)
	}
	if target != "" {
		out.outf("  url:    %s", target)
	}
	if bp.Mode != "" {
		out.outf("  mode:   %s", bp.Mode)
	}
	out.outf("  health: %s (provisioning continues — 'bp barkparks' tracks it)", orUnknown(bp.HealthStatus))
}

// orUnknown returns s, or "unknown" when s is empty.
func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// requireCloud loads the config and asserts a Cloud token is present. On a clean
// load with a token it returns (cfg, true); otherwise it emits the right error
// ("run `bp login` first" for a missing token) and returns false. Every authed
// Cloud command (provider/launch/go-live) gates through it.
func requireCloud(out *writer) (*Config, bool) {
	cfg, err := LoadConfig()
	if err != nil {
		useError(out, "failed", "read config: "+err.Error(), exitGeneric)
		return nil, false
	}
	if !cfg.HasCloudToken() {
		useError(out, "auth", "not logged in — run `bp login` first", exitAuth)
		return nil, false
	}
	return cfg, true
}

// promptLine prints prompt to stderr (so it never pollutes piped stdout) and
// reads one line from stdin, trimmed. On a non-TTY / read error it returns "".
func promptLine(out *writer, prompt string) string {
	fmt.Fprint(out.stderr, prompt)
	var line string
	if _, err := fmt.Fscanln(os.Stdin, &line); err != nil {
		return strings.TrimSpace(line)
	}
	return strings.TrimSpace(line)
}

// promptPassword reads a password WITHOUT echoing it, using golang.org/x/term on
// a TTY. On a non-TTY stdin (a pipe / test) it falls back to a plain line read so
// scripted input still works. The prompt goes to stderr.
func promptPassword(out *writer, prompt string) string {
	fmt.Fprint(out.stderr, prompt)
	fd := int(os.Stdin.Fd())
	if term.IsTerminal(fd) {
		raw, err := term.ReadPassword(fd)
		fmt.Fprintln(out.stderr) // the user's Enter is swallowed by ReadPassword
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(raw))
	}
	// Non-TTY: read a line plainly (pipe/test input).
	var line string
	if _, err := fmt.Fscanln(os.Stdin, &line); err != nil {
		return strings.TrimSpace(line)
	}
	return strings.TrimSpace(line)
}

// --- flag parsers (dependency-free, mirroring cloud_cmd.go's hand-rolled style) -

// parseLoginArgs splits `bp login` flags: --email/--user, --password/--pass, --url.
// Each accepts both `--flag value` and `--flag=value`. Any positional or unknown
// flag is a usage error.
func parseLoginArgs(args []string) (email, password, url string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--email" || a == "--user":
			email, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--email="):
			email = a[len("--email="):]
		case strings.HasPrefix(a, "--user="):
			email = a[len("--user="):]
		case a == "--password" || a == "--pass":
			password, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--password="):
			password = a[len("--password="):]
		case strings.HasPrefix(a, "--pass="):
			password = a[len("--pass="):]
		case a == "--url":
			url, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--url="):
			url = a[len("--url="):]
		default:
			return "", "", "", fmt.Errorf("unexpected argument %q (usage: bp login [--email <addr>] [--password <pw>] [--url <url>])", a)
		}
		if err != nil {
			return "", "", "", err
		}
	}
	return email, password, url, nil
}

// parseSignupArgs splits `bp signup` flags: --email/--user, --password/--pass,
// --team, --url. Each accepts both `--flag value` and `--flag=value`. It mirrors
// parseLoginArgs exactly, with the one extra optional --team flag. Any positional
// or unknown flag is a usage error.
func parseSignupArgs(args []string) (email, password, team, url string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--email" || a == "--user":
			email, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--email="):
			email = a[len("--email="):]
		case strings.HasPrefix(a, "--user="):
			email = a[len("--user="):]
		case a == "--password" || a == "--pass":
			password, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--password="):
			password = a[len("--password="):]
		case strings.HasPrefix(a, "--pass="):
			password = a[len("--pass="):]
		case a == "--team":
			team, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--team="):
			team = a[len("--team="):]
		case a == "--url":
			url, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--url="):
			url = a[len("--url="):]
		default:
			return "", "", "", "", fmt.Errorf("unexpected argument %q (usage: bp signup --email <addr> [--team <name>] [--password <pw>] [--url <url>])", a)
		}
		if err != nil {
			return "", "", "", "", err
		}
	}
	return email, password, team, url, nil
}

// parseProviderAddArgs splits `bp provider add <kind> --token <t> [--label <l>]`:
// the first positional is the kind, then the flags.
func parseProviderAddArgs(args []string) (kind, token, label string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--token":
			token, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--token="):
			token = a[len("--token="):]
		case a == "--label":
			label, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--label="):
			label = a[len("--label="):]
		case strings.HasPrefix(a, "-"):
			return "", "", "", fmt.Errorf("unknown flag %q (usage: bp provider add hetzner --token <token> [--label <label>])", a)
		default:
			if kind != "" {
				return "", "", "", fmt.Errorf("unexpected extra argument %q", a)
			}
			kind = a
		}
		if err != nil {
			return "", "", "", err
		}
	}
	return kind, token, label, nil
}

// parseLaunchArgs splits `bp launch <provider> --name <name>`: the first
// positional is the provider, then the --name flag.
func parseLaunchArgs(args []string) (provider, name string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--name":
			name, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--name="):
			name = a[len("--name="):]
		case strings.HasPrefix(a, "-"):
			return "", "", fmt.Errorf("unknown flag %q (usage: bp launch hetzner --name <name>)", a)
		default:
			if provider != "" {
				return "", "", fmt.Errorf("unexpected extra argument %q", a)
			}
			provider = a
		}
		if err != nil {
			return "", "", err
		}
	}
	return provider, name, nil
}

// parseGoLiveArgs splits `bp go-live --name <name> [--plan <plan>]`. No
// positionals — everything is a flag.
func parseGoLiveArgs(args []string) (name, plan string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--name":
			name, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--name="):
			name = a[len("--name="):]
		case a == "--plan":
			plan, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--plan="):
			plan = a[len("--plan="):]
		default:
			return "", "", fmt.Errorf("unexpected argument %q (usage: bp go-live --name <name> [--plan pro])", a)
		}
		if err != nil {
			return "", "", err
		}
	}
	return name, plan, nil
}

// nextFlagValue reads the value for a space-separated flag at args[i], returning
// the value and the advanced index. A missing value (flag is the last token) is
// an error naming the flag. (cloud_cmd.go-style hand parsing; named distinctly
// from migrate_cmd.go's inline-aware flagValue, which has a different signature.)
func nextFlagValue(args []string, i int) (string, int, error) {
	if i+1 >= len(args) {
		return "", i, fmt.Errorf("%s needs a value", args[i])
	}
	return args[i+1], i + 1, nil
}

// --- help text ---------------------------------------------------------------

func printLoginHelp(out *writer) {
	const help = `bp login — authenticate to Barkpark Cloud (the control plane).

USAGE
  bp login [--email <addr>] [--password <pw>] [--url <url>]

WHAT IT DOES
  exchanges your email + password for a session token via the control plane and
  stores it (0600) so 'bp barkparks', 'bp launch', and 'bp go-live' work. The
  email/password are prompted when omitted; the password is never echoed and can
  also come from the BARKPARK_PASSWORD env var.

FLAGS
  --email <addr>    your account email (prompted when omitted)
  --password <pw>   your password (prompted, not echoed; or BARKPARK_PASSWORD)
  --url <url>       control-plane URL (default https://api.barkpark.cloud)
  -o json           emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

func printSignupHelp(out *writer) {
	const help = `bp signup — create a Barkpark Cloud account (and log in).

USAGE
  bp signup --email <addr> [--team <name>] [--password <pw>] [--url <url>]

WHAT IT DOES
  registers a new account on the control plane — it creates your user, a team, an
  owner membership, and a session token, then stores the token (0600) so you are
  logged in immediately (just like 'bp login'). The team name defaults to a slug
  derived from your email when --team is omitted. The password is prompted twice
  (not echoed) and must match; it can also come from --password or the
  BARKPARK_PASSWORD env var. An already-registered email points you at 'bp login'.

FLAGS
  --email <addr>    your account email (required; prompted when omitted)
  --team <name>     your team's name (optional; defaults from the email)
  --password <pw>   your password (prompted twice, not echoed; or BARKPARK_PASSWORD)
  --url <url>       control-plane URL (default https://api.barkpark.cloud)
  -o json           emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

func printProviderHelp(out *writer) {
	const help = `bp provider — connect a cloud account to provision Barkparks into.

USAGE
  bp provider add hetzner --token <token> [--label <label>]

WHAT IT DOES
  links a cloud provider (today: hetzner) to your team on the control plane so
  'bp launch <kind>' can provision a Barkpark into it. The token is encrypted at
  rest by the control plane and never echoed back. Requires 'bp login' first.

FLAGS
  --token <token>   the provider API token
  --label <label>   a human label for the connection (optional)
  -o json           emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

func printLaunchHelp(out *writer) {
	const help = `bp launch — provision a Barkpark into a connected provider.

USAGE
  bp launch hetzner --name <name>

WHAT IT DOES
  asks the control plane to provision a new Barkpark into your connected provider
  of that kind. Provisioning runs server-side; the command returns the new row
  (health "unknown" until the agent phones home). Requires 'bp login' first and a
  connected provider ('bp provider add').

FLAGS
  --name <name>   the new Barkpark's name (required)
  -o json         emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

func printGoLiveHelp(out *writer) {
	const help = `bp go-live — provision a fully-managed Barkpark (zero-config).

USAGE
  bp go-live --name <name> [--plan pro]

WHAT IT DOES
  asks the control plane to stand up a fully-managed Barkpark — no bring-your-own
  provider needed. Provisioning runs server-side; the command returns the new row.
  Requires 'bp login' first.

FLAGS
  --name <name>   the new Barkpark's name (required)
  --plan <plan>   the billing plan to provision under (optional, e.g. pro)
  -o json         emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}
