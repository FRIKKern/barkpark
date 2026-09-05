package cli

// token_create_cmd.go — `bp token create <label> --permissions read [--dataset d]`.
//
// THE HOLE THIS CLOSES. The `read` token tier is the one credential that reads a
// PRIVATE schema inside its own workspace: token_controller's mintable allowlist
// is `~w(public-read read)`, and PublicRead.public_read_token?/1 is a membership
// test on the literal string "public-read", so a ["read"] token no-ops out of the
// public clamp entirely and QueryController.authed?/1 treats it as authenticated.
// The authorization layer was never the problem. NOTHING MINTED ONE.
//
// The manifest already declares `token.create` with a `--permissions` flag whose
// help reads "Comma list — public-read|read ONLY (default public-read)". That flag
// never reaches the wire as a list. commandFlagBelongsInBody (run.go) admits a
// flag into the JSON body only for a BATCH write (or the two cycle.open
// exceptions), and token.create is neither — so `--permissions` falls through to
// applyQuery and goes out as the query string `?permissions=read`, a SCALAR.
// Phoenix merges it into params as the binary "read", token_controller's
// fetch_permissions/1 only accepts `is_list(perms)`, and the request 422s with
// `permissions [:invalid] not allowed`. Drop the flag and the server defaults to
// ["public-read"]. Either way a customer cannot ask for `read` — which is exactly
// the "no surface mints a workspace-bound read token" finding, confirmed at the
// MINTING layer while the authorization layer was already correct.
//
// WHY A BUILT-IN AND NOT A MANIFEST FIX. Both honest repairs to the manifest path
// live in api/lib — either declaring the flag list-typed (capabilities.ex) or
// teaching the server to accept a comma string (token_controller.ex) — and a
// generic "split every comma flag into an array" in buildBody would change the
// wire shape of every other command that has one. So this verb is registered in
// nounBuiltins GATED on --permissions: a bare `bp token create <label>` still
// rides the untouched manifest path and mints public-read exactly as before, and
// only a caller who STATES a permission set takes this path, where the body is
// built as JSON and `permissions` is an ARRAY.
//
// THE RECEIPT IS READ BACK, NOT ECHOED. Every field printed below comes out of the
// 201 body — the server's `permissions`, its `workspace`, its generated `id` — not
// out of the request. A mint that silently landed public-read, or landed in the
// Default workspace instead of the stated one, has to SAY so here. The 2xx is
// screened through screenBuiltinWriteReceipt (the one writeReceiptVerdict) first,
// so an empty 200 or a proxy page cannot render as a minted token.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// tokenCreateUsage is the one usage line the help block and every arg refusal
// share, so the two can never describe different syntax.
const tokenCreateUsage = "bp [-w <workspace>] [-p <project>] token create <label> --permissions read|public-read[,…] [--dataset <dataset>]"

// tokenCreateArgs is the parsed command line. dataset defaults to the resolved
// context's dataset rather than a literal, so `bp -d staging token create …`
// binds the token to staging without the caller repeating himself.
type tokenCreateArgs struct {
	label       string
	permissions []string
	dataset     string
}

