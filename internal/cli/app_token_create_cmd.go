package cli

// app_token_create_cmd.go — `bp -w <workspace> app_token create <email>
// [--permissions read,write,chat] [--label <label>]`.
//
// THE BUG THIS FIXES (task-e044d53aceb0e5c8). The manifest verb could not seat
// a token anywhere but the Default workspace, and could not ask for a
// permission set. app_token_controller.ex create/2 reads `workspace` and
// `permissions` from the JSON body. The manifest path never put them there:
//
//   - `--workspace` is a GLOBAL flag. parseGlobals eats it wherever it sits, so
//     it only re-scoped the CLI's context and never reached the body. The
//     route is flat (/v1/auth/app-tokens, no scoped mirror), so the context
//     was not on the wire either. resolve_workspace/1 found no `workspace` key
//     and fell back to the Default workspace, and the 201 said so only as a
//     bare workspace_id nobody compared.
//   - `--permissions` went out as the query scalar `?permissions=read,write`,
//     because commandFlagBelongsInBody (run.go) admits a flag into the body
//     only for a batch write. fetch_permissions/1 accepts only a list, so every
//     stated set was refused with 422.
//
// token create had the same two holes and got a built-in for them
// (token_create_cmd.go). This is the same repair. The body is built here as
// JSON: email, workspace (only the one the operator typed with -w/--workspace),
// permissions as an ARRAY, dataset (only a typed -d/--dataset, because a named
// dataset binds the token) and label.
//
// THE RECEIPT IS READ BACK, AND CHECKED. The 201 names the workspace by id.
// When the operator stated a workspace, the receipt compares the two: an id
// match is immediate; a slug is resolved through GET /api/workspaces. A token
// that landed somewhere else prints its secret (it is live, and the operator
// needs it to revoke it) and then a loud warning, and the command exits 1.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const appTokenCreateUsage = "bp [-w <workspace>] [-d <dataset>] app_token create <email> [--permissions read,write,chat] [--label <label>]"

// appTokenPermissions is the server's allowlist, @app_token_permissions in
// app_token_controller.ex. Checked here too, so a wrong name is refused before
// anything is sent, with the alternative named.
var appTokenPermissions = []string{"read", "write", "chat"}

type appTokenCreateArgs struct {
	email       string
	label       string
	permissions []string // nil = not stated: the server's default set
	workspace   string   // "" = not stated: the server's Default workspace
	dataset     string   // "" = not stated: production, not bound
}

// appTokenWorkspace verdicts.
const (
	appTokenWorkspaceNotStated   = "not_stated"
	appTokenWorkspaceConfirmed   = "confirmed"
	appTokenWorkspaceMismatch    = "mismatch"
	appTokenWorkspaceUnconfirmed = "unconfirmed"
)

func runAppTokenCreate(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printAppTokenCreateHelp(out)
		return exitOK
	}

	typedDataset := ""
	if g.datasetSet {
		typedDataset = g.dataset
	}
	args, err := parseAppTokenCreateArgs(tail, strings.TrimSpace(g.workspace), typedDataset)
	if err != nil {
		return usageErrf(out, func() { printAppTokenCreateHelp(out) }, "%v", err)
	}

	body, _ := json.Marshal(appTokenMintBody(args))
	u := strings.TrimRight(ctx.Server, "/") + "/v1/auth/app-tokens"
	headers := ctxAuthHeaders(ctx)
	headers["Content-Type"] = "application/json"

	// The one write of this verb. --dry-run prints it and stops.
	const method = "POST"
	if g.dryRun {
		return dryRun(out, manifest.Command{Noun: "app_token", Verb: "create", HTTP: manifest.HTTP{Method: method}}, u, headers, body)
	}
	// The manifest verb this replaces is a write, so it asked before a prod
	// write. Keep that.
	if isProd(ctx, &manifest.Manifest{}) && !g.yes && !serverDeclaredNonProd(ctx.Server) {
		if !confirmProdWrite(out, manifest.Command{Noun: "app_token", Verb: "create"}, ctx) {
			out.errf("aborted: prod write not confirmed")
			return exitUsage
		}
	}

	status, respBody, rerr := doRequest(method, u, headers, body)
	if rerr != nil {
		return useError(out, "request_failed", "app_token create: the request failed: "+rerr.Error()+
			". The token may or may not have been minted: check with `bp app_token ls --email "+args.email+"`", exitGeneric)
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		renderError(out, ae)
		return ae.exit
	}
	if rc, handled := screenBuiltinWriteReceipt(out, "app_token create", status, respBody); handled {
		return rc
	}
	resp, perr := parseAppTokenMintReceipt(respBody)
	if perr != nil {
		refuseWithRemedy(out, "unreadable_write_receipt",
			fmt.Sprintf("app_token create: %v (HTTP %d, %d bytes): %s", perr, status, len(respBody), bodyPreview(respBody)),
			"the token may or may not have been minted. Run `bp app_token ls --email "+args.email+"` before retrying")
		return exitGeneric
	}

	verdict, slug := checkAppTokenWorkspace(ctx, args.workspace, resp.WorkspaceID)
	return renderAppTokenReceipt(out, args, resp, verdict, slug)
}

