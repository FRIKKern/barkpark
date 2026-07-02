package cli

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/mattn/go-runewidth"
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

// cloudFail maps a cloud-client error onto the CLI's exit contract. cloudclient
// prefixes every 401 with "unauthorized:" precisely so callers can read the auth
// failure — an expired/revoked CloudToken exits exitAuth with a `bp login` hint,
// matching requireCloud's absent-token path (a dead session and a missing one are
// the same condition to a script). Everything else stays the generic failure it
// always was.
func cloudFail(out *writer, what string, err error) int {
	if strings.Contains(err.Error(), "unauthorized") {
		return useError(out, "auth", what+": "+err.Error()+" — session expired? run `bp login` again", exitAuth)
	}
	return useError(out, "failed", what+": "+err.Error(), exitGeneric)
}

// runLoginCloud is the `bp login` built-in — it REPLACES the v1 token-stub. It
// reads an email (--email/--user flag or prompt) and a password (--password flag,
// BARKPARK_PASSWORD env, or a non-echoed prompt), authenticates against the
// control plane, and stores CloudToken + CloudURL (+ team) in config 0600.
//
// --url overrides the control-plane URL (default https://api.barkpark.cloud) and
// is persisted so subsequent Cloud commands hit the same plane. When no control
// plane is reachable / configured the error is surfaced verbatim.
func runLoginCloud(out *writer, args []string) int {
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

	if out.emitStructured(map[string]any{
		"ok":        true,
		"cloud_url": base,
		"team_id":   resp.TeamID,
	}) {
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

	if out.emitStructured(map[string]any{
		"ok":        true,
		"cloud_url": base,
		"team_id":   resp.TeamID,
	}) {
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
		return cloudFail(out, "list barkparks", err)
	}

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(list))
		for _, b := range list {
			rows = append(rows, cloudBarkparkRow(b))
		}
		out.emitStructured(map[string]any{
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
	// Widths are measured in terminal display cells (runewidth), not bytes: a
	// multibyte name or URL is fewer cells than bytes, so a byte width would shear
	// the alignment. FillRight pads to that same cell width. Matches renderHzTable.
	nameW, urlW, modeW, healthW := runewidth.StringWidth(hName), runewidth.StringWidth(hURL), runewidth.StringWidth(hMode), runewidth.StringWidth(hHealth)
	display := make([]string, len(list))
	for i, b := range list {
		u := b.URL
		if u == "" {
			u = b.Host
		}
		display[i] = u
		if n := runewidth.StringWidth(b.Name); n > nameW {
			nameW = n
		}
		if n := runewidth.StringWidth(u); n > urlW {
			urlW = n
		}
		if n := runewidth.StringWidth(b.Mode); n > modeW {
			modeW = n
		}
		if n := runewidth.StringWidth(b.HealthStatus); n > healthW {
			healthW = n
		}
	}

	out.outf("%s", strings.Join([]string{
		runewidth.FillRight(hName, nameW), runewidth.FillRight(hURL, urlW),
		runewidth.FillRight(hMode, modeW), runewidth.FillRight(hHealth, healthW), hAgent,
	}, "  "))
	for i, b := range list {
		out.outf("%s", strings.Join([]string{
			runewidth.FillRight(b.Name, nameW), runewidth.FillRight(display[i], urlW),
			runewidth.FillRight(b.Mode, modeW), runewidth.FillRight(b.HealthStatus, healthW), b.AgentStatus,
		}, "  "))
	}
}

// runProvider is the `bp provider <verb>` built-in. Today the only verb is `add`:
//
//	bp provider add hetzner --token <t> [--label <l>]
//
// It connects a cloud account to the control plane (POST /v1/providers) so a
// later `bp launch` can provision into it. Requires a Cloud token.
func runProvider(out *writer, args []string) int {
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
		return cloudFail(out, "connect provider", err)
	}

	if out.emitStructured(map[string]any{
		"ok": true,
		"provider": map[string]any{
			"id":      prov.ID,
			"kind":    prov.Kind,
			"label":   prov.Label,
			"team_id": prov.TeamID,
		},
	}) {
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
		if code, msg, ok := noSubscriptionError(err); ok {
			return useError(out, "failed", msg, code)
		}
		return cloudFail(out, "launch", err)
	}

	if out.emitStructured(map[string]any{"ok": true, "barkpark": cloudBarkparkRow(bp)}) {
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
		return useError(out, "usage", "--name required — bp go-live --name <name> [--plan supporter]", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	bp, err := cfg.CloudClient().GoLive(cloudCtx(), name, plan)
	if err != nil {
		if code, msg, ok := noSubscriptionError(err); ok {
			return useError(out, "failed", msg, code)
		}
		return cloudFail(out, "go-live", err)
	}

	if out.emitStructured(map[string]any{"ok": true, "barkpark": cloudBarkparkRow(bp)}) {
		return exitOK
	}
	renderProvisioned(out, "going live", bp)
	return exitOK
}

// billingPlans is the closed set of subscription tiers the CLI validates --plan
// against BEFORE any network call. It mirrors the control plane's @plans
// (billing/subscription.ex). "free" is included so it parses, but subscribe
// rejects it locally: the free tier needs no checkout (the server also 422s
// "plan_invalid" for it — the local guard just fails faster and friendlier).
var billingPlans = []string{"free", "supporter", "support_plus"}

// validBillingPlan reports whether plan is one of the known tiers.
func validBillingPlan(plan string) bool {
	for _, p := range billingPlans {
		if p == plan {
			return true
		}
	}
	return false
}

// runSubscribe is the `bp subscribe --plan <tier> [--url]` built-in — it starts
// a subscription checkout for the authed user's team (POST /v1/billing/checkout)
// and prints the hosted checkout URL the customer opens in a browser to add a
// card and activate the plan. The team is resolved SERVER-SIDE from the session
// token; the client never sends a team. Requires `bp login` first.
//
// --plan is required and validated against the known tiers BEFORE the
// network call, so an unknown tier (or the no-checkout "free" tier) fails fast
// with a usage error and never reaches the server. The server's own 422
// "plan_invalid" is surfaced verbatim as a backstop. --url is accepted for
// symmetry with the other commands (and to open the URL is left to the user).
func runSubscribe(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printSubscribeHelp(out)
			return exitOK
		}
	}

	plan, perr := parseSubscribeArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if plan == "" {
		return useError(out, "usage", "--plan required — bp subscribe --plan <supporter|support_plus>", exitUsage)
	}
	// Validate the tier locally so a typo (or the no-checkout "free" tier) fails
	// before any network call. "free" parses as a known tier but has no checkout.
	if !validBillingPlan(plan) || plan == "free" {
		return useError(out, "usage",
			fmt.Sprintf("plan_invalid: %q is not a subscribable tier — choose one of supporter, support_plus", plan),
			exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	resp, err := cfg.CloudClient().CreateCheckout(cloudCtx(), plan)
	if err != nil {
		// The server's 422 plan_invalid is a usage problem (the client guard above
		// should normally catch it first); everything else surfaces verbatim.
		if strings.Contains(err.Error(), "plan_invalid") {
			return useError(out, "usage", "plan_invalid: "+plan+" is not a subscribable tier", exitUsage)
		}
		return cloudFail(out, "subscribe", err)
	}

	if out.emitStructured(map[string]any{
		"ok":           true,
		"plan":         plan,
		"checkout_url": resp.CheckoutURL,
	}) {
		return exitOK
	}

	out.outf("Subscribe at: %s", resp.CheckoutURL)
	out.outf("Open it in your browser to add a card and activate your %s subscription.", plan)
	return exitOK
}

// noSubscriptionError detects the control plane's 402 no_active_subscription
// gate (returned by /v1/launch and /v1/go-live when the team has no live
// subscription) inside a cloudclient error and maps it to an honest, actionable
// message pointing the user at `bp subscribe`. The second return is the exit
// code; the third reports whether the error was the subscription gate (so the
// caller falls through to its generic error otherwise). cloudError carries the
// server's {"error":"no_active_subscription"} message verbatim, so a substring
// match is the contract-faithful detection.
func noSubscriptionError(err error) (int, string, bool) {
	if err != nil && strings.Contains(err.Error(), "no_active_subscription") {
		return exitGeneric, "no active subscription — run `bp subscribe --plan <tier>` first", true
	}
	return 0, "", false
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

// Flag string constants shared by parseLoginArgs / parseSignupArgs. Holding
// them up here keeps the assignment lines below clean (no inline string
// literals) and stops conservative source-scanners from misreading a flag
// parser as a credential assignment.
const (
	flagEmail   = "--email"
	flagUser    = "--user"
	flagPasswd  = "--password"
	flagPass    = "--pass"
	flagURL     = "--url"
	flagTeam    = "--team"
	flagEmailEq = flagEmail + "="
	flagUserEq  = flagUser + "="
	flagPwEq    = flagPasswd + "="
	flagPassEq  = flagPass + "="
	flagURLEq   = flagURL + "="
	flagTeamEq  = flagTeam + "="
)

// parseLoginArgs splits `bp login` flags: --email/--user, --password/--pass, --url.
// Each accepts both `--flag value` and `--flag=value`. Any positional or unknown
// flag is a usage error.
func parseLoginArgs(args []string) (email, password, url string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == flagEmail || a == flagUser:
			email, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, flagEmailEq):
			email = a[len(flagEmailEq):]
		case strings.HasPrefix(a, flagUserEq):
			email = a[len(flagUserEq):]
		case a == flagPasswd || a == flagPass:
			password, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, flagPwEq):
			password = a[len(flagPwEq):]
		case strings.HasPrefix(a, flagPassEq):
			password = a[len(flagPassEq):]
		case a == flagURL:
			url, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, flagURLEq):
			url = a[len(flagURLEq):]
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
		case a == flagEmail || a == flagUser:
			email, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, flagEmailEq):
			email = a[len(flagEmailEq):]
		case strings.HasPrefix(a, flagUserEq):
			email = a[len(flagUserEq):]
		case a == flagPasswd || a == flagPass:
			password, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, flagPwEq):
			password = a[len(flagPwEq):]
		case strings.HasPrefix(a, flagPassEq):
			password = a[len(flagPassEq):]
		case a == flagTeam:
			team, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, flagTeamEq):
			team = a[len(flagTeamEq):]
		case a == flagURL:
			url, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, flagURLEq):
			url = a[len(flagURLEq):]
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
			return "", "", fmt.Errorf("unexpected argument %q (usage: bp go-live --name <name> [--plan supporter])", a)
		}
		if err != nil {
			return "", "", err
		}
	}
	return name, plan, nil
}

