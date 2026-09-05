package cli

// mcp_serve.go — `bp mcp serve`: a stdio Model-Context-Protocol server that
// exposes Barkpark Tasks to MCP-native clients (Cursor, Claude Desktop, any MCP
// host). This is "path B" for task tracking: path A is the shell-based
// .cursor/rules/barkpark-tasks.mdc card (an agent shells out to `bp task …`);
// path B lets a client that speaks MCP call the SAME task verbs as first-class
// tools, no shell, with the claim-first/epoch-CAS doctrine carried in each
// tool's description so the model uses the queue correctly.
//
// A CLI built-in intercepted before manifest dispatch (like cmux/doctor): `mcp`
// is not a manifest noun, so this intercept shadows nothing and needs no server
// change. runMCPServe loads the capabilities manifest ONCE and reuses the CLI's
// manifest-driven request machinery (BuildURL → buildBody → authHeaders →
// doRequest, run.go) to back each MCP tool — so the tools can never drift from
// what `bp task …` does.
//
// CRITICAL stdio invariant: the JSON-RPC framing rides os.Stdout. A single stray
// byte on os.Stdout corrupts the protocol stream. So every tool handler returns
// its payload as MCP result content and writes NOTHING to os.Stdout — no
// handleResponse, no render*, no receipt. Diagnostics (the startup line, fatal
// errors) go to os.Stderr only.
//
// REMOTE transport (`--http <addr>`, viable-everywhere charter D18): the same
// server also speaks Streamable HTTP for remote MCP clients (Claude.ai/ChatGPT-
// class connectors, via a fronting proxy). The design is FORWARD-THROUGH: the
// process holds NO ambient credential — every request's `Authorization: Bearer`
// is copied into a per-request manifest.Context and rides downstream on the
// normal dispatch seam, so Barkpark's own Auth.verify_token/1 stays the single
// choke point and a missing/bogus bearer fails closed with the ordinary 401
// envelope. No pre-verify middleware in v1 (charter D18: no bearer-gated
// verify-only route exists, and the SDK's RequireBearerToken hard-401s tokens
// without an expiry, which Barkpark tokens legitimately are).

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// runMCPServe handles `bp mcp serve [--tools tasks|all]`. It loads the manifest,
// registers the curated task tools (and, with --tools all, the generic
// capabilities→MCP bridge), then serves the MCP protocol over stdin/stdout until
// the client disconnects or the process is signalled. Returns the exit code.
//
// The manifest load is fail-fast: an MCP client launches `bp mcp serve` as a
// long-lived subprocess and expects a ready server on the pipe, so a server it
// can't back (no manifest reachable) must die immediately with a clear stderr
// line rather than come up half-alive and 500 every tool call.
func runMCPServe(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printMCPServeHelp(out)
		return exitOK
	}

	toolset, nouns, httpAddr, err := parseMCPServeArgs(tail)
	if err != nil {
		return usageErrf(out, func() { printMCPServeHelp(out) }, "%v", err)
	}

	// Load the manifest ONCE (honours --manifest / $BARKPARK_MANIFEST, else the
	// ETag cache / GET /v1/capabilities). Fail fast to stderr + non-zero: the MCP
	// tools are backed by this manifest, so an unreachable one is fatal now, not
	// per-tool-call later.
	m, err := loadManifest(g, ctx)
	if err != nil {
		out.userErr("mcp serve: cannot start — %v", err)
		return exitGeneric
	}

	if httpAddr != "" {
		return runMCPServeHTTP(out, g, ctx, m, toolset, nouns, httpAddr)
	}

	// Stdio mode: one server instance, the process's own credential (env/config),
	// papers enumerated once at startup for resources/list.
	srv, err := buildMCPServer(out, g, ctx, m, toolset, nouns, true)
	if err != nil {
		out.userErr("mcp serve: %v", err)
		return exitGeneric
	}

	// Announce readiness on stderr (never stdout — that pipe is the protocol).
	out.errf("bp mcp serve: %s tools over stdio (server %s) — Ctrl-C to stop", toolsetLabel(toolset, nouns), ctx.Server)

	// A signalled process (Ctrl-C, SIGTERM) cancels the context so Run returns
	// cleanly instead of leaving a zombie on the pipe. Run also returns on its own
	// when the client closes stdin (EOF) — the normal end of an MCP session.
	runCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := srv.Run(runCtx, &mcp.StdioTransport{}); err != nil {
		// A cancelled context (we asked it to stop) is a clean shutdown, not a
		// failure. Any other error (transport fault) is real.
		if runCtx.Err() != nil {
			return exitOK
		}
		out.userErr("mcp serve: %v", err)
		return exitGeneric
	}
	return exitOK
}