// appTokenMintBody is the JSON app_token_controller.ex create/2 reads. A key is
// present only when the operator stated it, so every default stays the
// server's.
func appTokenMintBody(args appTokenCreateArgs) map[string]any {
	body := map[string]any{"email": args.email}
	if args.workspace != "" {
		body["workspace"] = args.workspace
	}
	if args.permissions != nil {
		body["permissions"] = args.permissions
	}
	if args.dataset != "" {
		body["dataset"] = args.dataset
	}
	if args.label != "" {
		body["label"] = args.label
	}
	return body
}

// appTokenMintReceipt is the 201 body: {token, workspace_id, permissions,
// expires_at}.
type appTokenMintReceipt struct {
	Token       string   `json:"token"`
	WorkspaceID string   `json:"workspace_id"`
	Permissions []string `json:"permissions"`
	ExpiresAt   any      `json:"expires_at"`
}

// parseAppTokenMintReceipt refuses a body that cannot carry the receipt's
// claims: the secret, the permissions that landed and the workspace.
func parseAppTokenMintReceipt(body []byte) (appTokenMintReceipt, error) {
	var r appTokenMintReceipt
	if err := json.Unmarshal(body, &r); err != nil {
		return r, fmt.Errorf("the mint response is not readable JSON")
	}
	if r.Token == "" {
		return r, fmt.Errorf("the mint response carried no token")
	}
	if len(r.Permissions) == 0 {
		return r, fmt.Errorf("the mint response named no permissions, so the tier that landed is unknown")
	}
	if r.WorkspaceID == "" {
		return r, fmt.Errorf("the mint response named no workspace_id, so the workspace the token is seated in is unknown")
	}
	return r, nil
}

// checkAppTokenWorkspace compares the workspace the server seated the token in
// with the one the operator stated. It returns the verdict and the slug of the
// returned workspace when the lookup found it.
func checkAppTokenWorkspace(ctx manifest.Context, stated, returnedID string) (string, string) {
	if stated == "" {
		return appTokenWorkspaceNotStated, ""
	}
	if strings.EqualFold(stated, returnedID) {
		return appTokenWorkspaceConfirmed, ""
	}
	list, ok := fetchWorkspaceList(ctx)
	if !ok {
		return appTokenWorkspaceUnconfirmed, ""
	}
	for _, w := range list {
		if w.ID == returnedID {
			if strings.EqualFold(w.Slug, stated) {
				return appTokenWorkspaceConfirmed, w.Slug
			}
			return appTokenWorkspaceMismatch, w.Slug
		}
	}
	for _, w := range list {
		if strings.EqualFold(w.Slug, stated) || strings.EqualFold(w.ID, stated) {
			// The stated workspace resolves to another id than the one the
			// token landed in.
			return appTokenWorkspaceMismatch, ""
		}
	}
	return appTokenWorkspaceUnconfirmed, ""
}

type workspaceListEntry struct {
	ID   string `json:"id"`
	Slug string `json:"slug"`
}

// fetchWorkspaceList reads GET /api/workspaces (workspace.ls): the workspaces
// the bearer is seated in. ok=false on any failure.
func fetchWorkspaceList(ctx manifest.Context) ([]workspaceListEntry, bool) {
	u := strings.TrimRight(ctx.Server, "/") + "/api/workspaces"
	status, body, err := doRequest("GET", u, ctxAuthHeaders(ctx), nil)
	if err != nil || status != 200 {
		return nil, false
	}
	var resp struct {
		Workspaces []workspaceListEntry `json:"workspaces"`
	}
	if json.Unmarshal(body, &resp) != nil {
		return nil, false
	}
	return resp.Workspaces, true
}

func renderAppTokenReceipt(out *writer, args appTokenCreateArgs, resp appTokenMintReceipt, verdict, slug string) int {
	mismatch := verdict == appTokenWorkspaceMismatch
	warning := ""
	if mismatch {
		landed := resp.WorkspaceID
		if slug != "" {
			landed = slug + " (" + resp.WorkspaceID + ")"
		}
		warning = fmt.Sprintf("the token was seated in workspace %s, NOT in %q, the workspace you named. "+
			"It is live there. Revoke it: `bp app_token ls --email %s`, then `bp app_token revoke-by-id <id>`",
			landed, args.workspace, args.email)
	}

	payload := map[string]any{
		"ok":               !mismatch,
		"token":            resp.Token,
		"email":            args.email,
		"workspace_id":     resp.WorkspaceID,
		"workspace_check":  verdict,
		"stated_workspace": args.workspace,
		"permissions":      resp.Permissions,
		"expires_at":       resp.ExpiresAt,
	}
	if slug != "" {
		payload["workspace_slug"] = slug
	}
	if mismatch {
		payload["error"] = map[string]any{"code": "workspace_mismatch", "message": warning}
	}
	if out.emitStructured(payload) {
		if mismatch {
			out.userErr("WARNING: %s", warning)
			return exitGeneric
		}
		return exitOK
	}

	ws := resp.WorkspaceID
	if slug != "" {
		ws = slug + " (" + resp.WorkspaceID + ")"
	}
	out.outf("✓ minted an app token for %s", args.email)
	out.outf("  permissions  %s   (as the server recorded them)", strings.Join(resp.Permissions, ","))
	out.outf("  workspace    %s   (as the server resolved it)", ws)
	switch verdict {
	case appTokenWorkspaceConfirmed:
		out.outf("               matches the workspace you named")
	case appTokenWorkspaceNotStated:
		out.outf("               no -w/--workspace was given, so the server chose its Default workspace")
	case appTokenWorkspaceUnconfirmed:
		out.outf("               could not confirm this is %q: your workspace list does not name it (`bp workspace ls`)", args.workspace)
	}
	if args.dataset != "" {
		out.outf("  dataset      %s   (bound, as requested)", args.dataset)
	}
	if resp.ExpiresAt == nil {
		out.outf("  expires      never")
	} else {
		out.outf("  expires      %v", resp.ExpiresAt)
	}
	out.outf("  token        %s", resp.Token)
	out.outf("")
	out.outf("This token is shown ONCE. Store it now: the server keeps only its hash.")
	if mismatch {
		out.errf("")
		out.userErr("WARNING: %s", warning)
		return exitGeneric
	}
	return exitOK
}

