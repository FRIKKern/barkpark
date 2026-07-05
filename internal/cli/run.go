package cli

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/mattn/go-isatty"
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
		if !renderErrorEnvelope(out, "usage", err.Error(), "", "") {
			out.userErr("%v", err)
			usageCommand(out, cmd)
		}
		return exitUsage
	}

	// Bind positional args to the command's declared arg names.
	argMap, err := bindArgs(cmd, posArgs)
	if err != nil {
		if !renderErrorEnvelope(out, "usage", err.Error(), "", "") {
			out.userErr("%v", err)
			usageCommand(out, cmd)
		}
		return exitUsage
	}

	// Build the absolute URL (fills :placeholders + prepends scoped_prefix).
	rawURL, err := m.BuildURL(cmd, ctx, argMap)
	if err != nil {
		if !renderErrorEnvelope(out, "usage", err.Error(), "", "") {
			out.userErr("%v", err)
		}
		return exitUsage
	}

	// Apply query-string params: pagination, manifest-declared query flags, and
	// any declared arg whose location is query (a non-path arg on a read).
	rawURL = applyQuery(rawURL, g, cmd, cmdFlags, argMap)

	// Build the request body for writes. Declared non-path args seed the JSON
	// object; --set merges over them; --file (or stdin) overrides everything; a
	// file-typed arg on a media route is sent as multipart/form-data instead.
	body, stream, contentType, err := buildBody(cmd, cmdFlags, argMap)
	if err != nil {
		if !renderErrorEnvelope(out, "usage", err.Error(), "", "") {
			out.userErr("%v", err)
		}
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

	// A multipart upload rides the streaming transfer client (no wall-clock
	// Timeout — a large/slow media body must not be killed at 30s); every other
	// write keeps the 30s doRequest client, byte-identical.
	var (
		status   int
		respBody []byte
	)
	if stream != nil {
		status, respBody, err = doRequestStream(cmd.HTTP.Method, rawURL, headers, stream, -1)
	} else {
		status, respBody, err = doRequest(cmd.HTTP.Method, rawURL, headers, body)
	}
	if err != nil {
		if !renderErrorEnvelope(out, "request_failed", "request failed: "+err.Error(), "", "") {
			out.userErr("request failed: %v", err)
		}
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
				// `--force=false` must not silently set the flag true: an inline
				// value on a bool is a usage error, mirroring parseGlobals.
				if hasInline {
					return nil, nil, fmt.Errorf("flag --%s takes no value", name)
				}
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
// multipart/form-data with the file under the "file" form field, not as JSON —
// and as a streaming io.Reader (returned in stream, with body nil) so a large
// upload is neither buffered whole in memory nor killed by the 30s wall-clock.
// Reads return nil; a write with no body source sends an empty JSON object so a
// POST/PUT that expects JSON does not choke on an empty body.
func buildBody(cmd manifest.Command, flags map[string][]string, args map[string]string) (body []byte, stream io.Reader, contentType string, err error) {
	if !cmd.Writes {
		return nil, nil, "", nil
	}

	// Media upload (or any file-typed arg on a POST media route): multipart,
	// streamed via io.Pipe so it rides doRequestStream's transfer client.
	if path, ok := mediaUploadFileArg(cmd, args); ok {
		r, ct, err := buildMultipartFile(path)
		return nil, r, ct, err
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
			return nil, nil, "", fmt.Errorf("read --file %q: %w", path, err)
		}
		return raw, nil, "application/json", nil
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
					return nil, nil, "", fmt.Errorf("invalid --set %q: %q is not valid JSON (key:=value sends raw JSON; use key=value for strings)", kv, kv[eq+2:])
				}
				setTarget[kv[:eq]] = typed
				continue
			}
			eq := strings.IndexByte(kv, '=')
			if eq < 0 {
				return nil, nil, "", fmt.Errorf("invalid --set %q (want key=value, or key:=json for typed values)", kv)
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
		return raw, nil, "application/json", nil
	}

	if len(obj) == 0 {
		// A write with no body source: send an empty JSON object so a POST/PUT
		// that expects JSON does not choke on an empty body.
		return []byte("{}"), nil, "application/json", nil
	}
	raw, _ := json.Marshal(obj)
	return raw, nil, "application/json", nil
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

// buildMultipartFile streams path as a multipart/form-data body under the "file"
// form field (the field name the server's media upload plug expects) via
// io.Pipe, so the file is never buffered whole in memory. It opens+stats the
// file up front (keeping the friendly missing-file error text), then a goroutine
// writes the form part and io.Copies the file into the pipe, calling
// pw.CloseWithError on any failure so the in-flight HTTP request aborts with that
// error. The returned reader is NOT replayable — safe only because
// doRequestStream never retries. The content type carries the generated boundary.
func buildMultipartFile(path string) (io.Reader, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", fmt.Errorf("read upload file %q: %w", path, err)
	}
	if _, err := f.Stat(); err != nil {
		f.Close()
		return nil, "", fmt.Errorf("read upload file %q: %w", path, err)
	}
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		defer f.Close()
		fw, err := mw.CreateFormFile("file", filepath.Base(path))
		if err != nil {
			pw.CloseWithError(fmt.Errorf("multipart create: %w", err))
			return
		}
		if _, err := io.Copy(fw, f); err != nil {
			pw.CloseWithError(fmt.Errorf("multipart write: %w", err))
			return
		}
		if err := mw.Close(); err != nil {
			pw.CloseWithError(fmt.Errorf("multipart close: %w", err))
			return
		}
		pw.Close()
	}()
	return pr, mw.FormDataContentType(), nil
}