// mcpToolsetTasksBestEffort is the toolset word the `--http` transport uses in
// place of "tasks". Registration is IDENTICAL to "tasks" — the curated task
// tools and nothing else — but a manifest that cannot back them DEGRADES with
// one loud stderr line instead of refusing to start.
//
// Why --http and not stdio: a stdio server is launched per client with the
// user's own credential, so a manifest without the task noun is a real
// misconfiguration the operator should see as an immediate non-zero exit. An
// --http server holds NO ambient credential by design (forward-through, charter
// D18), so its ONE startup manifest is always the ANONYMOUS projection of GET
// /v1/capabilities — which on a stock Barkpark carries doc/media/search/auth and
// NO task noun. Failing fast there turns a correct, useful bridge into a systemd
// crash loop (barkpark-mcp.service: NRestarts 2464, one exit-1 every 10 s) while
// the endpoint 503s. The tools a caller's bearer would unlock cannot be
// recovered per request anyway — the stateless per-request rebuild reuses this
// same startup manifest — so the honest behaviour is to serve what the manifest
// DOES back and say loudly, once, what is missing and why.
//
// This value is unreachable from user input: parseToolsSelector only ever
// returns "tasks", "all", or "subset", so no `--tools <noun>` list can collide
// with it.
const mcpToolsetTasksBestEffort = "tasks-best-effort"

