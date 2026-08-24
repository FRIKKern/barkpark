package cli

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
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

// ExitOpenDesk is a SENTINEL "exit code" a login-connect path returns from
// cli.Execute to ask main() to open the TUI desk IN-PROCESS instead of exiting.
// It is never a real process status: main.go intercepts it before os.Exit and
// launches runTUI against the just-saved server (see cmd/barkpark/main.go). The
// value sits well outside the real 0–8 exit scheme AND the 0–255 range a shell
// can read, so it can never be mistaken for a genuine status — if it ever leaked
// to os.Exit that is a wiring bug, not a valid code.
const ExitOpenDesk = 256

// offerOpenDesk is the tail of a SUCCESSFUL auto-connect: the user is signed in
// AND a real content server was just saved, so we offer to drop them straight
// into the working desk rather than leave them at a hint. On a bare Enter it
// returns the ExitOpenDesk sentinel main() reads to launch the TUI in-process;
// declining (typing n / no) returns exitOK with a one-line reminder so the
// prompt is never a trap.
//
// The offer appears ONLY on the interactive human path — a real TTY and a
// non-machine output shape. On -o json/yaml (the report branch), a pipe, or any
// non-tty it is a SILENT no-op returning exitOK, so the {ok,…} envelope and
// headless/CI callers are untouched (charter decision 12: no chrome, no prompts
// on the machine path). The caller must only invoke it when auto-connect
// actually ran. The read is cooked-mode Fscanln — the same terminal-safe read
// the wizard→desk fall-through already relies on.
func offerOpenDesk(out *writer) int {
	if !out.isTTY || out.machineOut() {
		return exitOK
	}
	fmt.Fprint(out.stderr, "Press Enter to open the desk (or type n to stay here): ")
	var line string
	// Fscanln returns an error on a bare Enter (no token scanned) — that empty
	// line IS the default "yes, open it". Only an explicit n / no declines; any
	// other input is treated as assent, since the prompt asked for Enter.
	_, _ = fmt.Fscanln(os.Stdin, &line)
	line = strings.TrimSpace(line)
	if line == "n" || line == "N" || strings.EqualFold(line, "no") {
		out.outf("Run 'bp' any time to open the desk.")
		return exitOK
	}
	return ExitOpenDesk
}

// LoggedInWithoutServer reports the "signed in to Barkpark Cloud but no barkpark
// connected" state: a Cloud session token is stored, yet no active CONTENT
// server is resolvable (no BARKPARK_* server env, no saved active server). In
// that state the TUI falls to the baked localhost floor, fails to load schemas,
// and — because saving the Cloud token makes FirstRun() false — would otherwise
// print the misleading "Is the Phoenix API running?" hint. main() consults this
// to print setup guidance instead. Exported and side-effect-free (a pure read of
// env + on-disk config) so it is unit-testable.
func LoggedInWithoutServer() bool {
	// axi-b4: EVERY server name the resolver honours, from the shared list. A
	// name missing here makes this answer true for a user who DID configure a
	// server, and the TUI then prints setup guidance for a box it is connected to.
	if anyEnvSet(ServerEnvNames...) {
		return false
	}
	c, err := LoadConfig()
	if err != nil || c == nil {
		return false
	}
	return c.HasCloudToken() && strings.TrimSpace(c.Server) == ""
}

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

	email, password, url, device, deviceStart, devicePollCode, perr := parseLoginArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	devicePollCode = strings.TrimSpace(devicePollCode)
	if deviceStart && devicePollCode != "" {
		return useError(out, "usage", "pass EITHER --device-start OR --device-poll <code>, not both", exitUsage)
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

	// Non-interactive device-login steps (BP-ONB-13): split the blocking browser
	// login into two script-drivable one-shots BEFORE the interactive branch, so a
	// headless / agent wrapper owns the poll cadence itself. --device-start mints
	// the code pair and exits; --device-poll <code> does exactly ONE poll and
	// exits (no 15-min loop). Both emit a single JSON envelope; neither blocks and
	// neither auto-registers a fleet (that is the human-TTY tail below).
	if deviceStart {
		return runDeviceStartStep(out, base)
	}
	if devicePollCode != "" {
		return runDevicePollStep(out, cfg, base, devicePollCode)
	}

	// Copy-a-link browser login (charter decision 10): the friendly default when
	// the user gave no credential and there is a human at a terminal to approve in
	// a browser — or when forced with --device. Every other combination (any
	// credential input, a piped/CI run) falls through to the password path
	// VERBATIM below, so `bp login --email x` and BARKPARK_PASSWORD are unchanged.
	if deviceRequested(device, email, password) {
		if derr := runDeviceLoginFlow(out, cfg, base, deviceClientName()); derr != nil {
			if asDeviceAuthError(derr) {
				return useError(out, "auth", derr.Error(), exitAuth)
			}
			return useError(out, "failed", derr.Error(), exitGeneric)
		}
		// AUTO-REGISTER (bp-login-ux W2): resolve the fleet and, on a single
		// barkpark, connect bp to it — landing the user in a working surface, not
		// at a hint. runDeviceLoginFlow already emitted the {ok,cloud_url,team_id}
		// envelope, so there is NO json early-return here to lean on;
		// finishLoginConnect gates itself strictly to the human TTY path. Its
		// return is exitOK — or the ExitOpenDesk sentinel when the user accepted
		// the "Press Enter to open the desk" offer (decision 23).
		return finishLoginConnect(out, cfg)
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
		// Headless / -o json: the envelope is byte-identical to before — NO
		// auto-connect side effects on the machine path.
		return exitOK
	}

	out.outf("✓ logged in to %s", base)
	if resp.TeamID != "" {
		out.outf("  team: %s", resp.TeamID)
	}
	// AUTO-REGISTER (bp-login-ux W2): replaces the former dead-end
	// "run 'bp barkparks'" hint — resolve the fleet and connect on a single
	// barkpark (gated to the human TTY path inside finishLoginConnect). Returns
	// exitOK, or the ExitOpenDesk sentinel on an accepted desk offer.
	return finishLoginConnect(out, cfg)
}