// transferResponseHeaderTimeout bounds only the wait for a response's headers on
// the streaming transfer client (media upload, upgrade download) — NOT the
// transfer body's wall-clock. A var, not a const, so tests can shrink it.
var transferResponseHeaderTimeout = 60 * time.Second

// newTransferClient builds an HTTP client with NO absolute Timeout — only
// connection-phase deadlines (dial, TLS handshake, response-header wait). A
// media upload or binary download whose BODY legitimately takes minutes must not
// be killed mid-transfer the way the 30s doRequest client kills any upload
// >30s wall-clock. Mirrors curl/gh/stripe: cap the connection, never the body.
// Reads transferResponseHeaderTimeout at call time so a test's shrunk value
// takes effect.
func newTransferClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy: http.ProxyFromEnvironment,
			DialContext: (&net.Dialer{
				Timeout:   10 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			TLSHandshakeTimeout:   10 * time.Second,
			ResponseHeaderTimeout: transferResponseHeaderTimeout,
		},
	}
}

// doRequestStream is doRequest for a streaming, non-replayable body (the
// multipart media upload io.Pipe): it takes an io.Reader and drives the
// header-timeout-only transfer client so a large/slow upload is not killed by
// doRequest's 30s wall-clock cap. contentLength >= 0 sets Content-Length; -1
// leaves it unknown (chunked). It performs NO retries — required, since a pipe
// body cannot be replayed.
func doRequestStream(method, rawURL string, headers map[string]string, body io.Reader, contentLength int64) (int, []byte, error) {
	req, err := http.NewRequest(method, rawURL, body)
	if err != nil {
		return 0, nil, err
	}
	if contentLength >= 0 {
		req.ContentLength = contentLength
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := newTransferClient().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	respBody, err := readCapped(resp.Body, maxResponseBytes)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, respBody, nil
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
	respBody, err := readCapped(resp.Body, maxResponseBytes)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, respBody, nil
}

// maxResponseBytes caps how much of an HTTP response body the generic request
// paths will buffer.
const maxResponseBytes = 64 << 20 // 64MB — generous cap for query/doc bodies; hostile or runaway responses fail loudly instead of OOMing

// readCapped reads at most max bytes from r, failing loudly rather than silently
// truncating: it reads one byte past the cap so an over-limit body is detected
// (io.LimitReader alone would just truncate). Used by the generic HTTP request
// paths so a malformed/hostile server cannot OOM the process.
func readCapped(r io.Reader, max int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, fmt.Errorf("response exceeds %d bytes — refusing to parse a truncated body", max)
	}
	return b, nil
}

