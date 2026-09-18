package cli

// cloud_token_cmd.go is `bp cloud token mint|ls|revoke` — the verb that ends
// "client #2 starts with a browser". Before it, the ONLY way to get the
// control-plane credential a CI job needs was the console's API-tokens panel,
// by hand, in a browser: `bp cloud token` was an unknown command (measured), and
// `bp token` mints an api/ WORKSPACE token capped at public-read/read — a
// different credential for a different service.
//
// THE NAMED DECISION it implements is docs/contracts/cli-credential-mint.md:
//
//   CRED-1  SESSION-BACKED, not a second device flow. `bp login` already runs
//           the RFC 8628 device flow and persists a cloud SESSION token; these
//           three verbs ride it. The control plane's /v1/tokens routes are
//           `Auth.require_user` — session-only on purpose, so a leaked `read`
//           PAT can never mint itself a `root` one — and that firewall is
//           preserved verbatim, never worked around.
//   CRED-2  THE PLAINTEXT IS NEVER PRINTED BY DEFAULT. `--out <path>` is the
//           default sink: a new 0600 file, never an existing one. Printing the
//           secret to stdout requires the explicit `--reveal`. With neither
//           flag the command REFUSES before it calls the control plane, so a
//           forgotten sink can never mint a live credential into scrollback.
//   CRED-3  THE ROLE CAP IS THE SERVER'S. A plain member may mint `read` only;
//           `write`/`deploy`/`root` are owner/admin (Accounts.
//           create_personal_access_token). The CLI does NOT re-implement that
//           gate (m0 rule C2: only the server knows the role) — it names the
//           plane's 403 {"error":"forbidden","required":"admin","scope":"team"}
//           as the role cap, and exits 3.
//   CRED-4  Ability and expiry VALUES are validated client-side. That is a typo
//           gate, not a role gate: an off-menu `--expires-days 45` is silently
//           rewritten to the default validity by `parse_expiry/1`, so accepting
//           it would hand back a window the caller never asked for.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// runCloudToken routes `bp cloud token <verb>`.
func runCloudToken(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudTokenHelp(out)
			return exitOK
		}
	}
	if g.help || len(args) == 0 || args[0] == "help" {
		if len(args) == 0 && !g.help {
			return useError(out, "usage", "missing token verb (run `bp cloud token -h` for usage)", exitUsage)
		}
		printCloudTokenHelp(out)
		return exitOK
	}

	switch args[0] {
	case "mint", "create":
		return runCloudTokenMint(out, args[1:])
	case "ls", "list":
		return runCloudTokenList(out, args[1:])
	case "revoke", "rm":
		return runCloudTokenRevoke(out, args[1:])
	default:
		return useError(out, "usage",
			fmt.Sprintf("unknown token verb %q (want mint · ls · revoke)", args[0]), exitUsage)
	}
}

// requireCloudSession resolves the config and refuses when there is no cloud
// credential. The three PAT routes are SESSION-ONLY, so BARKPARK_CLOUD_TOKEN
// holding a PAT will be refused by the plane with a 401 — the refusal below is
// only about having nothing at all.
func requireCloudSession(out *writer) (*Config, int) {
	cfg, cerr := LoadConfig()
	if cerr != nil {
		return nil, useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return nil, useError(out, "auth",
			"not logged in — run `bp login`, or set "+CloudTokenEnv+" for a non-interactive job. "+
				"Note that PAT management is SESSION-ONLY: "+CloudTokenEnv+" holding a PAT will be refused by the control plane (a PAT can never mint a PAT)",
			exitAuth)
	}
	return cfg, exitOK
}