// parseSubscribeArgs splits `bp subscribe --plan <tier> [--url]`. --plan is the
// only value-flag; --url is accepted as a bare boolean (it asks the command to
// surface the URL prominently — which it always does — and exists for symmetry
// with the other Cloud commands). Any positional or unknown flag is a usage
// error. The tier itself is validated by the caller, not here.
func parseSubscribeArgs(args []string) (plan string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--plan":
			plan, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--plan="):
			plan = a[len("--plan="):]
		case a == "--url":
			// Bare boolean — the URL is always printed; --url is accepted for
			// symmetry and to make "show me the URL" explicit. No value consumed.
		default:
			return "", fmt.Errorf("unexpected argument %q (usage: bp subscribe --plan <supporter|support_plus> [--url])", a)
		}
		if err != nil {
			return "", err
		}
	}
	return plan, nil
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
  bp go-live --name <name> [--plan supporter]

WHAT IT DOES
  asks the control plane to stand up a fully-managed Barkpark — no bring-your-own
  provider needed. Provisioning runs server-side; the command returns the new row.
  Requires 'bp login' first.

FLAGS
  --name <name>   the new Barkpark's name (required)
  --plan <plan>   the billing plan to provision under (optional, e.g. supporter)
  -o json         emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

// runInstance is the `bp instance <verb> …` built-in. Today the only verb is
// `credentials`:
//
//	bp instance credentials <id>
//
// It retrieves the per-instance ADMIN TOKEN the warm-pool minted on the box
// (instance-admin-token) from the control plane (GET /v1/barkparks/:id/credentials)
// and prints it with a store-it-safely note — eliminating the SSH/rescue-reboot
// dance just to administer your own instance. The route is team-admin-gated and
// team-scoped, so only an owner/admin of the owning team can read it. Requires
// `bp login`.
func runInstance(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printInstanceHelp(out)
			return exitOK
		}
	}

	if len(args) == 0 {
		return useError(out, "usage", "bp instance credentials <id>", exitUsage)
	}

	switch args[0] {
	case "credentials", "creds":
		return runInstanceCredentials(out, args[1:])
	default:
		return useError(out, "usage", fmt.Sprintf("unknown instance verb %q — try: bp instance credentials <id>", args[0]), exitUsage)
	}
}

