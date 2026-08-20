package cli

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// This file is the CLI half of the setup wizard's Barkpark Cloud target. The
// setup package deliberately never imports cloudclient (it would create an import
// cycle and couple the pure engine to the control-plane client); instead it calls
// a setup.CloudLoginFunc hook. cloudLoginHook is that hook — the ONE place the
// wizard's cloud path touches the control plane:
//
//  1. log the user in to Barkpark Cloud (cloudSetupDeviceLogin),
//  2. list their fleet and let them pick a Barkpark (cloudFleetPick),
//  3. hand the picked server + admin token back to setup, which delegates to the
//     unchanged connect path so `bp doc ls` works right after.
//
// Every branch is a complete outcome: an empty fleet or a credential-less pick
// finishes LOGGED IN (exit 0) rather than dead-ending.

// cloudFleetClient is the slice of the control-plane client the cloud target
// needs. *cloudclient.Client satisfies it; a test passes a fake so the
// fleet-pick / no-admin-token branches are exercised without a network.
type cloudFleetClient interface {
	ListAllBarkparks(ctx context.Context) ([]cloudclient.Barkpark, error)
	GetCredentialsForTeam(ctx context.Context, id, teamID string) (cloudclient.Credentials, error)
}

// cloudLoginHook is injected into setup.Options.CloudLogin by the setup built-in.
// It logs in, then resolves a Barkpark to connect to (or a logged-in-only signal).
func cloudLoginHook(_ setup.Options) (setup.CloudLoginResult, error) {
	out := newWriter(os.Stdout, os.Stderr)
	cfg, err := cloudSetupDeviceLogin(out)
	if err != nil {
		return setup.CloudLoginResult{}, err
	}
	return cloudFleetPick(out, cfg.CloudClient(), os.Stdin)
}

// cloudSetupDeviceLogin logs the caller in to Barkpark Cloud and returns the
// logged-in config (CloudURL/CloudToken/CloudTeam persisted 0600, exactly like
// `bp login`). An existing session is reused with no re-prompt.
//
// The login itself is the SAME routine bare `bp login` runs, chosen by the same
// gating rule (charter decision 11): the copy-a-link browser device flow
// (runDeviceLoginFlow, login_device.go) whenever there is no BARKPARK_PASSWORD
// and both streams are a genuine TTY; otherwise the email+password prompt — the
// permanent headless/CI fallback. It is a var so tests can stub the whole login.
var cloudSetupDeviceLogin = func(out *writer) (*Config, error) {
	cfg, err := LoadConfig()
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	base := strings.TrimSpace(cfg.CloudURL)
	if base == "" {
		base = cloudclient.DefaultBaseURL
	}

	// Already logged in: reuse the session (no re-prompt) — the common case when a
	// user ran `bp login` before opening the wizard.
	if cfg.HasCloudToken() {
		out.outf("Using your Barkpark Cloud session (%s).", base)
		return cfg, nil
	}

	// The wizard runs on a TTY, so this is the normal path: the same boxed
	// URL + code browser approve as bare `bp login`. runDeviceLoginFlow saves the
	// config itself (0600) and prints its own success surface.
	if deviceRequested(false, "", "") {
		if derr := runDeviceLoginFlow(out, cfg, base, deviceClientName()); derr != nil {
			return nil, derr
		}
		return cfg, nil
	}

	out.outf("Log in to Barkpark Cloud (%s)", base)
	email := promptLine(out, "  email: ")
	if strings.TrimSpace(email) == "" {
		return nil, fmt.Errorf("email required to log in to Barkpark Cloud")
	}
	password := os.Getenv("BARKPARK_PASSWORD")
	if password == "" {
		password = promptPassword(out, "  password: ")
	}
	if strings.TrimSpace(password) == "" {
		return nil, fmt.Errorf("password required to log in to Barkpark Cloud")
	}

	resp, lerr := (&cloudclient.Client{BaseURL: base}).Login(cloudCtx(), email, password)
	if lerr != nil {
		return nil, fmt.Errorf("login failed: %w", lerr)
	}
	cfg.CloudURL = base
	cfg.CloudToken = resp.Token
	cfg.CloudTeam = resp.TeamID
	if serr := SaveConfig(cfg); serr != nil {
		return nil, fmt.Errorf("save config: %w", serr)
	}
	out.outf("✓ logged in to Barkpark Cloud")
	return cfg, nil
}