// runCloudTokenMint is `bp cloud token mint --name <n> [--ability a]…
// [--expires-days N|never] (--out <path> | --reveal)`.
func runCloudTokenMint(out *writer, args []string) int {
	const usage = "bp cloud token mint --name <name> [--ability read|write|deploy|root]… [--expires-days 7|30|60|90|365|never] --out <path>"
	a, perr := parseHzArgs(args, []string{"name", "ability", "abilities", "expires-days", "out"}, []string{"reveal"}, usage)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage",
			fmt.Sprintf("unexpected argument %q — the name is a flag (usage: %s)", a.pos[0], usage), exitUsage)
	}

	name := strings.TrimSpace(a.val("name"))
	if name == "" {
		return useError(out, "usage", "--name is required (the label you will recognise this credential by in the console)", exitUsage)
	}

	abilities := append(a.list("ability"), a.list("abilities")...)
	if len(abilities) == 0 {
		abilities = []string{"read"}
	}
	if bad := unknownAbilities(abilities); len(bad) > 0 {
		return useError(out, "usage",
			fmt.Sprintf("unknown ability %s — the control plane's vocabulary is %s",
				strings.Join(quoteAll(bad), ", "), strings.Join(cloudclient.PATAbilities(), " · ")),
			exitUsage)
	}

	expires, eerr := parsePATExpiry(a.val("expires-days"))
	if eerr != nil {
		return useError(out, "usage", eerr.Error(), exitUsage)
	}

	// CRED-2, AND IT RUNS BEFORE THE NETWORK CALL. A mint with no sink would
	// create a live credential that then has nowhere to go but scrollback; the
	// secret is unrecoverable after the response, so refusing late would burn a
	// real token. This refusal happens with zero requests issued.
	outPath := strings.TrimSpace(a.val("out"))
	reveal := a.bools["reveal"]
	switch {
	case outPath == "" && !reveal:
		return useError(out, "usage",
			"no sink for the credential — pass `--out <path>` to write it to a new 0600 file, or `--reveal` to print it to stdout on purpose. "+
				"Without one of these the token would only reach your scrollback, and it is unrecoverable after this call",
			exitUsage)
	case outPath != "" && reveal:
		return useError(out, "usage", "--out and --reveal are exclusive — pick one sink for the credential", exitUsage)
	}

	// Claim the destination path BEFORE minting too: a path that already exists,
	// or a directory that does not, must not cost a live credential.
	var sink *os.File
	if outPath != "" {
		f, ferr := openCredentialSink(outPath)
		if ferr != nil {
			return useError(out, "usage", ferr.Error(), exitUsage)
		}
		sink = f
	}
	closeSink := func() {
		if sink != nil {
			_ = sink.Close()
		}
	}

	cfg, code := requireCloudSession(out)
	if cfg == nil {
		closeSink()
		if sink != nil {
			_ = os.Remove(outPath)
		}
		return code
	}

	plaintext, pat, merr := cfg.CloudClient().MintPAT(cloudCtx(), cloudclient.MintPATRequest{
		Name:          name,
		Abilities:     abilities,
		ExpiresInDays: expires,
	})
	if merr != nil {
		closeSink()
		if sink != nil {
			// Nothing was minted; do not leave an empty 0600 file that a script
			// would read as a credential.
			_ = os.Remove(outPath)
		}
		return mintFail(out, abilities, merr)
	}

	if sink != nil {
		// A trailing newline so `$(cat file)` and `read < file` both work; the
		// file is 0600 and was created exclusively.
		if _, werr := sink.WriteString(plaintext + "\n"); werr != nil {
			closeSink()
			return useError(out, "failed",
				fmt.Sprintf("the credential was minted but could not be written to %s: %s — revoke it with `bp cloud token revoke %s` and mint again",
					outPath, werr.Error(), pat.ID),
				exitGeneric)
		}
		closeSink()
	}

	return emitMintResult(out, pat, plaintext, outPath, reveal)
}