// buildMCPServer assembles a fully registered MCP server: the curated task
// tools, optionally the generic capabilities bridge (--tools all), and the
// published-papers resources. Extracted from runMCPServe so the stdio path (one
// server per process) and the Streamable-HTTP path (one server PER REQUEST,
// carrying that request's forwarded bearer in ctx.Token) build the exact same
// server from the exact same registration code — mcp_tasks.go / mcp_bridge.go /
// mcp_resources.go are untouched by the transport split.
//
// enumeratePapers selects the resource registration mode: true (stdio) runs the
// full registerPaperResources — read template + a best-effort downstream doc.ls
// enumeration for resources/list; false (HTTP) registers the read TEMPLATE ONLY,
// because this function runs per-request in stateless HTTP mode and an
// enumeration GET per request would hammer the API (charter D18).
//
// Under the default --tools tasks the curated task tools ARE the server, so a
// missing task verb is a returned error (fail fast, decision 10). Under --tools
// all the bridge exposes whatever the manifest DOES carry, so a tasks-less
// instance is served bridge-only after a stderr warning rather than refused — a
// Barkpark with the Tasks plugin off still gets a useful MCP surface.
// registerTaskTools batches every verb Lookup before the first AddTool, so a
// failure leaves NOTHING half-registered on srv; and bridgeShadowedIDs is inert
// when the task verbs are absent (there is no twin to skip) — so continuing is
// safe. out is stderr-only diagnostics (decision 4).
//
// Under the "subset" toolset (--tools <noun,noun>) the server is BRIDGE-ONLY,
// filtered to the named nouns (registerBridgeToolsFiltered): the curated task
// tools are NOT registered, and the bridgeShadowedIDs skip stays active (inert
// for non-task nouns; a `--tools task` whose task verbs are all curated-shadowed
// correctly yields zero). An unknown noun matches nothing → zero tools, the
// honest 0-install surface. This is the connector-scoped Cloud surface (D24
// knob 3, Go half): expose exactly the workspace's connected nouns, nothing else.
func buildMCPServer(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, toolset string, nouns []string, enumeratePapers bool) (*mcp.Server, error) {
	// Instructions ride the initialize result (go-sdk ServerOptions.Instructions
	// → InitializeResult.Instructions), so an MCP-only client is primed with the
	// movement-ledger doctrine without ever reading a doc — the whole point of
	// carrying it here rather than only in AGENTS.md. Same const the onramp teach
	// block renders, so the two can never drift.
	srv := mcp.NewServer(&mcp.Implementation{
		Name:    "barkpark-tasks",
		Title:   "Barkpark Tasks",
		Version: cliVersion,
	}, &mcp.ServerOptions{Instructions: movementLedgerDoctrine})

	// Headless liveness (charter decision 5): tool handlers ride the guard-free
	// execManifestCommand seam, but force g.yes anyway as belt-and-braces — a
	// stdin-reading confirm prompt would hang a server whose stdin is the
	// protocol pipe (stdio) or does not exist (HTTP).
	g.yes = true

	if toolset == "subset" {
		// Bridge-only, filtered to the named nouns — no curated task tools.
		if err := registerBridgeToolsFiltered(srv, g, ctx, m, nouns); err != nil {
			return nil, fmt.Errorf("register bridge tools: %w", err)
		}
		if enumeratePapers {
			registerPaperResources(out, srv, g, ctx, m)
		} else {
			registerPaperResourceTemplateOnly(out, srv, g, ctx, m)
		}
		return srv, nil
	}

	if err := registerTaskTools(srv, g, ctx, m); err != nil {
		if toolset != "all" && toolset != mcpToolsetTasksBestEffort {
			return nil, fmt.Errorf("register task tools: %w", err)
		}
		// stderr only — os.Stdout is the JSON-RPC protocol stream (decision 4).
		if toolset == mcpToolsetTasksBestEffort {
			out.errf("mcp serve: DEGRADED — curated task tools NOT registered (%s): register task tools: %v; --http holds no ambient credential (forward-through, charter D18) so its startup manifest is the ANONYMOUS /v1/capabilities projection, which carries no task noun, and a caller's own bearer cannot restore them because the stateless per-request server is rebuilt from this same startup manifest; serving the chat tools and paper resources anyway instead of exiting 1 — point the server at a manifest that carries the task noun (--manifest / $BARKPARK_MANIFEST, or a Barkpark whose anonymous projection includes task) to get them back", strings.Join(curatedTaskToolNames, ", "), err)
		} else {
			out.errf("mcp serve: curated task tools unavailable (%v) — serving --tools all bridge-only", err)
		}
	}
	if toolset == "all" {
		if err := registerBridgeTools(srv, g, ctx, m); err != nil {
			return nil, fmt.Errorf("register bridge tools: %w", err)
		}
	}

	// The four curated chat session tools (herd charter D74h) ride BOTH tasks
	// and all — this single assembly is what `bp mcp serve` (default tasks) and
	// the Studio loopback (`--tools all`, registered as "barkpark") build, so
	// registering here is what puts them on both surfaces. Hardcoded /v1/chat
	// wrappers, deliberately NOT manifest-backed (chat.* is existence-hidden at
	// write tier — a Lookup would silently skip them on the loopback); infallible,
	// so the batch-first invariant holds. The noun-subset surface above stays
	// bridge-only by design and does not carry them.
	registerChatTools(srv, ctx)

	// Published papers as read-only MCP resources — independent of --tools (the
	// 40-tool Cursor cap is about TOOLS, not resources). Wholly best-effort: on
	// any failure (unreachable API, missing doc verbs) it warns to stderr and
	// degrades — never fatal to startup.
	if enumeratePapers {
		registerPaperResources(out, srv, g, ctx, m)
	} else {
		registerPaperResourceTemplateOnly(out, srv, g, ctx, m)
	}
	return srv, nil
}

// registerPaperResourceTemplateOnly registers ONLY the barkpark://papers/{id}
// read template — no resources/list enumeration. It is the HTTP-mode resource
// surface: buildMCPServer runs per-request there, and registerPaperResources
// would fire a downstream doc.ls GET at every registration (mcp_resources.go),
// so the HTTP path registers the lazy read alone; any published paper still
// reads by URI, authorized by the request's own forwarded bearer.
//
// The template's fields and read handler deliberately mirror
// registerPaperResources (mcp_resources.go) — kept as a sibling here rather
// than a parameter on it so the resources file stays transport-agnostic and
// byte-unchanged (charter D18: the transport split edits mcp_serve.go only).
func registerPaperResourceTemplateOnly(out *writer, srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest) {
	getCmd, ok := m.Tree().Lookup("doc", "get")
	if !ok {
		// No doc.get → no way to back a paper read. Same degrade as the full path.
		out.errf("mcp serve: paper resources disabled — manifest has no doc.get verb")
		return
	}
	srv.AddResourceTemplate(&mcp.ResourceTemplate{
		Name:        "paper",
		Title:       "Barkpark paper",
		Description: "A published Barkpark paper (Bulldocs document) as raw JSON. Read barkpark://papers/<id> for any published paper by its id — including papers created after the server started, which resources/list may not yet enumerate.",
		MIMEType:    paperResourceMIME,
		URITemplate: paperResourceTemplate,
	}, func(_ context.Context, req *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
		uri := ""
		if req != nil && req.Params != nil {
			uri = req.Params.URI
		}
		id := paperIDFromURI(uri)
		if id == "" {
			return nil, mcp.ResourceNotFoundError(uri)
		}
		return readPaperResource(g, ctx, m, *getCmd, uri, id)
	})
}