// finishLoginConnect is the shared AUTO-REGISTER tail both `bp login` paths run
// after the session is stored (bp-login-ux W2): it resolves the logged-in user's
// fleet and, when there is exactly ONE barkpark (the overwhelmingly common case),
// fetches its admin credentials and connects bp to it — landing the user in a
// working surface instead of at a "run bp barkparks" hint.
//
// It is gated STRICTLY to the human terminal path (out.isTTY && !out.machineOut()):
//   - the headless / -o json contract is frozen — the {ok,cloud_url,team_id}
//     envelope is byte-identical and NO auto-connect side effect fires. The device
//     branch calls this AFTER runDeviceLoginFlow already emitted its envelope, so
//     the gate here (not a json early-return) is what protects the machine path.
//
// Every outcome is a complete, non-dead-end success — it returns exitOK on every
// path except one: a successful single-barkpark auto-connect on a both-streams
// terminal ends with the "Press Enter to open the desk" offer, whose acceptance
// returns the ExitOpenDesk sentinel (decision 23; main() turns it into runTUI).
// A fleet error after a good login is a stderr warning. Zero barkparks →
// launch/deploy guidance. One → auto-connect + announce (with a steal-guard,
// below). Many → an interactive pick when both streams are a TTY, else the fleet
// printed with a one-line connect command.
func finishLoginConnect(out *writer, cfg *Config) int {
	// A human terminal only. Never auto-connect on the headless / machine path.
	if !out.isTTY || out.machineOut() {
		return exitOK
	}

	client := cfg.CloudClient()
	list, err := client.ListAllBarkparks(cloudCtx())
	if err != nil {
		// Logged in IS success; a fleet lookup blip is a warning, not a failure.
		out.errf("logged in, but couldn't reach your fleet (%v) — try `bp barkparks`.", err)
		return exitOK
	}

	switch len(list) {
	case 0:
		out.outf("")
		out.outf("You're logged in — you don't have any Barkparks yet.")
		out.outf("  launch one:    bp launch hetzner --name <name>")
		out.outf("  fully-managed: bp go-live --name <name>")
		return exitOK
	case 1:
		return finishSingleBarkpark(out, client, list[0])
	default:
		return finishMultiBarkpark(out, client, list)
	}
}