// emitMintResult prints the RECEIPT. The plaintext appears here on exactly one
// path — `--reveal` — and nowhere else: not in the table, not in the -o json
// envelope, not in a diagnostic. This function is the whole of CRED-2's print
// surface, which is what makes it testable as one place.
func emitMintResult(out *writer, pat cloudclient.PAT, plaintext, outPath string, reveal bool) int {
	if out.machineOut() {
		payload := map[string]any{
			"pat": map[string]any{
				"id":          pat.ID,
				"name":        pat.Name,
				"abilities":   pat.Abilities,
				"expires_at":  pat.ExpiresAt,
				"inserted_at": pat.InsertedAt,
			},
		}
		if outPath != "" {
			payload["written_to"] = outPath
		}
		if reveal {
			payload["token"] = plaintext
		}
		out.emitStructured(payload)
		return exitOK
	}

	out.outf("Minted %s", sanitizeCell(pat.Name))
	out.outf("  id         %s", sanitizeCell(pat.ID))
	out.outf("  abilities  %s", sanitizeCell(strings.Join(pat.Abilities, ", ")))
	out.outf("  expires    %s", patCell(pat.ExpiresAt))
	switch {
	case reveal:
		out.outf("")
		out.outf("%s", plaintext)
		out.errf("warning: the credential above is now in this terminal's output — anything capturing it (a CI log, a transcript, a scrollback buffer) holds a live token.")
	default:
		out.outf("")
		out.outf("  written to %s (mode 0600)", sanitizeCell(outPath))
		out.outf("The plaintext is shown by the server ONCE and is unrecoverable — that file is the only copy.")
	}
	return exitOK
}

// mintFail maps a refused mint. The role cap (CRED-3) is the one refusal that
// gets its own sentence, because "forbidden" alone does not tell an operator
// that a plain member is capped at `read` and an admin is not.
func mintFail(out *writer, abilities []string, err error) int {
	var ref *cloudclient.CloudRefusal
	if errors.As(err, &ref) {
		switch {
		case ref.HTTPStatus == 403 && ref.Reason == "no_team":
			return useError(out, "auth",
				"mint token: your session has no team to mint under — create or join a team first", exitAuth)
		case ref.HTTPStatus == 403:
			elevated := elevatedAbilities(abilities)
			msg := "mint token: the control plane refused this ability set"
			if len(elevated) > 0 {
				msg = fmt.Sprintf("mint token: minting %s needs an owner/admin of the team — a plain member may mint `read` only",
					strings.Join(quoteAll(elevated), ", "))
			}
			if ref.Required != "" {
				msg += fmt.Sprintf(" (the plane named required=%s scope=%s)", ref.Required, ref.Scope)
			}
			return useError(out, "auth", msg, exitAuth)
		case ref.HTTPStatus == 401:
			return useError(out, "auth",
				"mint token: the control plane refused this credential — PAT management is session-only, so run `bp login` (a PAT cannot mint a PAT)",
				exitAuth)
		case ref.HTTPStatus == 422:
			return useError(out, "usage", "mint token: "+ref.Error(), exitUsage)
		}
	}
	return cloudFail(out, "mint token", err)
}