// runTokenCreate handles `bp token create <label> --permissions …`.
func runTokenCreate(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTokenCreateHelp(out)
		return exitOK
	}

	args, err := parseTokenCreateArgs(tail, ctx.Dataset)
	if err != nil {
		return usageErrf(out, func() { printTokenCreateHelp(out) }, "%v", err)
	}

	// permissions as a LIST — the whole reason this path exists.
	body, merr := json.Marshal(map[string]any{
		"label":       args.label,
		"permissions": args.permissions,
		"dataset":     args.dataset,
	})
	if merr != nil {
		return usageErrf(out, func() { printTokenCreateHelp(out) }, "could not build the mint request: %v", merr)
	}

	// ScopedURL is unconditional here: /v1/tokens exists ONLY under the
	// /w/<ws>/p/<project> mirror (router.ex — the :scoped_admin block), so a
	// stated -w always reaches the wire and there is no flat route that could
	// silently mint in Default instead.
	u := apiclient.ScopedURL(ctx.Server, ctx.Workspace, ctx.Project, "/v1/tokens")
	headers := map[string]string{"Content-Type": "application/json"}
	if ctx.Token != "" {
		headers["Authorization"] = "Bearer " + ctx.Token
	}

	status, respBody, rerr := doRequest("POST", u, headers, body)
	if rerr != nil {
		if !renderErrorEnvelope(out, "request_failed", "request failed: "+rerr.Error(), "", "") {
			out.userErr("request failed: %v", rerr)
		}
		return exitGeneric
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		renderError(out, ae)
		return ae.exit
	}
	if rc, handled := screenBuiltinWriteReceipt(out, "token create", status, respBody); handled {
		return rc
	}

	resp, perr := parseTokenMintReceipt(respBody)
	if perr != nil {
		refuseWithRemedy(out, "unreadable_write_receipt",
			fmt.Sprintf("token create: %v (HTTP %d, %d bytes): %s", perr, status, len(respBody), bodyPreview(respBody)),
			"the token may or may not have been minted — run `bp -w "+ctx.Workspace+" token ls` to see the workspace's inventory before retrying")
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
		"inserted_at": resp.InsertedAt,
	}) {
		return exitOK
	}

	// Human receipt. The token is printed ONCE — the server never returns it
	// again, only its SHA256 is persisted — and the two lines that matter for
	// the finding this verb closes (which tier landed, and in WHICH workspace)
	// are the server's own words.
	out.outf("✓ minted %s", resp.Label)
	out.outf("  permissions  %s   (as the server recorded them)", strings.Join(resp.Permissions, ","))
	out.outf("  workspace    %s   (as the server resolved it)", resp.Workspace)
	out.outf("  dataset      %s", resp.Dataset)
	out.outf("  id           %s", resp.ID)
	out.outf("  token        %s", resp.Token)
	out.outf("")
	out.outf("This token is shown ONCE. Store it now — the server keeps only its hash.")
	return exitOK
}

// tokenMintReceipt is the 201 body of POST /w/:ws/p/:p/v1/tokens.
type tokenMintReceipt struct {
	Token       string   `json:"token"`
	ID          string   `json:"id"`
	Label       string   `json:"label"`
	Permissions []string `json:"permissions"`
	Dataset     string   `json:"dataset"`
	Workspace   string   `json:"workspace"`
	InsertedAt  any      `json:"inserted_at"`
}

// parseTokenMintReceipt decodes the mint response and REFUSES any body that
// cannot carry the receipt's claims. The three required fields are each
// server-only: `token` is the product, `permissions` is the tier the receipt
// asserts, `workspace` is the binding. `{}`, `null`, `{"result":null}` and an
// HTML proxy page all fail here rather than printing an empty checkmark.
func parseTokenMintReceipt(body []byte) (tokenMintReceipt, error) {
	var r tokenMintReceipt
	if err := json.Unmarshal(body, &r); err != nil {
		return r, fmt.Errorf("the mint response is not readable JSON")
	}
	if r.Token == "" {
		return r, fmt.Errorf("the mint response carried no token")
	}
	if len(r.Permissions) == 0 {
		return r, fmt.Errorf("the mint response named no permissions, so the tier that landed is unknown")
	}
	if r.Workspace == "" {
		return r, fmt.Errorf("the mint response named no workspace, so the binding is unknown")
	}
	return r, nil
}