// cloudFleetPick lists the logged-in user's Barkparks and returns the one to
// connect bp to. An empty fleet finishes logged-in with launch/deploy guidance
// (LoggedInOnly — exit 0, never a dead end). When the fleet holds exactly ONE
// Barkpark (the overwhelmingly common case) it is auto-selected — no numbered
// pick — and the choice is announced on stderr; the connect summary itself is
// printed by the connect path that consumes the result. Two or more prints a
// numbered list, reads the pick from in, and resolves that one. The credential
// tail (no_admin_token → manual paste, still-provisioning → logged-in) is shared
// by both paths in cloudResolveTarget. The admin token is never printed.
func cloudFleetPick(out *writer, client cloudFleetClient, in io.Reader) (setup.CloudLoginResult, error) {
	list, err := client.ListAllBarkparks(cloudCtx())
	if err != nil {
		return setup.CloudLoginResult{}, fmt.Errorf("list barkparks: %w", err)
	}

	if len(list) == 0 {
		out.outf("")
		out.outf("You're logged in — but you don't have any Barkparks yet.")
		out.outf("  launch one:    bp launch hetzner --name <name>")
		out.outf("  fully-managed: bp go-live --name <name>")
		out.outf("  then re-run 'bp setup' to connect to it.")
		return setup.CloudLoginResult{LoggedInOnly: true}, nil
	}

	reader := bufio.NewReader(in)

	// Exactly one Barkpark: skip the pick entirely and auto-connect it. Announce
	// which one on stderr (the connect path prints the full premium summary), then
	// resolve its credentials through the shared tail.
	if len(list) == 1 {
		picked := list[0]
		out.errf("Only Barkpark in your fleet — connecting to %q (%s).", picked.Name, fleetTarget(picked.URL, picked.Host))
		return cloudResolveTarget(out, reader, client, picked)
	}

	out.outf("")
	out.outf("Your Barkparks:")
	for i, b := range list {
		out.outf("  %d) %s  %s", i+1, fleetLabel(b), fleetTarget(b.URL, b.Host))
	}

	idx, ok := promptFleetChoice(out, reader, len(list))
	if !ok {
		// No valid selection (blank line / EOF / out of range): stay logged in
		// rather than dead-end or loop.
		out.outf("No Barkpark selected — you stay logged in. Re-run 'bp setup' to connect.")
		return setup.CloudLoginResult{LoggedInOnly: true}, nil
	}
	return cloudResolveTarget(out, reader, client, list[idx])
}

func fleetLabel(b cloudclient.Barkpark) string {
	if b.Team == nil || strings.TrimSpace(b.Team.Name) == "" {
		return b.Name
	}
	return b.Name + " · " + b.Team.Name
}

// cloudResolveTarget fetches the picked Barkpark's admin credentials and returns
// them as the connect target. It is the shared tail of both the single-Barkpark
// fast path and the numbered multi-pick. A no_admin_token 404 diverts to the
// manual-paste path; a Barkpark that has no address yet (still provisioning)
// finishes logged-in rather than erroring — every branch is a complete outcome,
// never a dead end. The admin token is saved as the server token (charter-accepted
// posture) and is never printed here.
func cloudResolveTarget(out *writer, reader *bufio.Reader, client cloudFleetClient, picked cloudclient.Barkpark) (setup.CloudLoginResult, error) {
	if picked.Team != nil && strings.EqualFold(strings.TrimSpace(picked.Team.Role), "member") {
		out.outf("")
		out.outf("%q belongs to %s, where your member role cannot retrieve its admin token.", picked.Name, fleetTeamName(picked))
		out.outf("You stay logged in. Ask a team owner or admin for access, or connect with your own token.")
		return setup.CloudLoginResult{LoggedInOnly: true}, nil
	}

	creds, gerr := client.GetCredentialsForTeam(cloudCtx(), picked.ID, fleetTeamID(picked))
	if gerr != nil {
		if strings.Contains(gerr.Error(), "no_admin_token") {
			return cloudNoAdminToken(out, reader, picked)
		}
		return setup.CloudLoginResult{}, fmt.Errorf("get credentials for %q: %w", picked.Name, gerr)
	}

	target := fleetTarget(creds.URL, creds.Host)
	if target == "" {
		return cloudStillProvisioning(out, picked), nil
	}
	return setup.CloudLoginResult{
		Server:     target,
		Token:      creds.AdminToken,
		Name:       picked.Name,
		InstanceID: strings.TrimSpace(picked.ID),
		Team:       fleetTeamLabel(picked),
	}, nil
}