// runCloudTokenList is `bp cloud token ls` — the inventory. No row it can print
// carries a plaintext; the server never serializes one outside the mint
// response.
func runCloudTokenList(out *writer, args []string) int {
	const usage = "bp cloud token ls"
	a, perr := parseHzArgs(args, nil, nil, usage)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}

	cfg, code := requireCloudSession(out)
	if cfg == nil {
		return code
	}

	res, lerr := cfg.CloudClient().ListPATs(cloudCtx())
	if lerr != nil {
		return cloudFail(out, "list tokens", lerr)
	}

	if out.machineOut() {
		raw, isArray := rawArrayOr(res.Raw)
		switch out.output {
		case "json":
			fmt.Fprintf(out.stdout, "{\"tokens\":%s}\n", raw)
		case "yaml":
			out.renderYAML(map[string]any{"tokens": res.PATs})
		}
		if !isArray {
			out.userErr("the control plane sent `tokens` as a JSON %s, not the array the contract specifies — the document on stdout is verbatim, but it is NOT an inventory", jsonShapeName(raw))
			return exitGeneric
		}
		return exitOK
	}

	if res.DecodeErr != nil {
		// An unreadable inventory must never be byte-identical to an empty one:
		// "(no tokens)" would read as "nothing to revoke".
		out.outf("Could not read the token inventory: %s", sanitizeCell(res.DecodeErr.Error()))
		out.outf("Re-read with '-o json' for the raw contract bytes.")
		return exitGeneric
	}
	if len(res.PATs) == 0 {
		out.outf("(no personal access tokens)")
		return exitOK
	}
	headers := []string{"ID", "NAME", "ABILITIES", "EXPIRES", "LAST USED", "STATE"}
	rows := make([][]string, 0, len(res.PATs))
	for _, p := range res.PATs {
		state := "active"
		if strings.TrimSpace(p.RevokedAt) != "" {
			state = "revoked"
		}
		rows = append(rows, []string{
			patCell(p.ID), patCell(p.Name), patCell(strings.Join(p.Abilities, ",")),
			patCell(p.ExpiresAt), patCell(p.LastUsedAt), state,
		})
	}
	renderPlainTable(out, headers, rows)
	return exitOK
}

// runCloudTokenRevoke is `bp cloud token revoke <id>` — the kill switch.
func runCloudTokenRevoke(out *writer, args []string) int {
	const usage = "bp cloud token revoke <id>"
	a, perr := parseHzArgs(args, nil, nil, usage)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one token id (usage: %s)", usage), exitUsage)
	}
	id := strings.TrimSpace(a.pos[0])
	if id == "" {
		return useError(out, "usage", fmt.Sprintf("want exactly one token id (usage: %s)", usage), exitUsage)
	}

	cfg, code := requireCloudSession(out)
	if cfg == nil {
		return code
	}
	if rerr := cfg.CloudClient().RevokePAT(cloudCtx(), id); rerr != nil {
		var ref *cloudclient.CloudRefusal
		if errors.As(rerr, &ref) && ref.HTTPStatus == 404 {
			return useError(out, "not_found",
				fmt.Sprintf("no token %q — it is not yours, or it does not exist", id), exitNotFound)
		}
		return cloudFail(out, "revoke token", rerr)
	}
	if out.machineOut() {
		out.emitStructured(map[string]any{"revoked": id})
		return exitOK
	}
	out.outf("Revoked %s — every request bearing it now fails.", sanitizeCell(id))
	return exitOK
}

// openCredentialSink creates the --out file EXCLUSIVELY at mode 0600. An
// existing path is refused rather than truncated: that file may be a live
// credential, and clobbering it would revoke nothing while destroying the only
// copy of something still in use.
func openCredentialSink(path string) (*os.File, error) {
	if dir := filepath.Dir(path); dir != "" {
		if st, err := os.Stat(dir); err != nil || !st.IsDir() {
			return nil, fmt.Errorf("--out %s: the directory %s does not exist — create it first (nothing was minted)", path, dir)
		}
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if os.IsExist(err) {
			return nil, fmt.Errorf("--out %s already exists — refusing to overwrite it (it may hold a live credential); pick a new path (nothing was minted)", path)
		}
		return nil, fmt.Errorf("--out %s: %s (nothing was minted)", path, err.Error())
	}
	return f, nil
}

// parsePATExpiry maps --expires-days onto the control plane's bounded menu.
// Empty means "omit the key" (the server's default validity); "never"/"0" means
// no expiry. Any other value is REFUSED (CRED-4) because `parse_expiry/1`
// silently rewrites an off-menu integer to the default — accepting 45 would hand
// back a window nobody asked for.
func parsePATExpiry(raw string) (*int, error) {
	s := strings.TrimSpace(strings.ToLower(raw))
	if s == "" {
		return nil, nil
	}
	if s == "never" || s == "0" {
		zero := 0
		return &zero, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return nil, fmt.Errorf("--expires-days %q is not a number — want one of %s, or `never`", raw, patExpiryMenu())
	}
	for _, ok := range cloudclient.PATExpiryChoices() {
		if n == ok {
			return &n, nil
		}
	}
	return nil, fmt.Errorf("--expires-days %d is not on the control plane's menu (%s, or `never`) — it would be silently rewritten to the default validity, so the token would not carry the window you asked for",
		n, patExpiryMenu())
}