// finishSingleBarkpark auto-connects the one-barkpark fleet: it fetches the
// barkpark's admin credentials and delegates to the unchanged connect path, then
// announces "Connected to <name> — <url>" before the connect summary.
//
// STEAL-GUARD (decision 17): if bp is already pointed at a DIFFERENT active saved
// server, we do NOT silently re-point it — we report the barkpark and how to
// connect, leaving the active server untouched (exit 0). When the active server IS
// this barkpark, it's a reconnect: we fall through and re-save with a FRESH admin
// token (GetCredentials always mints/returns the current one).
func finishSingleBarkpark(out *writer, client cloudFleetClient, only cloudclient.Barkpark) int {
	target := fleetTarget(only.URL, only.Host)
	if only.Team != nil && strings.EqualFold(strings.TrimSpace(only.Team.Role), "member") {
		out.outf("")
		out.outf("You're logged in. %q belongs to %s, where your member role cannot retrieve its admin token.", only.Name, fleetTeamName(only))
		out.outf("Ask a team owner or admin for access, or connect with your own token:  bp setup --target cloud")
		return exitOK
	}

	if active, ok := activeSavedServer(); ok && strings.TrimSpace(active.Server) != "" {
		if normalizeServerURL(active.Server) != normalizeServerURL(target) {
			out.outf("")
			out.outf("You're logged in. Your Barkpark: %s  %s", only.Name, orDash(target))
			out.outf("bp is currently connected to %s — leaving that as is.", active.Server)
			out.outf("Connect to %s any time with:  bp setup --target cloud", only.Name)
			return exitOK
		}
		// Same server → a reconnect: fall through to fetch a fresh token + re-save.
	}

	creds, gerr := client.GetCredentialsForTeam(cloudCtx(), only.ID, fleetTeamID(only))
	if gerr != nil {
		if strings.Contains(gerr.Error(), "no_admin_token") {
			// No stored admin token (an older / ip-only provision): fall back to the
			// manual-paste path — never a dead end.
			out.outf("")
			out.outf("%q has no stored admin token (an older or ip-only provision).", only.Name)
			out.outf("Connect by pasting an admin token:  bp setup --target cloud")
			return exitOK
		}
		out.errf("logged in, but couldn't fetch credentials for %q (%v) — try `bp setup --target cloud`.", only.Name, gerr)
		return exitOK
	}

	connectTarget := fleetTarget(creds.URL, creds.Host)
	if connectTarget == "" {
		out.errf("logged in — %q has no address yet (still provisioning). Re-run `bp setup --target cloud` once it's up.", only.Name)
		return exitOK
	}

	out.outf("")
	out.outf("Connected to %s — %s", only.Name, connectTarget)
	if !connectToBarkpark(out, connectTarget, creds.AdminToken, only.Name, only.ID, fleetTeamLabel(only)) {
		return exitOK
	}
	// TAKE ME FURTHER (decision 23): a successful AUTO-connect ends with the
	// Enter-to-desk offer — but only on a genuine both-streams terminal.
	// out.isTTY covers stdout alone; a piped stdin would hand offerOpenDesk an
	// immediate EOF that reads as assent and launch the desk unasked.
	out.outf("")
	if deviceTTYCheck() {
		return offerOpenDesk(out)
	}
	out.outf("  run 'bp' to open your desk")
	return exitOK
}

// finishMultiBarkpark handles a fleet with more than one barkpark. On a genuine
// both-streams terminal it reuses the wizard's cloudFleetPick (numbered list →
// pick → credentials → connect). When stdin is NOT a terminal (a rare
// `bp login < /dev/null` at a tty) it never prompts: it prints the fleet with a
// one-line connect command. Always exitOK: the Enter-to-desk offer is reserved
// for the AUTO-connect (decision 23) — after a user-driven pick the "run 'bp'"
// hint stands.
func finishMultiBarkpark(out *writer, client cloudFleetClient, list []cloudclient.Barkpark) int {
	if deviceTTYCheck() { // both stdin AND stdout are a real terminal
		res, err := cloudFleetPick(out, client, os.Stdin)
		if err != nil {
			out.errf("logged in, but couldn't pick a Barkpark (%v) — try `bp setup --target cloud`.", err)
			return exitOK
		}
		if res.LoggedInOnly || strings.TrimSpace(res.Server) == "" {
			// cloudFleetPick already printed the actionable guidance (skip / no token).
			return exitOK
		}
		out.outf("")
		out.outf("Connected to %s — %s", res.Name, res.Server)
		if connectToBarkpark(out, res.Server, res.Token, res.Name, res.InstanceID, res.Team) {
			out.outf("")
			out.outf("  run 'bp' to open your desk")
		}
		return exitOK
	}

	out.outf("")
	out.outf("You're logged in. Your Barkparks:")
	for _, b := range list {
		out.outf("  %s  %s", fleetLabel(b), orDash(fleetTarget(b.URL, b.Host)))
	}
	out.outf("")
	out.outf("Connect to one with:  bp setup --target cloud")
	return exitOK
}

// connectToBarkpark delegates to the setup connect path (TargetConnect over
// configStoreAdapter) so the server is probed, the admin token is persisted, bp is
// defaulted here, and the same premium connect summary prints — exactly like the
// wizard's cloud target. We never hand-roll RememberServer. instanceID + team are
// the control-plane identity from the fleet row already in scope (Barkpark.ID /
// Team.Name); they thread through SetupPlan → SavedConfig → ServerEntry so a
// second hostname of one instance collapses onto the existing entry (aliases)
// instead of minting a phantom "-2" (D4/D9) — the activation that made the
// wave-1 InstanceID plumbing live. A connect failure after a good login is a
// warning, not a failure (the user stays logged in) — reported as ok=false so the
// caller skips the next-step tail (hint or desk offer).
func connectToBarkpark(out *writer, server, token, name, instanceID, team string) bool {
	plan := setup.SetupPlan{
		Target:     setup.TargetConnect,
		Server:     server,
		Token:      token,
		Name:       strings.TrimSpace(name),
		InstanceID: strings.TrimSpace(instanceID),
		Team:       strings.TrimSpace(team),
	}
	opts := setup.Options{
		Out:          out.stdout,
		Store:        configStoreAdapter{},
		KnownServers: loadKnownServers(),
	}
	if err := setup.Execute(plan, opts); err != nil {
		out.errf("logged in, but connecting to %s failed: %v", server, err)
		out.errf("  you can retry with:  bp setup --target cloud")
		return false
	}
	return true
}