// renderError renders a classified API error. Under -o json/yaml it emits the
// canonical {ok:false, error:{code, message, request_id, hint}} envelope on
// stdout (same contract as the cloud built-ins' useError, richer because apiError
// carries request_id + hint) so a scripted `bp … -o json | jq` gets a parseable
// body rather than empty stdout. For table/minimal it prints the human shape to
// stderr: the message line, an indented fix-suggestion hint when one is
// registered, and — under -v — the machine code and request id for support.
// Centralised so every error path (single request, paginated reads) is identical.
func renderError(out *writer, ae apiError) {
	if renderErrorEnvelope(out, ae.code, ae.errorMessage(), ae.requestID, ae.hint()) {
		return
	}
	out.userErr("%s", ae.errorMessage())
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

	// Handoff-card shape: a 2xx object carrying a non-empty string "quickstart"
	// (the ticket-key mint / rotate receipt) prints that block verbatim as the
	// primary human output — the 2-minute-onboarding card the operator forwards.
	// Shape-keyed, never verb-keyed (like emitWarnings): any response may opt in
	// by carrying the field. Only the human `table` default shows the card;
	// `json`/`yaml` consumers read the structured field and `minimal` stays the
	// terse agent receipt.
	if out.output == "table" {
		if card := quickstartCard(payload); card != "" {
			out.outf("%s", card)
			emitWarnings(out, payload)
			return
		}
	}

	switch out.output {
	case "minimal":
		renderMinimal(out, payload)
		emitWarnings(out, payload)
	case "yaml":
		var v any
		if json.Unmarshal(payload, &v) == nil {
			out.renderYAML(v)
		} else {
			out.outf("%s", string(payload))
		}
	case "table":
		renderTable(out, payload)
		emitWarnings(out, payload)
	default: // json
		out.renderRaw(payload)
	}
}

// quickstartCard returns the value of a top-level string "quickstart" field on
// a 2xx object payload (the ticket-key mint/rotate handoff card), or "" when the
// field is absent, empty, or not a string. Pure/shape-keyed so any endpoint can
// opt into the plain-block render by carrying the field.
func quickstartCard(payload []byte) string {
	var env struct {
		Quickstart string `json:"quickstart"`
	}
	if json.Unmarshal(payload, &env) != nil {
		return ""
	}
	return strings.TrimRight(env.Quickstart, "\n")
}

