package cli

// instance_admin_token_cmd.go — `bp instance admin-token <instance-id>`
// (task-7d4d405e0ee4bcbf).
//
// THE HOLE THIS CLOSES. With no admin token locally, the only way back into an
// instance was the credential Barkpark Cloud stores for it — `bp login` and
// `bp instance credentials` hand that exact secret to the operator, who then
// shares it with Cloud. Rotating it (`bp token rotate`) killed Cloud's copy, and
// restoring access took root SSH and hand-written SQL.
//
// WHAT THIS DOES INSTEAD. Cloud's credential is read from
// GET /v1/barkparks/:id/credentials and used ONCE, as the bearer of a single
// POST /w/<ws>/p/<project>/v1/tokens/elevated on the instance, which mints a NEW
// admin token seated in the same workspace. Cloud's credential is never printed,
// never written to config and never rotated; only the new token goes anywhere.
//
// SINKS (docs/contracts/cli-credential-mint.md CRED-2). The new secret goes to
// exactly the sinks named: --install (this server's token in the bp config, the
// connect path `bp login` uses), --out <path> (a new 0600 file), --reveal
// (stdout). With none of them the command refuses BEFORE any request, because a
// late refusal would burn a live admin credential.

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

const instanceAdminTokenUsage = "bp [-w <workspace>] [-p <project>] instance admin-token <instance-id> [--label <l>] [--expires-in <d> | --no-expiry] (--install | --out <path> | --reveal) [--team <t>]"

type instanceAdminTokenArgs struct {
	id, team, label, outPath string
	expiresIn                time.Duration
	noExpiry, install        bool
	reveal                   bool
}

func parseInstanceAdminTokenArgs(args []string) (instanceAdminTokenArgs, error) {
	var a instanceAdminTokenArgs
	for i := 0; i < len(args); i++ {
		name, inline, hasInline := splitTokenFlag(args[i])
		if name == "" {
			if a.id != "" {
				return a, fmt.Errorf("unexpected argument %q (usage: %s)", args[i], instanceAdminTokenUsage)
			}
			a.id = strings.TrimSpace(args[i])
			continue
		}
		switch name {
		case "install", "reveal", "no-expiry":
			if hasInline && inline != "true" {
				return a, fmt.Errorf("--%s takes no value (usage: %s)", name, instanceAdminTokenUsage)
			}
			switch name {
			case "install":
				a.install = true
			case "reveal":
				a.reveal = true
			default:
				a.noExpiry = true
			}
			continue
		}
		value := inline
		if !hasInline {
			if i+1 >= len(args) {
				return a, fmt.Errorf("--%s needs a value (usage: %s)", name, instanceAdminTokenUsage)
			}
			i++
			value = args[i]
		}
		switch name {
		case "team":
			a.team = value
		case "label":
			a.label = strings.TrimSpace(value)
		case "out":
			a.outPath = strings.TrimSpace(value)
		case "expires-in":
			d, err := parseTokenDuration(value)
			if err != nil {
				return a, err
			}
			a.expiresIn = d
		default:
			return a, fmt.Errorf("unknown flag --%s (usage: %s)", name, instanceAdminTokenUsage)
		}
	}
	switch {
	case a.id == "":
		return a, fmt.Errorf("the instance id is required — see `bp barkparks` (usage: %s)", instanceAdminTokenUsage)
	case !a.install && a.outPath == "" && !a.reveal:
		return a, fmt.Errorf("no sink for the new admin token — pass --install (save it as this server's token in your bp config), " +
			"--out <path> (a new 0600 file) or --reveal (print it). Nothing was requested")
	case a.outPath != "" && a.reveal:
		return a, fmt.Errorf("--out and --reveal are exclusive — pick one sink for the printed copy")
	case a.noExpiry && a.expiresIn > 0:
		return a, fmt.Errorf("--expires-in and --no-expiry contradict each other — give one")
	}
	if a.label == "" {
		host, _ := os.Hostname()
		if host = strings.TrimSpace(host); host == "" {
			host = "this machine"
		}
		a.label = "bp admin-token (" + host + ")"
	}
	return a, nil
}