// orDash renders an empty string as the house em-dash so a provisioning barkpark
// with no URL/host yet reads honestly rather than as a bare gap.
func orDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return s
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
		// 409 email_taken → point the user at login; everything else (422 validation)
		// surfaces verbatim. We match on the message cloudError carried.
		msg := rerr.Error()
		if strings.Contains(msg, "email_taken") {
			return useError(out, "failed", "email already registered — run `bp login` instead", exitGeneric)
		}
		// POST-COMMIT NETWORK DROP (onb-w4): a NON-refusal error means the control
		// plane never returned an HTTP status at all — the connection dropped. That
		// drop can land AFTER the server already committed the account (register is
		// not idempotent — a blind retry 409s email_taken and forces a command
		// switch). We cannot know from here whether the write happened, so we fail
		// closed and tell the honest truth: the account MAY already exist, and the
		// recovery is `bp login` with the SAME credentials — never a bare
		// "signup failed: <transport>" that strands a possibly-created account.
		// A server refusal is a *cloudclient.CloudRefusal (it carries an HTTP
		// status); a transport error is not, which is exactly the seam we key on.
		var refusal *cloudclient.CloudRefusal
		if !errors.As(rerr, &refusal) {
			return useError(out, "failed", signupTransportRecoveryMessage(email, base, msg), exitGeneric)
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

// signupTransportRecoveryMessage builds the honest receipt for a `bp signup`
// whose POST /v1/auth/register dropped in transport (onb-w4). Because the drop
// can happen AFTER the server committed the account, the copy never claims the
// signup failed cleanly: it names the ambiguous state (the account MAY already
// exist) and advises `bp login` with the SAME credentials as the recovery — a
// blind `bp signup` retry would 409 email_taken and force a command switch. When
// the email is known it is threaded into the login hint so the user can act
// without retyping it; the underlying transport error stays appended so the
// cause is never hidden.
//
// The base URL is threaded in too, and appended as --url whenever it is NOT the
// baked default: this path never persists CloudURL, so on a FIRST signup against
// a non-default control plane a bare `bp login --email X` would resolve back to
// the default host and fail — and the copy's next clause ("if that reports
// invalid credentials, the account was not created") would then draw exactly the
// false conclusion this receipt exists to prevent.
func signupTransportRecoveryMessage(email, base, transportErr string) string {
	loginHint := "bp login"
	if e := strings.TrimSpace(email); e != "" {
		loginHint = "bp login --email " + e
	}
	if b := strings.TrimSpace(base); b != "" && b != cloudclient.DefaultBaseURL {
		loginHint += " --url " + b
	}
	return "signup could not be confirmed — the connection dropped before the " +
		"control plane replied, so your account may already have been created. " +
		"Run `" + loginHint + "` with the same password to sign in; if that reports " +
		"invalid credentials, the account was not created and you can run `bp signup` " +
		"again. (" + transportErr + ")"
}

// runLogout is the `bp logout` built-in — the sign-out sibling of `bp login`.
// It blanks the three Cloud* control-plane fields (CloudURL + CloudToken +
// CloudTeam) and persists via SaveConfig, so the on-disk config no longer
// carries a control-plane session and the authed Cloud commands fall back to
// their "run 'bp login'" path.
//
// It leaves the per-server content Token/scope and the whole KnownServers fleet
// UNTOUCHED — logout is a cloud-session action, not a config wipe — UNLESS the
// global --all flag is given, which additionally drops the ACTIVE content token
// (the remembered per-server tokens in KnownServers still stay put).
//
// Idempotent: logging out when already logged out is a clean no-op that still
// exits 0. -o json/yaml emits a receipt envelope; the human path prints a
// one-line confirmation.
func runLogout(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printLogoutHelp(out)
			return exitOK
		}
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}

	wasLoggedIn := cfg.HasCloudToken()
	prevURL := strings.TrimSpace(cfg.CloudURL)

	// Clear exactly the three Cloud* session fields.
	cfg.CloudURL = ""
	cfg.CloudToken = ""
	cfg.CloudTeam = ""

	// --all also drops the active content token (opt-in, never by default).
	tokenCleared := false
	if g.all && strings.TrimSpace(cfg.Token) != "" {
		cfg.Token = ""
		tokenCleared = true
	}

	if serr := SaveConfig(cfg); serr != nil {
		return useError(out, "failed", "save config: "+serr.Error(), exitGeneric)
	}

	if out.emitStructured(map[string]any{
		"ok":            true,
		"was_logged_in": wasLoggedIn,
		"token_cleared": tokenCleared,
	}) {
		return exitOK
	}

	switch {
	case wasLoggedIn && prevURL != "":
		out.outf("✓ logged out of %s", prevURL)
	case wasLoggedIn:
		out.outf("✓ logged out")
	default:
		out.outf("already logged out")
	}
	if tokenCleared {
		out.outf("  content token cleared")
	}
	return exitOK
}