// runMCPServeHTTP serves the MCP protocol over Streamable HTTP on addr until
// signalled. Stateless mode: the SDK calls getServer for every request, and the
// per-request server is built around THAT request's Authorization bearer — the
// forward-through design (charter D18). Returns the exit code.
func runMCPServeHTTP(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, toolset string, nouns []string, addr string) int {
	handler, err := newMCPHTTPHandler(out, g, ctx, m, toolset, nouns)
	if err != nil {
		out.userErr("mcp serve: %v", err)
		return exitGeneric
	}

	// Bind before announcing, so a taken port / bad addr fails fast and clear.
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		out.userErr("mcp serve: listen %s: %v", addr, err)
		return exitGeneric
	}

	// stderr for diagnostics, same discipline as stdio mode (decision 4) — and
	// never a token byte: the process holds no credential to leak.
	out.errf("bp mcp serve: %s tools over Streamable HTTP on %s (server %s, forward-through bearer) — Ctrl-C to stop", toolsetLabel(toolset, nouns), ln.Addr(), ctx.Server)

	httpSrv := newMCPHTTPServer(handler, newMCPRateLimiterFromEnv(out.errf))
	runCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() { errCh <- httpSrv.Serve(ln) }()

	select {
	case <-runCtx.Done():
		// Signalled: drain in-flight requests briefly, then exit clean.
		shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutCtx)
		return exitOK
	case err := <-errCh:
		if err != nil && err != http.ErrServerClosed {
			out.userErr("mcp serve: %v", err)
			return exitGeneric
		}
		return exitOK
	}
}

// Timeouts and header cap for the `--http` listener. The endpoint is
// UNAUTHENTICATED at the transport layer by design (forward-through bearer,
// charter D18): every TCP peer that reaches the port gets a connection before
// any credential is looked at, so slowloris / slow-body is an availability
// hazard with no auth gate in front of it. A bare &http.Server{Handler: …}
// applies NO deadline at all and lets a dribbling client hold a connection
// open forever.
const (
	// mcpHTTPReadHeaderTimeout bounds the request LINE + headers. This is the
	// slowloris clamp: a peer that dribbles headers is closed here.
	mcpHTTPReadHeaderTimeout = 10 * time.Second
	// mcpHTTPReadTimeout bounds the whole request read (headers + body). MCP
	// JSON-RPC bodies are small; a body that takes longer than this is a
	// slow-read attack, not a client. It does NOT bound the response: Go arms
	// this deadline for the request read only, so a long-running tool call whose
	// SSE response outlives it still completes.
	mcpHTTPReadTimeout = 30 * time.Second
	// mcpHTTPIdleTimeout bounds an idle keep-alive connection between requests,
	// so a flood cannot park sockets for free.
	mcpHTTPIdleTimeout = 120 * time.Second
	// mcpHTTPMaxHeaderBytes caps header size well under Go's 1 MiB default —
	// this endpoint's largest legitimate header is an Authorization bearer.
	mcpHTTPMaxHeaderBytes = 64 << 10
)