func fleetTeamID(b cloudclient.Barkpark) string {
	if b.Team == nil {
		return ""
	}
	return strings.TrimSpace(b.Team.ID)
}

func fleetTeamName(b cloudclient.Barkpark) string {
	if b.Team == nil || strings.TrimSpace(b.Team.Name) == "" {
		return "that team"
	}
	return b.Team.Name
}

// fleetTeamLabel is the IDENTITY form of the owning team's name — the raw name,
// or "" when unknown. Distinct from fleetTeamName, which returns the prose "that
// team" fallback for sentences. This is what lands on ServerEntry.Team, so a
// missing team stays empty rather than storing the prose placeholder.
func fleetTeamLabel(b cloudclient.Barkpark) string {
	if b.Team == nil {
		return ""
	}
	return strings.TrimSpace(b.Team.Name)
}

// cloudStillProvisioning is the not-a-dead-end outcome when a Barkpark has no URL
// or host yet — it is still coming up. The user stays logged in; re-running setup
// once the box is reachable will connect. LoggedInOnly ⇒ exit 0.
func cloudStillProvisioning(out *writer, picked cloudclient.Barkpark) setup.CloudLoginResult {
	out.outf("")
	out.outf("%q has no address yet — it's still provisioning.", picked.Name)
	out.outf("You stay logged in. Re-run 'bp setup' once it's up to connect.")
	return setup.CloudLoginResult{LoggedInOnly: true}
}

// promptFleetChoice reads a 1-based fleet selection from reader and returns the
// 0-based index. ok is false on a blank line, EOF, a non-number, or an
// out-of-range value so the caller finishes logged-in instead of looping.
func promptFleetChoice(out *writer, reader *bufio.Reader, n int) (int, bool) {
	fmt.Fprintf(out.stderr, "Pick a Barkpark [1-%d] (blank to skip): ", n)
	line, _ := reader.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return 0, false
	}
	num, err := strconv.Atoi(line)
	if err != nil || num < 1 || num > n {
		return 0, false
	}
	return num - 1, true
}

// cloudNoAdminToken handles GetCredentials' 404 no_admin_token: the picked
// Barkpark never had an admin token captured (an older or ip-only provision). It
// explains, then offers a manual token paste (feeds the same connect) or a
// logged-in-only finish — never a dead end.
func cloudNoAdminToken(out *writer, reader *bufio.Reader, picked cloudclient.Barkpark) (setup.CloudLoginResult, error) {
	target := fleetTarget(picked.URL, picked.Host)
	if target == "" {
		// No address to connect to even if the user pasted a token — the box is
		// still provisioning. Finish logged-in rather than prompt for a token that
		// can't be used yet.
		return cloudStillProvisioning(out, picked), nil
	}
	out.outf("")
	out.outf("%q has no stored admin token (an older or ip-only provision).", picked.Name)
	out.outf("Paste an admin token to connect now, or press Enter to stay logged in.")
	fmt.Fprint(out.stderr, "  admin token (blank to skip): ")
	line, _ := reader.ReadString('\n')
	token := strings.TrimSpace(line)
	if token == "" {
		out.outf("No token entered — you stay logged in. Re-run 'bp setup' any time.")
		return setup.CloudLoginResult{LoggedInOnly: true}, nil
	}
	return setup.CloudLoginResult{Server: target, Token: token, Name: picked.Name}, nil
}

// fleetTarget resolves a Barkpark's connectable address, preferring its full URL
// and falling back to its host (a box may have only a host early on). The result
// ALWAYS carries an http(s) scheme — a scheme-less host is promoted to
// https://<host> — so the connect path and normalizeServerURL upsert-equality
// (the W2 steal-guard) always compare a canonical scheme+host URL, never a bare
// authority. Returns "" when both url and host are blank.
func fleetTarget(url, host string) string {
	raw := strings.TrimSpace(url)
	if raw == "" {
		raw = strings.TrimSpace(host)
	}
	if raw == "" {
		return ""
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	return raw
}