// parseAppTokenCreateArgs reads `<email> [--permissions a,b] [--label l]`.
// statedWorkspace is the -w/--workspace the operator typed and typedDataset
// the -d/--dataset; parseGlobals eats both wherever they sit. A single-dash
// `-workspace`/`-dataset` passes the global parser and is read here.
func parseAppTokenCreateArgs(tail []string, statedWorkspace, typedDataset string) (appTokenCreateArgs, error) {
	out := appTokenCreateArgs{workspace: statedWorkspace, dataset: strings.TrimSpace(typedDataset)}
	for i := 0; i < len(tail); i++ {
		a := tail[i]
		name, inline, hasInline := splitTokenFlag(a)
		if name == "" {
			if out.email != "" {
				return out, fmt.Errorf("unexpected argument %q (usage: %s)", a, appTokenCreateUsage)
			}
			out.email = strings.TrimSpace(a)
			continue
		}
		value := inline
		if !hasInline {
			if i+1 >= len(tail) {
				return out, fmt.Errorf("--%s needs a value (usage: %s)", name, appTokenCreateUsage)
			}
			i++
			value = tail[i]
		}
		switch name {
		case "permissions":
			out.permissions = splitCommaList(value)
			if len(out.permissions) == 0 {
				return out, fmt.Errorf("--permissions was empty: name at least one of %s (usage: %s)",
					strings.Join(appTokenPermissions, ", "), appTokenCreateUsage)
			}
		case "label":
			out.label = strings.TrimSpace(value)
		case "email":
			if out.email != "" {
				return out, fmt.Errorf("the email was given twice (usage: %s)", appTokenCreateUsage)
			}
			out.email = strings.TrimSpace(value)
		case "workspace":
			out.workspace = strings.TrimSpace(value)
		case "dataset":
			out.dataset = strings.TrimSpace(value)
		default:
			return out, fmt.Errorf("unknown flag --%s (usage: %s)", name, appTokenCreateUsage)
		}
	}
	if out.email == "" {
		return out, fmt.Errorf("an email is required (usage: %s)", appTokenCreateUsage)
	}
	for _, p := range out.permissions {
		if !appTokenPermissionAllowed(p) {
			hint := ""
			if p == "admin" || p == "public-read" {
				hint = ". For an admin or public-read token use `bp token create <label> --permissions …`"
			}
			return out, fmt.Errorf("unknown permission %q: an app token takes only %s%s",
				p, strings.Join(appTokenPermissions, ", "), hint)
		}
	}
	return out, nil
}

func appTokenPermissionAllowed(p string) bool {
	for _, a := range appTokenPermissions {
		if p == a {
			return true
		}
	}
	return false
}

func printAppTokenCreateHelp(out *writer) {
	out.errf("usage: %s", appTokenCreateUsage)
	out.errf("")
	out.errf("Mint a member-shaped app token for a cloud account and print it once. The")
	out.errf("account gets a member seat in the workspace, and the token acts through it.")
	out.errf("The caller's token needs the admin permission.")
	out.errf("")
	out.errf("  -w <workspace>      the workspace to seat the token in (slug or id). Without it the")
	out.errf("                      server uses its Default workspace. The receipt reads the workspace")
	out.errf("                      back from the server and exits 1 with a warning when it differs.")
	out.errf("  --permissions <p>   comma list of read, write, chat (default: all three). For admin")
	out.errf("                      or public-read use `bp token create`.")
	out.errf("  -d <dataset>        bind the token to that one dataset. Without it the token is bound")
	out.errf("                      only when your own token is dataset-bound.")
	out.errf("  --label <label>     default \"app:<email>\".")
	out.errf("")
	out.errf("examples:")
	out.errf("  bp -w julegaveguide -d development app_token create ola@example.com --permissions read,write")
	out.errf("  bp -w acme app_token create kari@example.com")
}