func runInstanceAdminToken(out *writer, g globals, args []string) int {
	a, err := parseInstanceAdminTokenArgs(args)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}

	// Claim the --out path before any request: an existing path or a missing
	// directory must not cost a live admin credential.
	var sink *os.File
	if a.outPath != "" {
		f, ferr := openCredentialSink(a.outPath)
		if ferr != nil {
			return useError(out, "usage", ferr.Error(), exitUsage)
		}
		sink = f
	}
	abandonSink := func() {
		if sink != nil {
			_ = sink.Close()
			_ = os.Remove(a.outPath)
		}
	}

	cfg, ok := requireCloud(out)
	if !ok {
		abandonSink()
		return exitAuth
	}
	creds, code, ok := fetchInstanceCredentials(out, cfg, a.id, a.team)
	if !ok {
		abandonSink()
		return code
	}
	server := fleetTarget(creds.URL, creds.Host)
	if server == "" {
		abandonSink()
		return useError(out, "failed", "the instance has no address yet (still provisioning?) — nothing was minted", exitGeneric)
	}

	// Where to mint: a stated -w/-p wins; else the workspace Cloud's credential
	// belongs to (the token's own view of itself), else "default".
	workspace, project := strings.TrimSpace(g.workspace), strings.TrimSpace(g.project)
	if workspace == "" {
		id, ierr := fetchTokenIdentity(server, creds.AdminToken)
		switch {
		case ierr == nil && id.Token.Workspace != "":
			workspace = id.Token.Workspace
		case ierr != nil && strings.Contains(ierr.Error(), "HTTP 401"):
			abandonSink()
			return useError(out, "failed",
				"the instance no longer accepts the credential Cloud stores for it (HTTP 401) — it was rotated or revoked on the box. "+
					"Cloud cannot bootstrap a new token from it; an instance operator has to restore Cloud's credential first. Nothing was minted",
				exitAuth)
		default:
			workspace = "default"
		}
	}
	if project == "" {
		project = "default"
	}
	dataset := strings.TrimSpace(g.dataset)
	if dataset == "" {
		dataset = "production"
	}

	body, _ := tokenMintBody(tokenCreateArgs{
		label:       a.label,
		permissions: []string{"read", "write", "admin"},
		dataset:     dataset,
		expiresIn:   a.expiresIn,
		noExpiry:    a.noExpiry,
	}, time.Now())

	u := apiclient.ScopedURL(server, workspace, project, "/v1/tokens/elevated")
	headers := map[string]string{
		"Content-Type":  "application/json",
		"Authorization": "Bearer " + creds.AdminToken,
	}
	status, respBody, rerr := doRequest("POST", u, headers, body)
	if rerr != nil {
		abandonSink()
		return useError(out, "failed", "mint request to "+server+" failed: "+rerr.Error()+" — nothing was minted", exitGeneric)
	}
	if status < 200 || status >= 300 {
		abandonSink()
		ae := classifyError(status, respBody)
		renderError(out, ae)
		return ae.exit
	}
	if rc, handled := screenBuiltinWriteReceipt(out, "instance admin-token", status, respBody); handled {
		abandonSink()
		return rc
	}
	minted, perr := parseTokenMintReceipt(respBody)
	if perr != nil {
		abandonSink()
		refuseWithRemedy(out, "unreadable_write_receipt",
			fmt.Sprintf("instance admin-token: %v (HTTP %d, %d bytes)", perr, status, len(respBody)),
			"the token may or may not have been minted — list the workspace's tokens with an admin token before retrying")
		return exitGeneric
	}

	written := ""
	if sink != nil {
		_, werr := sink.WriteString(minted.Token + "\n")
		_ = sink.Close()
		if werr != nil {
			return useError(out, "failed",
				fmt.Sprintf("the admin token was minted (id %s) but could not be written to %s: %s — revoke it with `bp token revoke %s` and run this again",
					minted.ID, a.outPath, werr.Error(), minted.ID),
				exitGeneric)
		}
		written = a.outPath
	}

	installed := false
	if a.install {
		if ierr := installServerToken(out, server, minted.Token, a.id, minted.Workspace, project, dataset); ierr != nil {
			return useError(out, "failed",
				fmt.Sprintf("the admin token was minted (id %s) but saving it to your bp config failed: %v", minted.ID, ierr),
				exitGeneric)
		}
		installed = true
	}

	return emitInstanceAdminToken(out, server, minted, written, installed, a.reveal)
}

// installServerToken saves token as server's credential in the bp config through
// the same connect path `bp login` uses (setup.TargetConnect over
// configStoreAdapter): the server is probed with the NEW token, then saved and
// made active, keyed by the Cloud instance id so an existing entry is updated in
// place. The connect summary redacts the token; in machine output it is dropped.
func installServerToken(out *writer, server, token, instanceID, workspace, project, dataset string) error {
	var w io.Writer = out.stdout
	if out.machineOut() {
		w = io.Discard
	}
	plan := setup.SetupPlan{
		Target:     setup.TargetConnect,
		Server:     server,
		Token:      token,
		InstanceID: strings.TrimSpace(instanceID),
		Workspace:  workspace,
		Project:    project,
		Dataset:    dataset,
	}
	return setup.Execute(plan, setup.Options{
		Out:          w,
		Store:        configStoreAdapter{},
		KnownServers: loadKnownServers(),
		RepoPin:      currentRepoPin(),
	})
}

// emitInstanceAdminToken prints the receipt. The new secret appears only with
// --reveal; Cloud's credential appears nowhere.
func emitInstanceAdminToken(out *writer, server string, m tokenMintReceipt, written string, installed, reveal bool) int {
	if out.machineOut() {
		payload := map[string]any{
			"ok":          true,
			"server":      server,
			"id":          m.ID,
			"label":       m.Label,
			"permissions": m.Permissions,
			"workspace":   m.Workspace,
			"expires_at":  m.ExpiresAt,
			"installed":   installed,
		}
		if written != "" {
			payload["written_to"] = written
		}
		if reveal {
			payload["token"] = m.Token
		}
		out.emitStructured(payload)
		return exitOK
	}

	out.outf("✓ minted a new admin token on %s", server)
	out.outf("  label        %s", sanitizeCell(m.Label))
	out.outf("  permissions  %s", strings.Join(m.Permissions, ","))
	out.outf("  workspace    %s", sanitizeCell(m.Workspace))
	out.outf("  id           %s", sanitizeCell(m.ID))
	if installed {
		out.outf("  installed    saved as this server's token in your bp config")
	}
	if written != "" {
		out.outf("  written to   %s (mode 0600)", sanitizeCell(written))
	}
	if reveal {
		out.outf("")
		out.outf("%s", m.Token)
		out.errf("warning: the token above is now in this terminal's output — anything capturing it holds a live admin credential.")
	}
	out.outf("")
	out.outf("Cloud's own credential was used only to mint this one; it was not shown, saved or rotated.")
	return exitOK
}
