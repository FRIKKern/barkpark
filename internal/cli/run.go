package cli

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// cliVersion is the binary's CLI version, surfaced by `barkpark version` and
// used for the manifest's min_cli gate when present.
const cliVersion = "1.0.0"

// runCommand executes one manifest command: resolves positional args + flags,
// builds the request via manifest.BuildURL, applies the tier-appropriate
// credential, honours --dry-run and the prod write-guard, sends, then renders
// the result or maps the error envelope to an exit code.
func runCommand(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	out.resolveOutputForCommand(g, cmd.DefaultOutput)

	// Split tail into positional args and command-local flags.
	posArgs, cmdFlags, err := splitArgs(cmd, tail)
	if err != nil {
		out.errf("barkpark: %v", err)
		usageCommand(out, cmd)
		return exitUsage
	}

	// Bind positional args to the command's declared arg names.
	argMap, err := bindArgs(cmd, posArgs)
	if err != nil {
		out.errf("barkpark: %v", err)
		usageCommand(out, cmd)
		return exitUsage
	}

	// Build the absolute URL (fills :placeholders + prepends scoped_prefix).
	rawURL, err := m.BuildURL(cmd, ctx, argMap)
	if err != nil {
		out.errf("barkpark: %v", err)
		return exitUsage
	}

	// Apply query-string flags (pagination + manifest-declared query flags).
	rawURL = applyQuery(rawURL, g, cmd, cmdFlags)

	// Build the request body for writes (from --file or stdin / --set pairs).
	body, contentType, err := buildBody(cmd, cmdFlags)
	if err != nil {
		out.errf("barkpark: %v", err)
		return exitUsage
	}

	// Tier-appropriate credential.
	headers := authHeaders(cmd, ctx)
	if contentType != "" {
		headers["Content-Type"] = contentType
	}

	// --dry-run: print the resolved request and exit 0 WITHOUT sending (A1).
	if g.dryRun {
		return dryRun(out, cmd, rawURL, headers, body)
	}

	// Prod write-guard: a write against a prod-looking target needs confirmation
	// unless --yes. (scoped_admin still attempts — the guard is local UX, not the
	// client preflight-refuse that rule #2 forbids.)
	if cmd.Writes && isProd(ctx, m) && !g.yes {
		if !confirmProdWrite(out, cmd, ctx) {
			out.errf("aborted: prod write not confirmed")
			return exitUsage
		}
	}

	// Paginated reads with --all loop over offset pages.
	if cmd.Paginated && g.all && !cmd.Writes {
		return runPaginatedAll(out, cmd, rawURL, headers)
	}

	status, respBody, err := doRequest(cmd.HTTP.Method, rawURL, headers, body)
	if err != nil {
		out.errf("barkpark: request failed: %v", err)
		return exitGeneric
	}
	return handleResponse(out, cmd, status, respBody)
}

// authHeaders returns the tier-appropriate auth headers for cmd. read/none send
// nothing extra (a scoped read still carries the resolved token because the
// server's ResolveWorkspace fails closed — but a flat public read needs none);
// write/admin send the bearer token; ingest sends the ingest secret. NOTE: a
// scoped_admin command is NEVER client-preflight-refused (rule #2) — it is sent
// with the bearer token and the server's 403 is surfaced cleanly.
func authHeaders(cmd manifest.Command, ctx manifest.Context) map[string]string {
	h := map[string]string{}
	switch cmd.AuthTier {
	case "none":
		// Public, unauthenticated. Send nothing.
	case "read":
		// Public reads need no creds on flat paths; scoped reads (scoped_prefix
		// set) require workspace resolution, which fails closed for an anonymous
		// caller — so carry the resolved token when the path is scoped.
		if cmd.ScopedPrefix != nil && *cmd.ScopedPrefix != "" && ctx.Token != "" {
			h["Authorization"] = "Bearer " + ctx.Token
		}
	case "write", "admin", "scoped_admin":
		if ctx.Token != "" {
			h["Authorization"] = "Bearer " + ctx.Token
		}
	case "ingest":
		// Ingest commands (e.g. bulldocs writes) authenticate with the shared
		// ingest secret, NOT the api_tokens bearer. The server's
		// RequireIngestToken plug reads `Authorization: Bearer <secret>` and
		// constant-time-compares it against the configured :paperflow_ingest_token
		// (wired from PAPERFLOW_INGEST_TOKEN / BARKPARK_INGEST_TOKEN). So the
		// secret rides the standard Authorization: Bearer header — same header,
		// different credential source than the bearer api token.
		if secret := ingestSecret(ctx); secret != "" {
			h["Authorization"] = "Bearer " + secret
		}
	default:
		// Unknown tier: be permissive and attach the token if we have one.
		if ctx.Token != "" {
			h["Authorization"] = "Bearer " + ctx.Token
		}
	}
	return h
}

