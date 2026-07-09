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
	ListBarkparks(ctx context.Context) ([]cloudclient.Barkpark, error)
	GetCredentials(ctx context.Context, id string) (cloudclient.Credentials, error)
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
// INTEGRATION POINT: bp-login-ux-w1-cli-device-login lands the copy-a-link browser
// device flow in internal/cli/login_device.go (runDeviceLoginFlow). This is the
// single call site to swap onto it — assign `cloudSetupDeviceLogin =
// runDeviceLoginFlow` (or wrap it) once that merges. Until then it reuses the
// control plane's existing email+password login, which the charter keeps as the
// permanent headless/CI fallback anyway — so the wizard's cloud target is a
// complete, tested path today. It is a var precisely so the swap is one line and
// tests can stub it.
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
// (LoggedInOnly — exit 0, never a dead end). Otherwise it prints a numbered list,
// reads the pick from in, fetches that Barkpark's admin credentials, and returns
// them as the connect target. A no_admin_token 404 offers a manual token paste or
// a logged-in-only finish. The admin token is never printed.
func cloudFleetPick(out *writer, client cloudFleetClient, in io.Reader) (setup.CloudLoginResult, error) {
	list, err := client.ListBarkparks(cloudCtx())
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
	out.outf("")
	out.outf("Your Barkparks:")
	for i, b := range list {
		out.outf("  %d) %s  %s", i+1, b.Name, fleetTarget(b.URL, b.Host))
	}

	idx, ok := promptFleetChoice(out, reader, len(list))
	if !ok {
		// No valid selection (blank line / EOF / out of range): stay logged in
		// rather than dead-end or loop.
		out.outf("No Barkpark selected — you stay logged in. Re-run 'bp setup' to connect.")
		return setup.CloudLoginResult{LoggedInOnly: true}, nil
	}
	picked := list[idx]

	creds, gerr := client.GetCredentials(cloudCtx(), picked.ID)
	if gerr != nil {
		if strings.Contains(gerr.Error(), "no_admin_token") {
			return cloudNoAdminToken(out, reader, picked)
		}
		return setup.CloudLoginResult{}, fmt.Errorf("get credentials for %q: %w", picked.Name, gerr)
	}

	target := fleetTarget(creds.URL, creds.Host)
	if target == "" {
		return setup.CloudLoginResult{}, fmt.Errorf("%q has no URL to connect to yet (still provisioning?)", picked.Name)
	}
	// The admin token is saved as the server token (charter-accepted posture) and
	// never printed here.
	return setup.CloudLoginResult{Server: target, Token: creds.AdminToken, Name: picked.Name}, nil
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
	if target == "" {
		return setup.CloudLoginResult{}, fmt.Errorf("%q has no URL to connect to yet (still provisioning?)", picked.Name)
	}
	return setup.CloudLoginResult{Server: target, Token: token, Name: picked.Name}, nil
}

// fleetTarget prefers a Barkpark's URL, falling back to its host (a box still
// provisioning may have only a host). Returns "" when both are blank.
func fleetTarget(url, host string) string {
	if strings.TrimSpace(url) != "" {
		return url
	}
	return strings.TrimSpace(host)
}