// parseTokenCreateArgs reads `<label> --permissions a,b [--dataset d]`, in the
// long-flag spellings bp accepts elsewhere (`--flag value` and `--flag=value`,
// single dash tolerated). defaultDataset is the resolved context's dataset.
func parseTokenCreateArgs(tail []string, defaultDataset string) (tokenCreateArgs, error) {
	out := tokenCreateArgs{dataset: defaultDataset}
	var permsSet bool

	for i := 0; i < len(tail); i++ {
		a := tail[i]
		name, inline, hasInline := splitTokenFlag(a)
		if name == "" {
			if out.label != "" {
				return out, fmt.Errorf("unexpected argument %q (usage: %s)", a, tokenCreateUsage)
			}
			out.label = a
			continue
		}
		value := inline
		if !hasInline {
			if i+1 >= len(tail) {
				return out, fmt.Errorf("--%s needs a value (usage: %s)", name, tokenCreateUsage)
			}
			i++
			value = tail[i]
		}
		switch name {
		case "permissions":
			out.permissions = splitCommaList(value)
			permsSet = true
		case "dataset":
			out.dataset = strings.TrimSpace(value)
		default:
			return out, fmt.Errorf("unknown flag --%s (usage: %s)", name, tokenCreateUsage)
		}
	}

	if strings.TrimSpace(out.label) == "" {
		return out, fmt.Errorf("a label is required (usage: %s)", tokenCreateUsage)
	}
	out.label = strings.TrimSpace(out.label)
	if !permsSet {
		// Unreachable through the gated dispatch (the built-in fires only when
		// --permissions is present) — kept so a direct caller cannot mint an
		// unstated tier through this path.
		return out, fmt.Errorf("--permissions is required on this path (usage: %s)", tokenCreateUsage)
	}
	if len(out.permissions) == 0 {
		return out, fmt.Errorf("--permissions was empty — name at least one of read, public-read (usage: %s)", tokenCreateUsage)
	}
	if strings.TrimSpace(out.dataset) == "" {
		out.dataset = "production"
	}
	return out, nil
}

// splitTokenFlag returns ("", "", false) for a positional, or (name, inlineValue,
// hasInlineValue) for `--name`, `-name`, `--name=value`.
func splitTokenFlag(a string) (string, string, bool) {
	if !strings.HasPrefix(a, "-") || a == "-" || a == "--" {
		return "", "", false
	}
	body := strings.TrimLeft(a, "-")
	if eq := strings.IndexByte(body, '='); eq >= 0 {
		return body[:eq], body[eq+1:], true
	}
	return body, "", false
}

// splitCommaList turns "read, public-read" into ["read","public-read"], dropping
// empties so a trailing comma is not a phantom permission the server 422s on.
func splitCommaList(v string) []string {
	var outv []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			outv = append(outv, p)
		}
	}
	return outv
}

// tokenCreateGated is the nounBuiltins `When` predicate: this built-in shadows the
// manifest verb ONLY when the caller states --permissions. A bare
// `bp token create <label>` is untouched and still rides the manifest path.
func tokenCreateGated(tail []string) bool {
	for _, a := range tail {
		if name, _, _ := splitTokenFlag(a); name == "permissions" {
			return true
		}
	}
	return false
}

func printTokenCreateHelp(out *writer) {
	out.errf("usage: %s", tokenCreateUsage)
	out.errf("")
	out.errf("Mint a READ-ONLY, workspace-bound API token and print it once.")
	out.errf("")
	out.errf("  public-read   reads only PUBLISHED documents of a PUBLIC schema (the default a")
	out.errf("                deployed site needs — see `bp vercel deploy`).")
	out.errf("  read          reads PRIVATE schemas too, inside THIS workspace only. This is the")
	out.errf("                tier a desk-private dataset needs, and the tier the manifest verb")
	out.errf("                cannot ask for: its --permissions rides the query string as a")
	out.errf("                scalar, which the server rejects as invalid.")
	out.errf("")
	out.errf("The token is bound to the workspace your -w resolves to (the route is")
	out.errf("POST /w/<workspace>/p/<project>/v1/tokens, admin-gated on your membership ROLE)")
	out.errf("and the receipt prints the permissions and workspace the SERVER recorded, not the")
	out.errf("ones you asked for.")
	out.errf("")
	out.errf("examples:")
	out.errf("  bp -w gyldendal token create desk-reader --permissions read")
	out.errf("  bp -w acme token create site --permissions public-read --dataset staging")
}