// runBarkparksCloud is the control-plane path of `bp barkparks`: it fetches the
// AUTHORITATIVE fleet from the registry (GET /v1/barkparks, optionally with the
// explicit cross-team scope) and renders it. It is
// only reached when a CloudToken is present (runBarkparks branches to it); the
// local KnownServers view (cloud-11) is the no-token fallback.
func runBarkparksCloud(out *writer, cfg *Config, allTeams bool) int {
	client := cfg.CloudClient()
	var list []cloudclient.Barkpark
	var err error
	if allTeams {
		list, err = client.ListAllBarkparks(cloudCtx())
	} else {
		list, err = client.ListBarkparks(cloudCtx())
	}
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

	renderCloudBarkparksTable(out, list, allTeams)
	return exitOK
}

// cloudBarkparkRow projects a control-plane Barkpark onto the JSON row shape — a
// flat map so the -o json output is stable and self-describing.
func cloudBarkparkRow(b cloudclient.Barkpark) map[string]any {
	row := map[string]any{
		"id":            b.ID,
		"name":          b.Name,
		"slug":          b.Slug,
		"url":           b.URL,
		"host":          b.Host,
		"provider":      b.Provider,
		"mode":          b.Mode,
		"health_status": b.HealthStatus,
		"agent_status":  b.AgentStatus,
		"last_seen_at":  b.LastSeenAt,
		"version":       b.Version,
		"git_commit":    b.GitCommit,
		"team_id":       b.TeamID,
	}
	if b.Team != nil {
		row["team"] = map[string]any{
			"id": b.Team.ID, "name": b.Team.Name, "slug": b.Team.Slug, "role": b.Team.Role,
		}
	}
	return row
}

// renderCloudBarkparksTable prints the aligned fleet table through the ONE shared
// cloud/hetzner renderer (renderHzTable), so the neutral vocabulary finally paints
// on every row: PROVIDER (identity → GenProviderMark) + STATUS (the folded
// GenInstanceLifecycle state → its role hue), alongside NAME · URL · MODE ·
// HEALTH · AGENT (Decision 34 activates the merged-but-dormant #1739 chrome on the
// registry leg) — plus LAST-SEEN, the age of the control plane's last observation
// rendered through relativeAge(b.LastSeenAt) (a never-seen row → hzCell's em-dash).
// renderHzTable measures widths on bare strings and only tints when
// out.color is on, so color-off output stays byte-stable. URL falls back to the
// host when the server has no URL yet (still provisioning). Every cell rides
// through hzCell like every other renderHzTable call site: control chars from a
// server-supplied value are stripped (never echoed raw to the terminal) and an
// empty PROVIDER or STATUS cell (a pre-migration or unplaceable row) renders the
// house em-dash rather than a bare gap — the tinters key on exact vocabulary
// values, so a dashed cell stays honestly unpainted.
func renderCloudBarkparksTable(out *writer, list []cloudclient.Barkpark, showTeam bool) {
	headers := []string{"NAME", "PROVIDER", "URL", "STATUS", "MODE", "HEALTH", "AGENT", "LAST-SEEN"}
	if showTeam {
		headers = append([]string{"TEAM"}, headers...)
	}
	rows := make([][]string, 0, len(list))
	for _, b := range list {
		u := b.URL
		if u == "" {
			u = b.Host
		}
		row := []string{
			hzCell(b.Name), hzCell(b.Provider), hzCell(u), hzCell(registryLifecycleToken(b)),
			hzCell(b.Mode), hzCell(b.HealthStatus), hzCell(b.AgentStatus),
			hzCell(relativeAge(b.LastSeenAt)),
		}
		if showTeam {
			team := ""
			if b.Team != nil {
				team = b.Team.Name
			}
			row = append([]string{hzCell(team)}, row...)
		}
		rows = append(rows, row)
	}
	renderHzTable(out, headers, rows)
}

