package cli

// instance_studio_token_cmd.go — `bp instance studio-token --workspace <ws>`
// (task-7855ed1481992cf6).
//
// A Studio needs BARKPARK_TOKEN: a read token with a member seat in its
// workspace (barkpark-studio docs/DEPLOY.md). The scoped token mint needs an
// API token with an admin seat, and an owner who signs in with SSO has only a
// login session. This verb calls POST /v1/auth/studio-tokens, which accepts a
// workspace owner's or admin's login session as well as the instance admin
// token, and prints the new token once as the line the Studio's .env needs.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const instanceStudioTokenUsage = "bp instance studio-token --workspace <ws> [--dataset <d>] [--label <l>]"

type instanceStudioTokenArgs struct {
	workspace, dataset, label string
}

func parseInstanceStudioTokenArgs(args []string, defaultWorkspace string) (instanceStudioTokenArgs, error) {
	a := instanceStudioTokenArgs{workspace: strings.TrimSpace(defaultWorkspace)}
	for i := 0; i < len(args); i++ {
		name, inline, hasInline := splitTokenFlag(args[i])
		if name == "" {
			return a, fmt.Errorf("unexpected argument %q (usage: %s)", args[i], instanceStudioTokenUsage)
		}
		value := inline
		if !hasInline {
			if i+1 >= len(args) {
				return a, fmt.Errorf("--%s needs a value (usage: %s)", name, instanceStudioTokenUsage)
			}
			i++
			value = args[i]
		}
		value = strings.TrimSpace(value)
		switch name {
		case "workspace":
			a.workspace = value
		case "dataset":
			a.dataset = value
		case "label":
			a.label = value
		default:
			return a, fmt.Errorf("unknown flag --%s (usage: %s)", name, instanceStudioTokenUsage)
		}
	}
	if a.workspace == "" {
		return a, fmt.Errorf("name the Studio's workspace with --workspace <ws> (usage: %s)", instanceStudioTokenUsage)
	}
	return a, nil
}

func runInstanceStudioToken(out *writer, g globals, args []string) int {
	ctx := resolveContext(g)
	// Only a stated -w counts; the resolved default must not pick the
	// Studio's workspace silently.
	ctx.Workspace = strings.TrimSpace(g.workspace)
	return studioTokenMint(out, ctx, args)
}

func studioTokenMint(out *writer, ctx manifest.Context, args []string) int {
	a, err := parseInstanceStudioTokenArgs(args, ctx.Workspace)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if ctx.Token == "" {
		return useError(out, "auth", "no credential for "+ctx.Server+": sign in as an owner or admin of "+a.workspace+
			" or pass the admin token with --token. Nothing was minted", exitAuth)
	}

	payload := map[string]string{"workspace": a.workspace}
	if a.dataset != "" {
		payload["dataset"] = a.dataset
	}
	if a.label != "" {
		payload["label"] = a.label
	}
	body, _ := json.Marshal(payload)

	u := strings.TrimRight(ctx.Server, "/") + "/v1/auth/studio-tokens"
	headers := map[string]string{
		"Content-Type":  "application/json",
		"Authorization": "Bearer " + ctx.Token,
	}
	status, respBody, rerr := doRequest("POST", u, headers, body)
	if rerr != nil {
		return useError(out, "failed", "request to "+ctx.Server+" failed: "+rerr.Error()+". Nothing was minted", exitGeneric)
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		renderError(out, ae)
		return ae.exit
	}
	if rc, handled := screenBuiltinWriteReceipt(out, "instance studio-token", status, respBody); handled {
		return rc
	}
	resp, perr := parseTokenMintReceipt(respBody)
	if perr != nil {
		refuseWithRemedy(out, "unreadable_write_receipt",
			fmt.Sprintf("instance studio-token: %v (HTTP %d, %d bytes)", perr, status, len(respBody)),
			"the token may or may not have been minted. Run `bp -w "+a.workspace+" token ls` before retrying")
		return exitGeneric
	}

	if out.emitStructured(map[string]any{
		"ok":          true,
		"token":       resp.Token,
		"id":          resp.ID,
		"label":       resp.Label,
		"permissions": resp.Permissions,
		"dataset":     resp.Dataset,
		"workspace":   resp.Workspace,
		"expires_at":  resp.ExpiresAt,
	}) {
		return exitOK
	}

	out.outf("BARKPARK_TOKEN=%s", resp.Token)
	out.errf("Minted %q (id %s): %s, member seat in workspace %s, dataset %s.",
		resp.Label, resp.ID, strings.Join(resp.Permissions, ","), resp.Workspace, resp.Dataset)
	out.errf("Put the line above in the Studio's .env. It is shown once; the server keeps only its hash.")
	out.errf("Revoke it with `bp -w %s token revoke %s`.", resp.Workspace, resp.ID)
	return exitOK
}