// ingestSecret resolves the shared ingest secret for an `auth_tier: ingest`
// command. It reads BARKPARK_INGEST_TOKEN first, then the PAPERFLOW_INGEST_TOKEN
// alias (the original convergence env var the server still honours). As a last
// resort it falls back to the resolved bearer token — best-effort only, for the
// single-secret dev setup where both happen to be the same value. The server's
// RequireIngestToken plug compares this against :paperflow_ingest_token.
func ingestSecret(ctx manifest.Context) string {
	if s := os.Getenv("BARKPARK_INGEST_TOKEN"); s != "" {
		return s
	}
	if s := os.Getenv("PAPERFLOW_INGEST_TOKEN"); s != "" {
		return s
	}
	return ctx.Token
}

// shortFlagAliases maps a single-dash short flag to the canonical long flag
// name it stands for. Only -f/--file is wired today (the universal batch-payload
// short form); the table keeps it discoverable and additive. A short alias is
// only honoured when the command actually declares the long flag — so it never
// invents a flag the manifest didn't.
var shortFlagAliases = map[string]string{
	"-f": "file",
}

// splitArgs separates positional args from command-local flags in tail.
// Command flags are looked up in cmd.Flags; an unknown -flag is an error so a
// typo doesn't get silently swallowed as a positional. Long flags use
// --name[=val]; the -f short form aliases --file when the command declares it.
func splitArgs(cmd manifest.Command, tail []string) (pos []string, flags map[string][]string, err error) {
	flags = map[string][]string{}
	byName := map[string]manifest.Flag{}
	for _, f := range cmd.Flags {
		byName[f.Name] = f
	}

	i := 0
	for i < len(tail) {
		a := tail[i]

		// Long flag: --name or --name=value.
		if len(a) >= 2 && strings.HasPrefix(a, "--") {
			name := a[2:]
			val := ""
			hasInline := false
			if eq := strings.IndexByte(name, '='); eq >= 0 {
				val = name[eq+1:]
				name = name[:eq]
				hasInline = true
			}
			f, ok := byName[name]
			if !ok {
				return nil, nil, fmt.Errorf("unknown flag --%s for %s %s", name, cmd.Noun, cmd.Verb)
			}
			if f.Type == "bool" {
				flags[name] = append(flags[name], "true")
			} else {
				if !hasInline {
					if i+1 >= len(tail) {
						return nil, nil, fmt.Errorf("flag --%s needs a value", name)
					}
					val = tail[i+1]
					i++
				}
				flags[name] = append(flags[name], val)
			}
			i++
			continue
		}

		// Short flag: -f (and any future -x aliases). Resolve to its canonical
		// long flag, then reuse the long-flag value-consume path.
		if len(a) == 2 && a[0] == '-' && a != "-" {
			long, aliased := shortFlagAliases[a]
			if !aliased {
				return nil, nil, fmt.Errorf("unknown flag %s for %s %s", a, cmd.Noun, cmd.Verb)
			}
			f, ok := byName[long]
			if !ok {
				return nil, nil, fmt.Errorf("unknown flag %s for %s %s", a, cmd.Noun, cmd.Verb)
			}
			if f.Type == "bool" {
				flags[long] = append(flags[long], "true")
				i++
				continue
			}
			if i+1 >= len(tail) {
				return nil, nil, fmt.Errorf("flag %s needs a value", a)
			}
			flags[long] = append(flags[long], tail[i+1])
			i += 2
			continue
		}

		pos = append(pos, a)
		i++
	}
	return pos, flags, nil
}

// bindArgs maps positional values onto the command's declared args by position,
// enforcing required args. Extra positionals beyond the declared args are an
// error.
func bindArgs(cmd manifest.Command, pos []string) (map[string]string, error) {
	m := map[string]string{}
	for i, arg := range cmd.Args {
		if i < len(pos) {
			m[arg.Name] = pos[i]
		} else if arg.Required {
			return nil, fmt.Errorf("missing required argument <%s> for %s %s", arg.Name, cmd.Noun, cmd.Verb)
		}
	}
	if len(pos) > len(cmd.Args) {
		return nil, fmt.Errorf("too many arguments for %s %s (expected %d)", cmd.Noun, cmd.Verb, len(cmd.Args))
	}
	return m, nil
}