// newMCPHTTPServer wraps the Streamable-HTTP handler in an http.Server with
// those deadlines armed, behind the per-client-IP token bucket (limiter may be
// nil — a nil limiter is a pass-through, which is what BARKPARK_MCP_RATE=0
// produces). The deadlines bound per-CONNECTION time; the bucket is the only
// thing here that bounds request RATE (mcp_ratelimit.go).
//
// WriteTimeout is DELIBERATELY LEFT ZERO. In stateless mode the SDK answers a
// POST /mcp with Content-Type text/event-stream (streamable.go: jsonResponse is
// off unless StreamableHTTPOptions.JSONResponse is set), so the response is an
// SSE stream whose length is the duration of the downstream Barkpark call.
// Go arms WriteTimeout as an absolute deadline once the headers are read, so a
// non-zero value TRUNCATES a slow tool call mid-stream — measured: a 1.5 s SSE
// response under WriteTimeout=500 ms delivered 28 of 70 bytes and the client
// read "unexpected EOF". The response side is instead bounded per request by
// the caller's own client timeout and by the downstream HTTP client's, and a
// stalled peer's socket is reclaimed by IdleTimeout once the stream ends.
// (GET /mcp — the standalone SSE stream — is 405 in stateless mode, so there is
// no unbounded server-initiated stream to worry about.)
func newMCPHTTPServer(handler http.Handler, limiter *mcpRateLimiter) *http.Server {
	return &http.Server{
		Handler:           limiter.middleware(handler),
		ReadHeaderTimeout: mcpHTTPReadHeaderTimeout,
		ReadTimeout:       mcpHTTPReadTimeout,
		IdleTimeout:       mcpHTTPIdleTimeout,
		MaxHeaderBytes:    mcpHTTPMaxHeaderBytes,
	}
}

// newMCPHTTPHandler builds the Streamable-HTTP handler for `bp mcp serve
// --http`. Forward-through bearer (charter D18):
//
//   - The base context's Token is DISCARDED — the server process never uses an
//     ambient credential (env, saved config, --token) on behalf of a remote
//     caller. The only key is the one the request itself carries.
//   - Per request, getServer copies the base manifest.Context, sets ctx.Token
//     from the request's `Authorization: Bearer` (empty when absent/malformed),
//     and registers the same tools/resources stdio serves. A tool call then
//     rides the normal dispatch seam, so downstream Auth.verify_token/1 is the
//     single choke point: no/bad bearer → the ordinary 401 envelope back as the
//     tool result (fail closed), zero side effects server-side.
//   - Stateless: no Mcp-Session-Id bookkeeping, so getServer runs per request
//     and one request's token can never bleed into another's.
//   - DisableLocalhostProtection: the deploy shape is a loopback bind behind a
//     reverse proxy (charter D19), where inbound Host headers are the public
//     hostname — the SDK's DNS-rebind guard would 403 exactly that. The proxy
//     terminates TLS and owns origin policy.
//
// No RequireBearerToken pre-verify in v1 (charter D18): Barkpark has no
// bearer-gated verify-only route, and the SDK middleware rejects TokenInfo
// without an expiry while Barkpark tokens legitimately never expire.
func newMCPHTTPHandler(out *writer, g globals, base manifest.Context, m *manifest.Manifest, toolset string, nouns []string) (http.Handler, error) {
	// No ambient credential, ever: scrub the process token from the base context
	// (belt-and-braces — getServer overwrites Token per request regardless).
	base.Token = ""

	// A missing task noun must NOT take the endpoint down. The startup manifest
	// here is fetched with no credential, so on a stock Barkpark it is the
	// anonymous projection (doc/media/search/auth — no task), and fail-fast turns
	// that into a systemd crash loop serving 503 (see mcpToolsetTasksBestEffort).
	if toolset == "tasks" {
		toolset = mcpToolsetTasksBestEffort
	}

	// Still fail fast on anything the manifest genuinely cannot back (a bad
	// --tools all bridge, a broken subset): refuse to come up rather than 500
	// every call — and surface any degrade/bridge-only warning ONCE, here,
	// instead of per request.
	if _, err := buildMCPServer(out, g, base, m, toolset, nouns, false); err != nil {
		return nil, err
	}

	// Per-request rebuilds are validated-by-construction (same manifest, same
	// toolset), so their diagnostics would only repeat the startup line — send
	// them to a discard writer to keep stderr per-session quiet.
	quiet := newWriter(io.Discard, io.Discard)

	getServer := func(req *http.Request) *mcp.Server {
		ctx := base
		ctx.Token = bearerFromRequest(req)
		srv, err := buildMCPServer(quiet, g, ctx, m, toolset, nouns, false)
		if err != nil {
			return nil // cannot happen after the startup probe; SDK answers 400
		}
		return srv
	}

	return mcp.NewStreamableHTTPHandler(getServer, &mcp.StreamableHTTPOptions{
		Stateless:                  true,
		DisableLocalhostProtection: true,
	}), nil
}