// emitWarnings prints a top-level {"warnings":[…]} string list to stderr for
// the human output shapes (minimal/table). Shape-keyed, never verb-keyed: any
// 2xx envelope may carry advisory strings — e.g. the tasks close endpoint
// warns when a task is closed done with unmet acceptance_criteria (lvw-t6).
// Advisory only: exit code and stdout payload are untouched; json/yaml
// consumers read the field itself.
func emitWarnings(out *writer, payload []byte) {
	var env struct {
		Warnings []any `json:"warnings"`
	}
	if json.Unmarshal(payload, &env) != nil {
		return
	}
	for _, w := range env.Warnings {
		if s, ok := w.(string); ok && s != "" {
			out.errf("warning: %s", s)
		}
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
		// Skipped when the payload ALSO carries a list envelope: project-ls
		// returns {"workspace":{…},"projects":[…]} — the user wants the projects
		// listed, not the workspace-context slug echoed back.
		if _, hasList := envelopeRows(m); !hasList {
			for _, k := range []string{"workspace", "project"} {
				if obj, ok := m[k].(map[string]any); ok {
					if slug, ok := obj["slug"].(string); ok && slug != "" {
						out.outf("%s: %s", k, slug)
						return
					}
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
// when the doc carries a claim, plus the doc's rev when present — e.g.
// "<doc_id> epoch=<n> rev=<rev>". The rev is what a close pins to fence its
// write, so a claim receipt that carries one echoes it. Returns "" when no id
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
	line := id
	if claim, ok := doc["claim"].(map[string]any); ok {
		// JSON numbers decode to float64; the epoch is an integer by contract
		// (content.claim.epoch, bumped on every claim).
		if e, ok := claim["epoch"].(float64); ok {
			line += fmt.Sprintf(" epoch=%d", int64(e))
		}
	}
	// Rev rides the top-level doc object (render_doc emits "rev"; older/other
	// shapes may use "_rev"). Shape-keyed only — appended whenever the claim-
	// style doc carries one, no verb-specific logic.
	if rev := scalarString(doc["rev"], doc["_rev"]); rev != "" {
		line += " rev=" + rev
	}
	return line
}

// scalarString returns the first argument that renders as a non-empty scalar
// (string or JSON number), formatted as a string. Used so a rev decoded as
// either a hex string or a bare number both print cleanly.
func scalarString(vals ...any) string {
	for _, v := range vals {
		switch t := v.(type) {
		case string:
			if t != "" {
				return t
			}
		case float64:
			return strconv.FormatInt(int64(t), 10)
		}
	}
	return ""
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
		// doc_id), then id (media assets). The name/scope fallbacks cover the
		// admin list rows that carry no id at all — schema.ls / plugin.ls rows
		// are keyed by "name", share.ls rows by "scope". Without them those
		// commands printed a bare "ok" under -o minimal (zero information).
		// Order matters: id-bearing rows (docs/tasks/media/workspaces/projects)
		// match before the fallbacks, so their output is unchanged.
		// Appending every present key printed two lines per task row.
		for _, k := range []string{"_id", "doc_id", "id", "from_doc_id", "name", "scope"} {
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
	// Detected on page 1, then held for every page and the final re-wrap so the
	// renderer sees the envelope shape the command emits (docs/hits/… not just
	// documents). Empty until the first page is extracted.
	key := ""
	for {
		pageURL := withOffsetLimit(baseURL, offset, pageSize)
		status, respBody, err := doRequest(cmd.HTTP.Method, pageURL, headers, nil)
		if err != nil {
			if !renderErrorEnvelope(out, "request_failed", "request failed: "+err.Error(), "", "") {
				out.userErr("request failed: %v", err)
			}
			return exitGeneric
		}
		if status < 200 || status >= 300 {
			ae := classifyError(status, respBody)
			renderError(out, ae)
			return ae.exit
		}
		docs, k := extractListRows(unwrapResult(respBody))
		if key == "" {
			key = k
		}
		all = append(all, docs...)
		if len(docs) < pageSize {
			break
		}
		offset += pageSize
	}

	// Unknown envelope (no known key on page 1): fall back to the documents shape
	// so nothing regresses.
	if key == "" {
		key = "documents"
	}
	wrapped, _ := json.Marshal(map[string]any{key: json.RawMessage(mustArray(all))})
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

// extractListRows pulls the row array out of a list envelope, trying the known
// envelope keys (table.go's listEnvelopeKeys) in order. It returns the rows and
// the matched key; the first key whose value is a JSON array wins — an EMPTY
// array still counts as a match so key detection works on an empty first page.
// key is "" when the payload carries no known list envelope.
func extractListRows(payload []byte) ([]json.RawMessage, string) {
	var env map[string]json.RawMessage
	if json.Unmarshal(payload, &env) != nil {
		return nil, ""
	}
	for _, k := range listEnvelopeKeys {
		raw, ok := env[k]
		if !ok {
			continue
		}
		var rows []json.RawMessage
		if json.Unmarshal(raw, &rows) == nil {
			return rows, k
		}
	}
	return nil, ""
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
	// Gate on the ANSWER stream (stdin) and the PROMPT stream (stderr) — the two
	// streams this prompt actually uses — deliberately NOT stdout. That keeps
	// `bp … -o json > file` interactive: redirecting the JSON receipt leaves the
	// operator at a terminal that can still answer. (uninstall_cmd.go gates on
	// stdout because its prompt is on stdout; ours is on stderr, so we diverge.)
	// Non-TTY stdin (CI, piped, `echo | bp …`) can't answer the prompt: ReadString
	// hits EOF, the answer is empty, and the caller's "aborted" message never names
	// the flag that unblocks it. Name --yes here instead.
	if !(isatty.IsTerminal(os.Stdin.Fd()) && isatty.IsTerminal(os.Stderr.Fd())) {
		out.userErr("prod write to %s needs confirmation — re-run with --yes", ctx.Server)
		return false
	}
	fmt.Fprintf(out.stderr, "⚠ PROD: %s %s writes to %s. Continue? [y/N] ", cmd.Noun, cmd.Verb, ctx.Server)
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
	redacted := redactHeaders(headers)

	// Machine-readable modes emit the preview as a structured document so a
	// `--dry-run -o json | jq` pipe stays parseable. The stderr notice above is
	// off-stdout and does not pollute it.
	if out.output == "json" || out.output == "yaml" {
		// The YAML emitter only recurses into map[string]any, so widen the
		// redacted header map (JSON handles either shape).
		hdrs := make(map[string]any, len(redacted))
		for k, v := range redacted {
			hdrs[k] = v
		}
		payload := map[string]any{
			"method":  cmd.HTTP.Method,
			"url":     rawURL,
			"headers": hdrs,
		}
		if len(body) > 0 {
			var parsed any
			if json.Unmarshal(body, &parsed) == nil {
				payload["body"] = parsed
			} else {
				payload["body"] = string(body)
			}
		}
		if out.output == "json" {
			out.renderJSON(payload)
		} else {
			out.renderYAML(payload)
		}
		return exitOK
	}

	out.outf("%s %s", cmd.HTTP.Method, rawURL)
	keys := make([]string, 0, len(redacted))
	for k := range redacted {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out.outf("%s: %s", k, redacted[k])
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