// patExpiryMenu renders the accepted expiry values for a diagnostic.
func patExpiryMenu() string {
	parts := make([]string, 0, len(cloudclient.PATExpiryChoices()))
	for _, n := range cloudclient.PATExpiryChoices() {
		parts = append(parts, strconv.Itoa(n))
	}
	return strings.Join(parts, "/")
}

// unknownAbilities returns the requested abilities that are not in the control
// plane's vocabulary, sorted so the diagnostic is stable.
func unknownAbilities(requested []string) []string {
	known := map[string]bool{}
	for _, a := range cloudclient.PATAbilities() {
		known[a] = true
	}
	seen := map[string]bool{}
	var bad []string
	for _, a := range requested {
		k := strings.ToLower(strings.TrimSpace(a))
		if !known[k] && !seen[k] {
			seen[k] = true
			bad = append(bad, a)
		}
	}
	sort.Strings(bad)
	return bad
}

// elevatedAbilities returns the requested abilities a plain member may NOT mint
// — everything that is not `read`. Used only to NAME the server's refusal, never
// to pre-empt it.
func elevatedAbilities(requested []string) []string {
	var out []string
	for _, a := range requested {
		if strings.ToLower(strings.TrimSpace(a)) != "read" {
			out = append(out, a)
		}
	}
	return out
}

// quoteAll wraps each value in backticks for a diagnostic.
func quoteAll(vals []string) []string {
	out := make([]string, 0, len(vals))
	for _, v := range vals {
		out = append(out, "`"+sanitizeCell(v)+"`")
	}
	return out
}

// patCell dashes out an empty column value.
func patCell(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return sanitizeCell(s)
}

// printCloudTokenHelp writes `bp cloud token` usage.
func printCloudTokenHelp(out *writer) {
	const help = `bp cloud token — mint · list · revoke the control-plane credential CI needs.

USAGE
  bp cloud token mint --name <name> [--ability …]… [--expires-days N] --out <path>
  bp cloud token ls
  bp cloud token revoke <id>

WHY IT EXISTS
  A CI job authenticates to the control plane with a Personal Access Token.
  Minting one used to mean opening the console in a browser; this is the same
  mint, from the terminal, backed by the session 'bp login' already holds.

  PAT management is SESSION-ONLY by design — a PAT can never mint a PAT — so
  these verbs need 'bp login', not BARKPARK_CLOUD_TOKEN holding a PAT.

THE SECRET IS NEVER PRINTED BY DEFAULT
  --out <path>     write the plaintext to a NEW file at mode 0600 (refused if
                   the path exists — it may hold a live credential)
  --reveal         print it to stdout on purpose (anything capturing your
                   output then holds a live token)
  One of the two is REQUIRED, and the refusal happens BEFORE the mint, so a
  forgotten sink never costs a credential. The server shows the plaintext ONCE.

FLAGS (mint)
  --name <label>         required; how you will recognise it in the console
  --ability <a>          repeatable/comma-joined: read · write · deploy · root
                         (default: read; root/deploy collapse the set server-side)
  --expires-days <n>     7 · 30 · 60 · 90 · 365, or 'never'. Off-menu values are
                         refused, because the plane would silently substitute
                         its default instead of the window you asked for.

THE ROLE CAP IS THE SERVER'S
  A plain team member may mint a 'read' token only; 'write'/'deploy'/'root' need
  an owner/admin. The CLI does not second-guess your role — it names the control
  plane's refusal and exits 3.`
	out.outf("%s", help)
}