// bearerFromRequest extracts the bearer credential from a request's
// Authorization header. Anything that is not a well-formed `Bearer <token>`
// (missing header, other scheme, empty credential) returns "" — which the
// dispatch seam turns into a request with NO Authorization header downstream
// (authHeaders, run.go), i.e. a guaranteed 401: fail closed, never fall back to
// any ambient token.
func bearerFromRequest(req *http.Request) string {
	h := req.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) > len(prefix) && strings.EqualFold(h[:len(prefix)], prefix) {
		return strings.TrimSpace(h[len(prefix):])
	}
	return ""
}

// parseMCPServeArgs reads the `--tools` selector (default "tasks") and the
// `--http <addr>` transport switch (default "" = stdio) from the command tail.
// It accepts both `--flag val` and `--flag=val` forms. Any other flag/positional
// is a usage error so a typo is not silently ignored.
//
// The `--tools` value is one of two reserved toolset words (tasks|all) or a
// comma-separated NOUN subset (e.g. "github,linear") → the "subset" toolset,
// whose nouns are returned in `nouns`; the reserved words return `nouns == nil`.
func parseMCPServeArgs(tail []string) (toolset string, nouns []string, httpAddr string, err error) {
	toolset = "tasks"
	for i := 0; i < len(tail); i++ {
		a := tail[i]
		key, val, hasInline := a, "", false
		if eq := strings.IndexByte(a, '='); eq >= 0 && strings.HasPrefix(a, "--") {
			key, val, hasInline = a[:eq], a[eq+1:], true
		}
		switch key {
		case "--tools":
			if !hasInline {
				if i+1 >= len(tail) {
					return "", nil, "", fmt.Errorf("flag --tools needs a value (tasks|all|<noun>[,<noun>…])")
				}
				val = tail[i+1]
				i++
			}
			ts, ns, perr := parseToolsSelector(val)
			if perr != nil {
				return "", nil, "", perr
			}
			toolset, nouns = ts, ns
		case "--http":
			if !hasInline {
				if i+1 >= len(tail) {
					return "", nil, "", fmt.Errorf("flag --http needs a listen address (e.g. 127.0.0.1:4010)")
				}
				val = tail[i+1]
				i++
			}
			if strings.TrimSpace(val) == "" {
				return "", nil, "", fmt.Errorf("flag --http needs a listen address (e.g. 127.0.0.1:4010)")
			}
			httpAddr = val
		default:
			return "", nil, "", fmt.Errorf("unknown argument %q (mcp serve accepts --tools tasks|all|<noun>[,<noun>…] and --http <addr>)", a)
		}
	}
	return toolset, nouns, httpAddr, nil
}

// parseToolsSelector interprets a `--tools` value. "tasks" and "all" are the two
// reserved toolset words (nouns == nil). Anything else is a comma-separated list
// of manifest nouns → the "subset" toolset, which serves ONLY those nouns'
// commands as generic bridge tools (no curated task tools; buildMCPServer).
//
// Validation is purely SYNTACTIC: an empty comma token is rejected and the
// reserved words tasks/all may not be MIXED into a noun list, but a noun's
// existence is NOT checked here — the manifest loads only after this parse
// (runMCPServe), and an unknown noun degrades to zero tools (the honest
// 0-install behaviour), never a usage error. (github/linear are Catalog
// connector providers, not bp manifest nouns; this flag filters whatever nouns
// the target manifest actually declares — it is not itself the transport by
// which a cloud agent reaches those services.)
func parseToolsSelector(val string) (toolset string, nouns []string, err error) {
	if strings.TrimSpace(val) == "" {
		return "", nil, fmt.Errorf("flag --tools needs a value (tasks|all|<noun>[,<noun>…])")
	}
	switch val {
	case "tasks", "all":
		return val, nil, nil
	}
	parts := strings.Split(val, ",")
	ns := make([]string, 0, len(parts))
	for _, p := range parts {
		if p == "" {
			return "", nil, fmt.Errorf("invalid --tools %q: empty noun between commas", val)
		}
		switch p {
		case "tasks", "all":
			return "", nil, fmt.Errorf("invalid --tools %q: reserved word %q cannot appear in a noun list", val, p)
		}
		ns = append(ns, p)
	}
	return "subset", ns, nil
}

