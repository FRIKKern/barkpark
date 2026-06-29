package cli

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// cliVersion is the binary's CLI version, surfaced by `barkpark version` and
// used for the manifest's min_cli gate when present. Injected at release time
// via -ldflags -X (see Makefile LDFLAGS); "dev" for plain `go build` builds,
// which makes untagged binaries self-evident in bug reports.
var cliVersion = "dev"

// cliCommit and cliDate are release-build provenance, injected alongside
// cliVersion. Empty on dev builds; surfaced only in `bp version -o json` so the
// human output shape stays `barkpark <version>`.
var (
	cliCommit = ""
	cliDate   = ""
)

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

	// Apply query-string params: pagination, manifest-declared query flags, and
	// any declared arg whose location is query (a non-path arg on a read).
	rawURL = applyQuery(rawURL, g, cmd, cmdFlags, argMap)

	// Build the request body for writes. Declared non-path args seed the JSON
	// object; --set merges over them; --file (or stdin) overrides everything; a
	// file-typed arg on a media route is sent as multipart/form-data instead.
	body, contentType, err := buildBody(cmd, cmdFlags, argMap)
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

// authHeaders returns the tier-appropriate auth headers for cmd. Only `none`
// (public, existence-hiding floor) sends no credential. Every authenticated
// tier — read, write, admin, scoped_admin — carries the resolved api bearer
// token whenever one is present, regardless of scoped_prefix: flat
// auth-required reads (e.g. GET /api/workspaces, GET /v1/tasks/:dataset) need
// the bearer just as much as scoped ones, and an OptionalToken public read
// simply ignores a bearer it doesn't need. `ingest` sends the shared ingest
// secret instead of the bearer. NOTE: a scoped_admin command is NEVER
// client-preflight-refused (rule #2) — it is sent with the bearer token and the
// server's 403, if any, is surfaced cleanly.
func authHeaders(cmd manifest.Command, ctx manifest.Context) map[string]string {
	h := map[string]string{}
	switch cmd.AuthTier {
	case "none":
		// Public, unauthenticated. Send nothing.
	case "read", "write", "admin", "scoped_admin":
		if ctx.Token != "" {
			h["Authorization"] = "Bearer " + ctx.Token
		}
	case "ingest":
		// Ingest commands (e.g. bulldocs writes) authenticate with the shared
		// ingest secret, NOT the api_tokens bearer. The server's
		// RequireIngestToken plug reads `Authorization: Bearer <secret>` and
		// constant-time-compares it against the configured :ingest_token
		// (wired from BARKPARK_INGEST_TOKEN). So the
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
// command. It reads BARKPARK_INGEST_TOKEN first, then the legacy
// PAPERFLOW_INGEST_TOKEN env var the server still honours. As a last
// resort it falls back to the resolved bearer token — best-effort only, for the
// single-secret dev setup where both happen to be the same value. The server's
// RequireIngestToken plug compares this against :ingest_token.
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
// paginated command), any manifest-declared string/int flags that are not the
// body-carrying file/set flags, and any declared positional arg whose location
// resolves to "query" (a non-path arg on a read — e.g. search's `q`). Path
// placeholders are already consumed by BuildURL and are skipped here.
func applyQuery(rawURL string, g globals, cmd manifest.Command, flags map[string][]string, args map[string]string) string {
	q := url.Values{}

	if cmd.Paginated {
		if g.limitSet {
			q.Set("limit", strconv.Itoa(g.limit))
		}
		if g.offsetSet {
			q.Set("offset", strconv.Itoa(g.offset))
		}
	}

	// Declared positional args that belong in the query string (e.g. search.query
	// `q` against /v1/data/search/:dataset, which has no :q placeholder).
	for _, a := range cmd.Args {
		if cmd.ArgLocation(a) != "query" {
			continue
		}
		if v, ok := args[a.Name]; ok && v != "" {
			q.Add(a.Name, v)
		}
	}

	// Flags the CLI consumes itself — never forwarded as query params. `all` is a
	// global (client-side pagination); `file`/`set`/`quiet` carry the request body.
	clientOnly := map[string]bool{"file": true, "set": true, "quiet": true, "all": true}
	for _, f := range cmd.Flags {
		if clientOnly[f.Name] || f.Type == "file" {
			continue
		}
		if f.Type == "bool" {
			// A set bool flag rides as `?name=true` (server reads the string).
			if vals, ok := flags[f.Name]; ok && len(vals) > 0 && vals[len(vals)-1] == "true" {
				q.Set(f.Name, "true")
			}
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

// buildBody builds the request body for a write command. Sources, in increasing
// precedence:
//
//  1. declared non-path positional args (arg name -> value) whose location
//     resolves to "body" — e.g. webhook.create `url` -> {"url":"…"},
//     workspace.project-create `name` -> {"name":"…"}.
//  2. --set k=v pairs, merged over the arg-seeded object.
//  3. --file <path> (or - for stdin), which overrides everything and wins.
//
// A file-typed arg on a media route is special-cased FIRST: it ships as
// multipart/form-data with the file under the "file" form field, not as JSON.
// Reads return nil; a write with no body source sends an empty JSON object so a
// POST/PUT that expects JSON does not choke on an empty body.
func buildBody(cmd manifest.Command, flags map[string][]string, args map[string]string) (body []byte, contentType string, err error) {
	if !cmd.Writes {
		return nil, "", nil
	}

	// Media upload (or any file-typed arg on a POST media route): multipart.
	if path, ok := mediaUploadFileArg(cmd, args); ok {
		return buildMultipartFile(path)
	}

	// --file (or stdin) wins outright when given.
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

	// Seed the body object from declared body-location args, then merge --set.
	obj := map[string]any{}
	for _, a := range cmd.Args {
		if cmd.ArgLocation(a) != "body" {
			continue
		}
		if v, ok := args[a.Name]; ok && v != "" {
			obj[a.Name] = v
		}
	}
	// --set fields target: nested under SetKey (e.g. patch's `set`) or, by
	// default, merged flat into the body object.
	setTarget := obj
	if cmd.SetKey != "" {
		setTarget = map[string]any{}
	}
	if sets, ok := flags["set"]; ok && len(sets) > 0 {
		for _, kv := range sets {
			// key:=raw-json sends a TYPED value (httpie convention): the
			// server's patch path merges verbatim with no coercion, so
			// `--set priority=3` stores the STRING "3" (task validators
			// 422 it; untyped schemas silently flip the JSONB type).
			// `--set priority:=3` sends the number; arrays/objects/bools/
			// null ride the same way. Plain key=value stays a string —
			// type is the caller's explicit choice, never sniffed from the
			// value (a title that LOOKS numeric must stay a string).
			if eq := strings.Index(kv, ":="); eq >= 0 && !strings.Contains(kv[:eq], "=") {
				var typed any
				if err := json.Unmarshal([]byte(kv[eq+2:]), &typed); err != nil {
					return nil, "", fmt.Errorf("invalid --set %q: %q is not valid JSON (key:=value sends raw JSON; use key=value for strings)", kv, kv[eq+2:])
				}
				setTarget[kv[:eq]] = typed
				continue
			}
			eq := strings.IndexByte(kv, '=')
			if eq < 0 {
				return nil, "", fmt.Errorf("invalid --set %q (want key=value, or key:=json for typed values)", kv)
			}
			setTarget[kv[:eq]] = kv[eq+1:]
		}
	}
	if cmd.SetKey != "" {
		obj[cmd.SetKey] = setTarget
	}

	// A mutation command (doc publish/unpublish/delete) wraps its body-arg object
	// into the mutate batch shape: {mutations: [{<op>: {type, id, …}}]}.
	if cmd.MutationOp != "" {
		wrapped := map[string]any{
			"mutations": []any{map[string]any{cmd.MutationOp: obj}},
		}
		raw, _ := json.Marshal(wrapped)
		return raw, "application/json", nil
	}

	if len(obj) == 0 {
		// A write with no body source: send an empty JSON object so a POST/PUT
		// that expects JSON does not choke on an empty body.
		return []byte("{}"), "application/json", nil
	}
	raw, _ := json.Marshal(obj)
	return raw, "application/json", nil
}

// mediaUploadFileArg returns the bound file path when cmd has a file-typed
// declared arg AND posts to a media route — the signal that the payload must be
// sent as multipart/form-data rather than JSON. The route check keeps the
// multipart path narrow (only media uploads), so a future file-typed arg on a
// non-media route still goes through the JSON path unless the manifest opts it
// in via a media path.
func mediaUploadFileArg(cmd manifest.Command, args map[string]string) (string, bool) {
	if cmd.HTTP.Method != "POST" {
		return "", false
	}
	if !strings.Contains(cmd.HTTP.PathTemplate, "/media") {
		return "", false
	}
	for _, a := range cmd.Args {
		if a.Type != "file" {
			continue
		}
		if v, ok := args[a.Name]; ok && v != "" {
			return v, true
		}
	}
	return "", false
}

// buildMultipartFile reads path and wraps it in a multipart/form-data body under
// the "file" form field (the field name the server's media upload plug expects).
// The returned content type carries the generated boundary.
func buildMultipartFile(path string) ([]byte, string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("read upload file %q: %w", path, err)
	}
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("file", filepath.Base(path))
	if err != nil {
		return nil, "", fmt.Errorf("multipart create: %w", err)
	}
	if _, err := fw.Write(raw); err != nil {
		return nil, "", fmt.Errorf("multipart write: %w", err)
	}
	if err := mw.Close(); err != nil {
		return nil, "", fmt.Errorf("multipart close: %w", err)
	}
	return buf.Bytes(), mw.FormDataContentType(), nil
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

// renderError prints a classified API error to stderr in the standard shape:
// the message line, an indented fix-suggestion hint when one is registered, and
// — under -v — the machine code and request id for support. Centralised so every
// error path (single request, paginated reads) renders identically.
func renderError(out *writer, ae apiError) {
	out.errf("barkpark: %s", ae.errorMessage())
	if h := ae.hint(); h != "" {
		out.errf("  hint: %s", h)
	}
	if ae.code != "" {
		out.info("  code: %s", ae.code)
	}
	if ae.requestID != "" {
		out.info("  request_id: %s", ae.requestID)
	}
}

// handleResponse renders a success or maps an error body to an exit code.
func handleResponse(out *writer, cmd manifest.Command, status int, respBody []byte) int {
	if status >= 200 && status < 300 {
		renderSuccess(out, cmd, respBody)
		return exitOK
	}
	ae := classifyError(status, respBody)
	renderError(out, ae)
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
	// Shape-keyed receipts for {"ok":…} envelopes (e.g. the tasks endpoints) —
	// keyed off the response shape, never off a verb:
	//
	//   * {"ok":false,"reason":…} on a 2xx (the tasks queue-claim returns
	//     {"ok":false,"reason":"no_ready"} with HTTP 200 on an empty queue — a
	//     valid outcome, not an error; exit stays 0 and non-2xx ok:false shapes
	//     still route through classifyError) prints the reason token. A bare
	//     "ok" there would be actively misleading.
	//   * {"ok":true,"doc":{…}} (a claim-style write returning the affected
	//     doc) prints the doc's identifying line — doc_id plus the fencing
	//     epoch when the doc carries a claim — because the caller needs both
	//     to act on what it just claimed. Falls through to the generic
	//     rev/ids/ok receipt when the doc has no recognisable id.
	if m, isMap := v.(map[string]any); isMap {
		if okv, present := m["ok"].(bool); present {
			if !okv {
				if reason, _ := m["reason"].(string); reason != "" {
					out.outf("%s", reason)
				} else {
					out.outf("not ok")
				}
				return
			}
			if doc, isDoc := m["doc"].(map[string]any); isDoc {
				if line := docReceiptLine(doc); line != "" {
					out.outf("%s", line)
					return
				}
			}
		}
		// Workspace/project create receipts ({"workspace":{…}} / {"project":
		// {…}}): the actionable handle is the SLUG — the -w/-p globals take
		// slugs, not row uuids — so the receipt prints it. A bare "ok" here
		// forced a second call just to learn the handle the next command needs.
		for _, k := range []string{"workspace", "project"} {
			if obj, ok := m[k].(map[string]any); ok {
				if slug, ok := obj["slug"].(string); ok && slug != "" {
					out.outf("%s: %s", k, slug)
					return
				}
			}
		}
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

// docReceiptLine renders the one-line minimal receipt for a single returned
// doc object: its doc_id (falling back to _id / id), plus the fencing epoch
// when the doc carries a claim — "<doc_id> epoch=<n>". Returns "" when no id
// is found, so the caller falls through to the generic rev/ids receipt.
func docReceiptLine(doc map[string]any) string {
	id := ""
	for _, k := range []string{"doc_id", "_id", "id"} {
		if s, ok := doc[k].(string); ok && s != "" {
			id = s
			break
		}
	}
	if id == "" {
		return ""
	}
	if claim, ok := doc["claim"].(map[string]any); ok {
		// JSON numbers decode to float64; the epoch is an integer by contract
		// (content.claim.epoch, bumped on every claim).
		if e, ok := claim["epoch"].(float64); ok {
			return fmt.Sprintf("%s epoch=%d", id, int64(e))
		}
	}
	return id
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
		// ONE id per object, first match wins: _id (documents), doc_id (task
		// rows — their "id" is the row uuid, but every task verb takes the
		// doc_id), then id (media assets). Appending every present key printed
		// two lines per task row.
		for _, k := range []string{"_id", "doc_id", "id"} {
			if val, ok := t[k]; ok {
				if s, ok := val.(string); ok && s != "" {
					ids = append(ids, s)
					break
				}
			}
		}
		if rows, ok := envelopeRows(t); ok {
			for _, d := range rows {
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
			renderError(out, ae)
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