// runInstanceCredentials fetches + prints one instance's stored admin token. The
// <id> is the instance id shown by `bp barkparks` (-o json carries `id`). Treats
// the response as a secret: it prints once and is never written to config.
func runInstanceCredentials(out *writer, args []string) int {
	var id string
	for _, a := range args {
		if a == "" || strings.HasPrefix(a, "-") {
			continue
		}
		id = a
		break
	}
	if id == "" {
		return useError(out, "usage", "bp instance credentials <id> — the instance id (see 'bp barkparks')", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	creds, err := cfg.CloudClient().GetCredentials(cloudCtx(), id)
	if err != nil {
		// no_admin_token (404) is an expected, actionable state — surface it plainly.
		if strings.Contains(err.Error(), "no_admin_token") {
			return useError(out, "failed",
				"no admin token stored for this instance yet (captured at provision time — a pre-existing instance may need a re-provision)",
				exitGeneric)
		}
		return cloudFail(out, "instance credentials", err)
	}

	if out.emitStructured(map[string]any{
		"id":          id,
		"admin_token": creds.AdminToken,
		"url":         creds.URL,
		"host":        creds.Host,
	}) {
		return exitOK
	}

	target := creds.URL
	if target == "" {
		target = creds.Host
	}
	out.outf("Admin token for instance %s:", id)
	if target != "" {
		out.outf("  url:   %s", target)
	}
	out.outf("  token: %s", creds.AdminToken)
	out.outf("")
	out.outf("Store this safely — it grants read/write/admin on this instance. Use it as the")
	out.outf("bearer token for `bp` against this server (e.g. BARKPARK_API_TOKEN), or paste it into")
	out.outf("Studio. It is shown here on demand; treat it like a password.")
	return exitOK
}

func printInstanceHelp(out *writer) {
	const help = `bp instance — manage one of your managed Barkpark instances.

USAGE
  bp instance credentials <id>

WHAT IT DOES
  credentials  retrieve the per-instance ADMIN TOKEN the platform minted on the
               box at provision time, decrypted for you (the owner). Use it to
               administer the instance (content, ingest) without SSH. Only an
               owner/admin of the owning team can read it. The <id> is the
               instance id from 'bp barkparks' (-o json shows 'id').

FLAGS
  -o json      emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

func printSubscribeHelp(out *writer) {
	const help = `bp subscribe — start a subscription checkout for your team.

USAGE
  bp subscribe --plan <supporter|support_plus> [--url]

WHAT IT DOES
  asks the control plane to open a hosted checkout session for your team on the
  chosen plan and prints the URL. Open it in a browser to add a card and activate
  the subscription — only then can 'bp go-live' / 'bp launch' provision. The plan
  is checked client-side first; the 'free' tier has no checkout. Requires
  'bp login' first; the team is read from your session, never passed by you.

FLAGS
  --plan <plan>   the subscription tier (required: supporter, support_plus)
  --url           print the checkout URL prominently (it is always printed)
  -o json         emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}