// applyQuery appends query-string parameters: pagination (--limit/--offset for a
// paginated command) plus any manifest-declared string/int flags that are not
// the body-carrying file/set flags.
func applyQuery(rawURL string, g globals, cmd manifest.Command, flags map[string][]string) string {
	q := url.Values{}

	if cmd.Paginated {
		if g.limitSet {
			q.Set("limit", strconv.Itoa(g.limit))
		}
		if g.offsetSet {
			q.Set("offset", strconv.Itoa(g.offset))
		}
	}

	bodyFlags := map[string]bool{"file": true, "set": true, "quiet": true}
	for _, f := range cmd.Flags {
		if bodyFlags[f.Name] || f.Type == "bool" || f.Type == "file" {
			continue
		}
		if vals, ok := flags[f.Name]; ok {
			for _, v := range vals {
				q.Add(f.Name, v)
			}
		}
	}

	if len(q) == 0 {
		return rawURL
	}
	sep := "?"
	if strings.Contains(rawURL, "?") {
		sep = "&"
	}
	return rawURL + sep + q.Encode()
}

// buildBody builds the request body for a write command. A --file flag reads the
// payload from a path (or - for stdin); --set k=v pairs build a JSON object.
// Reads and bodyless writes return nil.
func buildBody(cmd manifest.Command, flags map[string][]string) (body []byte, contentType string, err error) {
	if !cmd.Writes {
		return nil, "", nil
	}

	if files, ok := flags["file"]; ok && len(files) > 0 {
		path := files[len(files)-1]
		var raw []byte
		if path == "-" {
			raw, err = io.ReadAll(os.Stdin)
		} else {
			raw, err = os.ReadFile(path)
		}
		if err != nil {
			return nil, "", fmt.Errorf("read --file %q: %w", path, err)
		}
		return raw, "application/json", nil
	}

	if sets, ok := flags["set"]; ok && len(sets) > 0 {
		obj := map[string]any{}
		for _, kv := range sets {
			eq := strings.IndexByte(kv, '=')
			if eq < 0 {
				return nil, "", fmt.Errorf("invalid --set %q (want key=value)", kv)
			}
			obj[kv[:eq]] = kv[eq+1:]
		}
		raw, _ := json.Marshal(obj)
		return raw, "application/json", nil
	}

	// A write with no body source: send an empty JSON object so a POST/PUT that
	// expects JSON does not choke on an empty body.
	return []byte("{}"), "application/json", nil
}

// doRequest performs the HTTP call and returns status + body.
func doRequest(method, rawURL string, headers map[string]string, body []byte) (int, []byte, error) {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, rawURL, rdr)
	if err != nil {
		return 0, nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, respBody, nil
}

// handleResponse renders a success or maps an error body to an exit code.
func handleResponse(out *writer, cmd manifest.Command, status int, respBody []byte) int {
	if status >= 200 && status < 300 {
		renderSuccess(out, cmd, respBody)
		return exitOK
	}
	ae := classifyError(status, respBody)
	out.errf("barkpark: %s", ae.errorMessage())
	if out.verbose && ae.requestID != "" {
		out.info("request_id: %s", ae.requestID)
	}
	return ae.exit
}

// renderSuccess prints a successful body in the resolved output shape. The API
// wraps data in {"result": …}; the CLI unwraps it for display so the user sees
// the payload, not the envelope. minimal/quiet prints rev + ids only.
func renderSuccess(out *writer, cmd manifest.Command, respBody []byte) {
	payload := unwrapResult(respBody)

	switch out.output {
	case "minimal":
		renderMinimal(out, payload)
	case "yaml":
		var v any
		if json.Unmarshal(payload, &v) == nil {
			out.renderYAML(v)
		} else {
			out.outf("%s", string(payload))
		}
	case "table":
		renderTable(out, payload)
	default: // json
		out.renderRaw(payload)
	}
}

// unwrapResult strips a top-level {"result": X} envelope, returning X's raw
// bytes. A body without that envelope is returned unchanged.
func unwrapResult(body []byte) []byte {
	var env map[string]json.RawMessage
	if err := json.Unmarshal(body, &env); err != nil {
		return body
	}
	if r, ok := env["result"]; ok {
		return r
	}
	return body
}

// renderMinimal prints the token-efficient receipt: the rev and any document
// ids found in the payload. It is the default write receipt (default_output
// "minimal") and the -q shape.
func renderMinimal(out *writer, payload []byte) {
	var v any
	if json.Unmarshal(payload, &v) != nil {
		out.outf("%s", strings.TrimSpace(string(payload)))
		return
	}
	ids := collectIDs(v)
	rev := findRev(v)
	if rev != "" {
		out.outf("rev: %s", rev)
	}
	for _, id := range ids {
		out.outf("id: %s", id)
	}
	if rev == "" && len(ids) == 0 {
		out.outf("ok")
	}
}

func findRev(v any) string {
	switch t := v.(type) {
	case map[string]any:
		for _, k := range []string{"_rev", "rev", "transactionId", "results"} {
			if val, ok := t[k]; ok {
				if s, ok := val.(string); ok {
					return s
				}
			}
		}
	}
	return ""
}