// runProvider is the `bp provider <verb>` built-in. Verbs:
//
//	bp provider add hetzner --token <t> [--label <l>]   connect a cloud account
//	bp provider remove <kind>                           disconnect it (→ standalone)
//
// `add` connects a cloud account to the control plane (POST /v1/providers) so a
// later `bp launch` can provision into it; `remove` drops it (DELETE
// /v1/providers/:kind) — the plugin law: disconnecting degrades to standalone.
// Requires a Cloud token.
func runProvider(out *writer, args []string) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		printProviderHelp(out)
		if len(args) == 0 {
			return exitUsage
		}
		return exitOK
	}

	verb := args[0]
	switch verb {
	case "add":
		return runProviderAdd(out, args[1:])
	case "remove":
		return runProviderRemove(out, args[1:])
	default:
		out.userErr("unknown provider command %q", verb)
		out.errf("usage: bp provider <add|remove> <kind> …")
		return exitUsage
	}
}

// runProviderAdd connects a cloud account: bp provider add <kind> --token <t>
// [--label <l>] (POST /v1/providers). The token is verified server-side before
// it is encrypted at rest, and never echoed back.
func runProviderAdd(out *writer, args []string) int {
	kind, token, label, perr := parseProviderAddArgs(args)
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

// runProviderRemove disconnects a cloud account: bp provider remove <kind>
// (DELETE /v1/providers/:kind). Drops the team's connection of that kind — the
// plugin law: with the provider gone, the box degrades gracefully to standalone.
// A 404 (nothing connected of that kind — no existence leak) surfaces verbatim.
func runProviderRemove(out *writer, args []string) int {
	var kind string
	for _, a := range args {
		switch {
		case a == "-h" || a == "--help":
			printProviderHelp(out)
			return exitOK
		case strings.HasPrefix(a, "-"):
			return useError(out, "usage", fmt.Sprintf("unknown flag %q (usage: bp provider remove <kind>)", a), exitUsage)
		default:
			if kind != "" {
				return useError(out, "usage", fmt.Sprintf("unexpected extra argument %q", a), exitUsage)
			}
			kind = a
		}
	}
	if kind == "" {
		return useError(out, "usage", "missing provider kind — e.g. bp provider remove cloudflare", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	if err := cfg.CloudClient().DisconnectProvider(cloudCtx(), kind); err != nil {
		return cloudFail(out, "disconnect provider", err)
	}

	if out.emitStructured(map[string]any{"ok": true, "kind": kind}) {
		return exitOK
	}

	out.outf("✓ disconnected %s provider", kind)
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
	flagDevice  = "--device"
	flagTeam    = "--team"
	flagEmailEq = flagEmail + "="
	flagUserEq  = flagUser + "="
	flagPwEq    = flagPasswd + "="
	flagPassEq  = flagPass + "="
	flagURLEq   = flagURL + "="
	flagTeamEq  = flagTeam + "="

	// Non-interactive device-login steps (BP-ONB-13): --device-start (bare bool)
	// mints the code pair and exits; --device-poll <code> performs one poll and
	// exits. They split the blocking browser login so a headless/agent wrapper
	// owns the poll cadence.
	flagDeviceStart  = "--device-start"
	flagDevicePoll   = "--device-poll"
	flagDevicePollEq = flagDevicePoll + "="
)

// loginKnownFlags / signupKnownFlags list every bare flag token each parser
// recognizes. nextFlagValue's guard checks a would-be value against this list
// so `bp login --password --device-start` errors instead of silently binding
// the password to the literal "--device-start" and leaving --device-start's
// own bool false with no error.
var loginKnownFlags = []string{flagEmail, flagUser, flagPasswd, flagPass, flagURL, flagDevice, flagDeviceStart, flagDevicePoll}
var signupKnownFlags = []string{flagEmail, flagUser, flagPasswd, flagPass, flagTeam, flagURL}

// parseLoginArgs splits `bp login` flags: --email/--user, --password/--pass,
// --url, the bare boolean --device (force the browser device-link flow), and the
// two non-interactive device-login steps --device-start (bare bool) and
// --device-poll <device_code> (BP-ONB-13). Each value-flag accepts both
// `--flag value` and `--flag=value`. Any positional or unknown flag is a usage error.
func parseLoginArgs(args []string) (email, password, url string, device, deviceStart bool, devicePoll string, err error) {
	fail := func(e error) (string, string, string, bool, bool, string, error) {
		return "", "", "", false, false, "", e
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == flagEmail || a == flagUser:
			email, i, err = nextFlagValue(args, i, loginKnownFlags...)
		case strings.HasPrefix(a, flagEmailEq):
			email = a[len(flagEmailEq):]
		case strings.HasPrefix(a, flagUserEq):
			email = a[len(flagUserEq):]
		case a == flagPasswd || a == flagPass:
			password, i, err = nextFlagValue(args, i, loginKnownFlags...)
		case strings.HasPrefix(a, flagPwEq):
			password = a[len(flagPwEq):]
		case strings.HasPrefix(a, flagPassEq):
			password = a[len(flagPassEq):]
		case a == flagURL:
			url, i, err = nextFlagValue(args, i, loginKnownFlags...)
		case strings.HasPrefix(a, flagURLEq):
			url = a[len(flagURLEq):]
		case a == flagDeviceStart:
			// Bare boolean — the non-interactive first leg: mint a code pair and
			// exit without polling.
			deviceStart = true
		case a == flagDevicePoll:
			devicePoll, i, err = nextFlagValue(args, i, loginKnownFlags...)
		case strings.HasPrefix(a, flagDevicePollEq):
			devicePoll = a[len(flagDevicePollEq):]
		case a == flagDevice:
			// Bare boolean — no value consumed. Forces the browser device-link
			// flow even when a credential or non-tty would otherwise route to the
			// password path. Matched AFTER the --device-* flags so it never shadows
			// them (exact-equality cases, so order is belt-and-braces).
			device = true
		default:
			return fail(fmt.Errorf("unexpected argument %q (usage: bp login [--email <addr>] [--password <pw>] [--device] [--device-start] [--device-poll <code>] [--url <url>])", a))
		}
		if err != nil {
			return fail(err)
		}
	}
	return email, password, url, device, deviceStart, devicePoll, nil
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
			email, i, err = nextFlagValue(args, i, signupKnownFlags...)
		case strings.HasPrefix(a, flagEmailEq):
			email = a[len(flagEmailEq):]
		case strings.HasPrefix(a, flagUserEq):
			email = a[len(flagUserEq):]
		case a == flagPasswd || a == flagPass:
			password, i, err = nextFlagValue(args, i, signupKnownFlags...)
		case strings.HasPrefix(a, flagPwEq):
			password = a[len(flagPwEq):]
		case strings.HasPrefix(a, flagPassEq):
			password = a[len(flagPassEq):]
		case a == flagTeam:
			team, i, err = nextFlagValue(args, i, signupKnownFlags...)
		case strings.HasPrefix(a, flagTeamEq):
			team = a[len(flagTeamEq):]
		case a == flagURL:
			url, i, err = nextFlagValue(args, i, signupKnownFlags...)
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
//
// known lists the flag tokens the caller's parser recognizes (e.g.
// loginKnownFlags). If the next token starts with "-" AND is one of those known
// flags, it is refused as a value with the same "needs a value" error — this
// stops a bare value-flag from silently swallowing the following flag (e.g.
// `--password --device-start` binding the password to the literal
// "--device-start"). Callers that pass no known flags (or values that merely
// start with "-" but aren't in the list, e.g. a password of "-secret") are
// unaffected — the value still passes through unchanged.
func nextFlagValue(args []string, i int, known ...string) (string, int, error) {
	if i+1 >= len(args) {
		return "", i, fmt.Errorf("%s needs a value", args[i])
	}
	next := args[i+1]
	if strings.HasPrefix(next, "-") {
		for _, k := range known {
			if next == k {
				return "", i, fmt.Errorf("%s needs a value", args[i])
			}
		}
	}
	return next, i + 1, nil
}

// --- help text ---------------------------------------------------------------

func printLoginHelp(out *writer) {
	const help = `bp login — authenticate to Barkpark Cloud (the control plane).

USAGE
  bp login [--email <addr>] [--password <pw>] [--device] [--url <url>]
  bp login --device-start -o json           # mint a code pair, exit (no polling)
  bp login --device-poll <device_code> -o json   # ONE poll, exit (script owns cadence)

WHAT IT DOES
  On a terminal with no credentials given, opens a copy-a-link BROWSER login: it
  prints a short verification URL + code (and tries to open your browser), you
  approve in your barkpark.cloud session, and the token lands here — no password
  typed. Pass any credential (--email/--password or BARKPARK_PASSWORD) and it
  falls back to email + password, prompting for whatever you omit (password never
  echoed) — the path headless/CI use. Either way the session token is stored
  (0600) so 'bp barkparks', 'bp launch', and 'bp go-live' work.

  For headless / agent wrappers, --device-start and --device-poll split the
  browser flow into two non-interactive steps: --device-start emits the code pair
  as JSON and exits; --device-poll <code> does exactly ONE poll and exits, so a
  script drives the cadence itself — e.g.
      resp=$(bp login --device-start -o json); code=$(jq -r .device_code <<<"$resp")
      until bp login --device-poll "$code" -o json; do sleep 5; done
  --device-poll exits 0 ONLY on approval; a non-zero exit (with a {status:…}
  envelope) means keep polling.

FLAGS
  --device            force the browser device-link flow (even with a credential)
  --device-start      mint a device code pair as JSON and exit (no polling)
  --device-poll <c>   perform ONE device poll for code <c> and exit
  --email <addr>      your account email (prompted when omitted) — password path
  --password <pw>     your password (prompted, not echoed; or BARKPARK_PASSWORD)
  --url <url>         control-plane URL (default https://api.barkpark.cloud)
  -o json             emit one machine-readable JSON object on stdout`
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

func printLogoutHelp(out *writer) {
	const help = `bp logout — clear your Barkpark Cloud session (the control plane).

USAGE
  bp logout [--all]

WHAT IT DOES
  removes the stored control-plane session (cloud url + token + team) from your
  config, so 'bp barkparks', 'bp launch', and 'bp go-live' stop using it and ask
  you to 'bp login' again. Your saved content servers and their tokens are left
  intact. Idempotent — logging out when already logged out is a clean no-op.

FLAGS
  --all             also clear the ACTIVE content-server token
  -o json           emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

func printProviderHelp(out *writer) {
	const help = `bp provider — connect a cloud account to provision Barkparks into.

USAGE
  bp provider add <kind> --token <token> [--label <label>]
  bp provider remove <kind>

WHAT IT DOES
  links a cloud provider (hetzner / azure to provision into; cloudflare for free
  edge DNS/TLS/CDN) to your team on the control plane. The token is verified, then
  encrypted at rest by the control plane and never echoed back. 'remove'
  disconnects it — the box degrades gracefully back to standalone. Requires
  'bp login' first.

FLAGS
  --token <token>   the provider API token (add only)
  --label <label>   a human label for the connection (optional, add only)
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
	var id, teamArg string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--team":
			// `--team <slug|id>` — read credentials in an explicit team context
			// rather than the active team (cfg.CloudTeam). Needs a value.
			if i+1 >= len(args) {
				return useError(out, "usage", "--team needs a value (a team slug or id — see 'bp teams')", exitUsage)
			}
			teamArg = args[i+1]
			i++
		case strings.HasPrefix(a, "--team="):
			teamArg = strings.TrimPrefix(a, "--team=")
		case a == "":
			continue
		case strings.HasPrefix(a, "-"):
			continue
		default:
			if id == "" {
				id = a
			}
		}
	}
	if id == "" {
		return useError(out, "usage", "bp instance credentials <id> [--team <slug|id>] — the instance id (see 'bp barkparks')", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	// Team context resolution: an explicit --team (slug or UUID) wins, else the
	// active team persisted by `bp team use` (cfg.CloudTeam). A slug is resolved
	// to its UUID against the caller's membership list (GET /v1/me) because the
	// control plane's get_team/1 is UUID-only — a slug can't be resolved
	// server-side. An empty context is the plain, primary-team behaviour.
	//
	// CAVEAT (auth model): the X-Barkpark-Team header this sends is honoured only
	// for SESSION-token auth — the `bp login` device flow mints a session token,
	// so this switch works there. A personal access token (PAT) is hard-bound to
	// its own pat.team_id server-side (auth.ex require_user_or_pat) and IGNORES
	// the header, so `--team` has no effect under a PAT: use `bp login` for
	// cross-team credential reads.
	teamID := strings.TrimSpace(cfg.CloudTeam)
	if t := strings.TrimSpace(teamArg); t != "" {
		me, merr := cfg.CloudClient().Me(cloudCtx())
		if merr != nil {
			return cloudFail(out, "resolve team", merr)
		}
		match, found := resolveTeam(me.Teams, t)
		if !found {
			msg := fmt.Sprintf("not a member of team %q", t)
			if names := teamHandles(me.Teams); names != "" {
				msg += " — you can use: " + names
			}
			return useError(out, "failed", msg, exitGeneric)
		}
		teamID = match.ID
	}

	creds, err := cfg.CloudClient().GetCredentialsForTeam(cloudCtx(), id, teamID)
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
  bp instance credentials <id> [--team <slug|id>]

WHAT IT DOES
  credentials  retrieve the per-instance ADMIN TOKEN the platform minted on the
               box at provision time, decrypted for you (the owner). Use it to
               administer the instance (content, ingest) without SSH. Only an
               owner/admin of the owning team can read it. The <id> is the
               instance id from 'bp barkparks' (-o json shows 'id').

FLAGS
  --team <t>   read credentials in an explicit team context (a team slug or id
               from 'bp teams'); defaults to your active team ('bp team use').
               An instance owned by a non-active team 404s without this. Honoured
               for session-token auth ('bp login'); a PAT ignores it.
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