// toolsetLabel renders the toolset for a stderr announce line. The reserved
// words print verbatim ("tasks"/"all"); a subset prints its noun list so the
// operator sees exactly which nouns the server was scoped to.
func toolsetLabel(toolset string, nouns []string) string {
	if toolset == "subset" {
		return "connector-subset[" + strings.Join(nouns, ",") + "]"
	}
	if toolset == mcpToolsetTasksBestEffort {
		// The --http best-effort variant of "tasks" is an internal registration
		// mode, not a selector the operator typed — print what they asked for.
		return "tasks"
	}
	return toolset
}

func printMCPServeHelp(out *writer) {
	out.outf(`usage: bp mcp serve [--tools tasks|all|<noun>[,<noun>…]] [--http <addr>]
  Run a Model-Context-Protocol server exposing Barkpark to MCP clients
  (Cursor, Claude Desktop, any MCP host). Path B for task tracking — the
  MCP-native counterpart to the shell-based .cursor/rules/barkpark-tasks.mdc
  card. Default transport is stdio (JSON-RPC over stdin/stdout; run it as a
  subprocess from your MCP client config, never interactively).

flags:
  --tools <sel>       Which tools to expose. "tasks" (default) is the curated
                      eight — task_ready, task_next, task_show, task_close,
                      task_create, task_prime, task_stamp, task_pulse — plus
                      the four chat session tools (chat_spawn_session,
                      chat_send, chat_read_tail, chat_wait_for_state). "all"
                      additionally bridges every other bp capability into a
                      generic tool. A comma-separated NOUN list (e.g.
                      "media,doc") serves ONLY those nouns' commands as generic
                      bridge tools — no curated task tools; an unknown noun
                      simply exposes nothing. This scopes the surface to a
                      chosen subset of the target manifest's nouns.
  --http <addr>       Serve Streamable HTTP on <addr> (e.g. 127.0.0.1:4010)
                      instead of stdio, for REMOTE MCP clients. Forward-through
                      auth: each request's "Authorization: Bearer <token>" is
                      forwarded to the Barkpark API as that request's
                      credential — the process itself holds NO token, and a
                      missing or invalid bearer fails closed with the API's own
                      401. Bind loopback behind a TLS reverse proxy; never
                      expose the plain listener publicly. Because it holds no
                      credential, its startup manifest is the ANONYMOUS
                      /v1/capabilities projection — if that cannot back the
                      curated task tools, --http logs ONE loud line and serves
                      what it can (chat tools, paper resources) rather than
                      exiting; stdio still fails fast.

--http rate limit (env, in-process — Caddy's rate_limit is a third-party
module the stock fleet caddy does not carry, so the clamp lives here):
  BARKPARK_MCP_RATE=<req/s>       Sustained per-client-IP rate. Default 5.
                                  0 DISABLES the limiter entirely.
  BARKPARK_MCP_BURST=<requests>   Bucket depth. Default 20.
  BARKPARK_MCP_TRUSTED_PROXIES=<cidr,…>
                                  Peers whose X-Forwarded-For is believed.
                                  Default 127.0.0.0/8,::1/128 (the loopback
                                  deploy shape). From a trusted peer the LAST
                                  XFF hop — the one the proxy appended — is the
                                  key; from any other peer the header is
                                  ignored and the TCP peer is the key, so no
                                  client can mint buckets with a header it
                                  writes itself. Over-limit requests get 429
                                  with Retry-After; an SSE stream already
                                  streaming is never cut off.

Published papers are also exposed as read-only MCP resources
(barkpark://papers/<id>), independent of --tools. In --http mode papers read
lazily by URI (barkpark://papers/{id} template); resources/list enumeration is
stdio-only.

The server resolves its target Barkpark the same way every other bp command
does (-s / --token / BARKPARK_* env / saved config). Register it in Cursor via
~/.cursor/mcp.json (global) or .cursor/mcp.json (per-project):

  {
    "mcpServers": {
      "barkpark": {
        "command": "bp",
        "args": ["mcp", "serve"],
        "env": { "BARKPARK_API_URL": "https://your.barkpark", "BARKPARK_API_TOKEN": "…" }
      }
    }
  }`)
}