func collectIDs(v any) []string {
	var ids []string
	switch t := v.(type) {
	case map[string]any:
		for _, k := range []string{"_id", "id"} {
			if val, ok := t[k]; ok {
				if s, ok := val.(string); ok {
					ids = append(ids, s)
				}
			}
		}
		if docs, ok := t["documents"].([]any); ok {
			for _, d := range docs {
				ids = append(ids, collectIDs(d)...)
			}
		}
	case []any:
		for _, item := range t {
			ids = append(ids, collectIDs(item)...)
		}
	}
	return ids
}

// runPaginatedAll fetches every offset page of a paginated read and prints the
// concatenated documents in the resolved output shape.
func runPaginatedAll(out *writer, cmd manifest.Command, baseURL string, headers map[string]string) int {
	const pageSize = 100
	offset := 0
	var all []json.RawMessage
	for {
		pageURL := withOffsetLimit(baseURL, offset, pageSize)
		status, respBody, err := doRequest(cmd.HTTP.Method, pageURL, headers, nil)
		if err != nil {
			out.errf("barkpark: request failed: %v", err)
			return exitGeneric
		}
		if status < 200 || status >= 300 {
			ae := classifyError(status, respBody)
			out.errf("barkpark: %s", ae.errorMessage())
			return ae.exit
		}
		docs := extractDocuments(unwrapResult(respBody))
		all = append(all, docs...)
		if len(docs) < pageSize {
			break
		}
		offset += pageSize
	}

	wrapped, _ := json.Marshal(map[string]any{"documents": json.RawMessage(mustArray(all))})
	renderSuccess(out, cmd, mustResult(wrapped))
	return exitOK
}

func withOffsetLimit(rawURL string, offset, limit int) string {
	sep := "?"
	if strings.Contains(rawURL, "?") {
		// Replace existing offset/limit by appending — last value wins on the server.
		sep = "&"
	}
	return fmt.Sprintf("%s%soffset=%d&limit=%d", rawURL, sep, offset, limit)
}

func extractDocuments(payload []byte) []json.RawMessage {
	var env struct {
		Documents []json.RawMessage `json:"documents"`
	}
	if json.Unmarshal(payload, &env) == nil && env.Documents != nil {
		return env.Documents
	}
	return nil
}

func mustArray(items []json.RawMessage) []byte {
	b, _ := json.Marshal(items)
	return b
}

func mustResult(inner []byte) []byte {
	b, _ := json.Marshal(map[string]json.RawMessage{"result": inner})
	return b
}

// confirmProdWrite prompts on stderr and reads a [y/N] answer from stdin.
func confirmProdWrite(out *writer, cmd manifest.Command, ctx manifest.Context) bool {
	out.errf("⚠ PROD: %s %s writes to %s. Continue? [y/N]", cmd.Noun, cmd.Verb, ctx.Server)
	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')
	line = strings.TrimSpace(strings.ToLower(line))
	return line == "y" || line == "yes"
}

// isProd decides whether the target is production via a name/url heuristic on
// the manifest's server identity and the resolved server URL.
func isProd(ctx manifest.Context, m *manifest.Manifest) bool {
	name := strings.ToLower(m.Server.Name)
	if name == "prod" || name == "production" {
		return true
	}
	s := strings.ToLower(ctx.Server + " " + m.Server.BaseURL)
	if strings.Contains(s, "localhost") || strings.Contains(s, "127.0.0.1") || strings.Contains(s, "0.0.0.0") {
		return false
	}
	return strings.Contains(s, "api.barkpark.cloud") || strings.Contains(s, "prod")
}

// dryRun prints the resolved method/path/headers(redacted)/body and exits 0
// WITHOUT calling (M0 decision A1). Since the manifest's dry_run is false in v1,
// it announces the client-side-preview degradation.
func dryRun(out *writer, cmd manifest.Command, rawURL string, headers map[string]string, body []byte) int {
	out.errf("dry-run: client-side preview only (server validate-only not available)")
	out.outf("%s %s", cmd.HTTP.Method, rawURL)
	for k, v := range redactHeaders(headers) {
		out.outf("%s: %s", k, v)
	}
	if len(body) > 0 {
		out.outf("")
		out.outf("%s", string(body))
	}
	return exitOK
}

// redactHeaders masks credential header values so a dry-run never prints a token.
func redactHeaders(h map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range h {
		lk := strings.ToLower(k)
		if lk == "authorization" || strings.Contains(lk, "secret") || strings.Contains(lk, "token") {
			out[k] = redact(v)
		} else {
			out[k] = v
		}
	}
	return out
}

func redact(v string) string {
	if strings.HasPrefix(v, "Bearer ") {
		return "Bearer ****"
	}
	return "****"
}
