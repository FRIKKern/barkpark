<!-- doc-tier: human | canonical-for: mcp-serve-validation | budget: 2000tok -->

# `bp mcp serve` — live-server validation

## Purpose

Prove the one thing no unit test can: that `bp mcp serve` is a **real MCP
server** that a real MCP client can drive end-to-end over stdio, against the
**live** guerrilla content API — real network, real capabilities manifest, real
auth, real task JSON riding back through the dispatch seam. This is the honest
protocol equivalent of a Cursor screenshot: a Cursor GUI tool-call is mediated
by Cursor's own agent LLM (a demo, not a deterministic proof), so the primary
artifact here is an **exec'd JSON-RPC transcript**, not a driven GUI.

## What the existing gates already prove (don't re-claim it)

Wave 1 shipped strong protocol coverage — but all of it is hermetic, against a
committed fixture manifest and a stub URL that never dials the network:

- `TestMCPServeStdioSmoke` (`internal/cli/mcp_stdio_smoke_test.go`) execs the
  **built binary** over real stdio, drives `initialize → notifications/initialized
  → tools/list`, and asserts **byte-pure ndjson JSON-RPC on stdout** plus exactly
  the curated tool set. But its manifest is the committed fixture
  (`docs/cli/fixtures/full-manifest.json`) and `BARKPARK_API_URL=http://127.0.0.1:0`
  — a stub it never dials; the session **stops at `tools/list`** (which needs no
  API). `TestMCPStdoutBytePurityHarness` (same file) proves that tripwire is
  non-vacuous.
- `TestMCPServeToolsLiveOverInMemory` (`internal/cli/mcp_serve_test.go`) drives
  `tools/call task_show` / `task_next` / `task_close` over the SDK's in-memory
  transport — but against an `httptest` stub HTTP server it starts itself,
  asserting the POSTed close body shape, not a real round-trip.
- `TestBridgeRoundTrip_ArgPlacement` (`internal/cli/mcp_bridge_test.go`) proves
  a `tools/call` reaches the CLI's arg-placement path — again vs its own
  `httptest` stub.

So byte-purity, the curated `tools/list`, clean EOF exit, and in-memory
`tools/call` shape are **already proven**. This doc adds only the missing rung:
a **real MCP session over stdio against the real network server**.

## Environment

| | |
|---|---|
| Server | `https://guerrilla.barkpark.cloud` (live content API) |
| Binary | `dist/bp`, `cli_version=dev`, commit `54f1f8a8`, built 2026-07-09 |
| Build | `make cli-build` from this worktree |
| Auth | admin token from `~/.config/barkpark/config.json` (`known_servers[guerrilla]`), passed via `BARKPARK_API_TOKEN`. It rides the HTTP `Authorization` header, **never a JSON-RPC frame** — so no token byte appears in the transcript; the harness redacts it regardless |
| Toolset | default (`tasks`) — the catalog wave had not merged, so **5** curated tools |
| Driver | a small Python harness that spawns `bp mcp serve` as a subprocess, writes newline-delimited JSON-RPC to its stdin, reads frames from its stdout |

The token is admin-tier — it *can* write. Discipline (not permission) keeps this
run **strictly read-only**: only `task_ready` and `task_show` (both `writes:false`
GETs) are called. No `task_next` / `task_close` / `task_create` anywhere — those
mutate the board.

## Transcript (redacted, verbatim frames)

`-->` is a frame written to the server's stdin; `<--` is a frame read from its
stdout. Long result bodies are truncated at `…`; nothing else is edited.

```jsonc
--> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bp-mcp-validation","version":"1.0"}}}
<-- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"logging":{},"tools":{"listChanged":true}},"protocolVersion":"2025-06-18","serverInfo":{"name":"barkpark-tasks","title":"Barkpark Tasks","version":"dev"}}}

--> {"jsonrpc":"2.0","method":"notifications/initialized"}

--> {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
<-- {"jsonrpc":"2.0","id":2,"result":{"tools":[ …5 tools: task_close, task_create, task_next, task_ready, task_show — each carrying the claim-first/epoch-CAS doctrine in its description… ]}}

// READ-ONLY GET against the LIVE board — real ready-queue head returned:
--> {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_ready","arguments":{}}}
<-- {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"ok\":true,\"docs\":[{\"id\":\"6a334ee7-…\",\"priority\":0,\"status\":\"draft\",\"type\":\"task\",\"title\":\"Sheets: Excel/Google-Sheets parity\",\"kind\":\"task\", …}]}"}]}}

// READ-ONLY GET for a known id — real published task JSON back through the seam:
--> {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"task_show","arguments":{"doc_id":"bp-mcp-serve-epic"}}}
<-- {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"ok\":true,\"doc\":{\"id\":\"f3a2efb1-…\",\"priority\":1,\"status\":\"published\",\"title\":\"bp mcp serve — MCP server for Barkpark Tasks (Cursor path B)\", …}}"}]}}
```

Server diagnostics stayed on **stderr** (never stdout — the protocol pipe):

```
bp mcp serve: tasks tools over stdio (server https://guerrilla.barkpark.cloud) — Ctrl-C to stop
bp: mcp serve: server is closing: EOF
```

On stdin close the process exited **0** (clean EOF shutdown). The harness read
**4 stdout lines, 0 non-JSON — byte-pure** over the real network.

An arg-name typo is also caught server-side, not silently swallowed:
`task_show` with `{"id":"…"}` (wrong key) returned
`{"content":[{"type":"text","text":"doc_id is required"}],"isError":true}` —
the real `doc_id` param is required, corrected above.

## What this proves (the delta)

The rung the hermetic gates left open is now closed against production:

1. **Real client ↔ real server, end-to-end.** A genuine MCP `initialize`
   handshake (protocol `2025-06-18`), `serverInfo` = `barkpark-tasks`, then a live
   `tools/list` and two `tools/call`s — all over stdio to a subprocess talking to
   `https://guerrilla.barkpark.cloud`.
2. **The manifest is the tool catalog, for real.** Tools came from the LIVE
   `GET /v1/capabilities`, not the fixture — **5** curated tools observed
   (`task_ready/next/show/close/create`), matching `tasks` default (the catalog
   wave that adds a sixth had not merged into this branch).
3. **Real task JSON rides back through the seam.** `task_ready` returned the live
   ready-queue head; `task_show` returned the real published `bp-mcp-serve-epic`
   document — the same bytes `bp task …` would fetch, wrapped as one MCP text
   content block (charter decision 9), no re-rendering.
4. **Stdout discipline holds over the network too.** 4 stdout lines, all valid
   JSON-RPC; every diagnostic (startup line, EOF close) went to stderr. The
   smoke test proves this against the fixture; this proves it against live auth
   and live payloads.

## How to re-run

```bash
make cli-build                       # dist/bp for this host
# TOKEN from ~/.config/barkpark/config.json known_servers[guerrilla] — never echo it
printf '%s\n%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_ready","arguments":{}}}' \
  | BARKPARK_API_URL=https://guerrilla.barkpark.cloud BARKPARK_API_TOKEN="$TOKEN" \
    ./dist/bp mcp serve
```

Note: feed the frames **interactively** (write-then-read per request, keeping
stdin open) — a single `printf | bp` that closes stdin immediately can EOF the
stdio transport before it replies. The captured run used a subprocess driver
that writes one frame, reads its response, then sends the next. Stay read-only:
`task_ready` / `task_show` only — never `task_next` / `task_close` /
`task_create` against a real board.

## HTTP transport (2026-07-11, `ve-w2-remote-mcp-bearer`)

`bp mcp serve --http <addr>` adds a Streamable-HTTP (stateless) transport with
**forward-through bearer** auth: the per-request `Authorization: Bearer` is the
only credential — the process holds none, and downstream token verification is
the single choke point (fail closed with the API's 401 envelope).

Hermetic coverage lands with the slice (`internal/cli/mcp_http_test.go`), all
driving a **real MCP client over real HTTP** against the production handler:

- `TestMCPHTTPForwardThroughBearer` — the client's bearer reaches the backing
  API verbatim, per request; the curated eight tools list identically to stdio;
  zero bytes on stdout.
- `TestMCPHTTPDenyPathsFailClosed` — missing AND bogus bearer each return the
  downstream 401 envelope as `isError`, with zero write side effects, and the
  ambient token (base context + `BARKPARK_API_TOKEN` env) provably never rides
  a downstream request.
- `TestMCPHTTPPaperResourcesTemplateOnly` — HTTP mode registers only the
  `barkpark://papers/{id}` read template; the enumeration GET fires zero times.

Owed at the time of the transport slice, since paid: the live remote smoke
against `https://guerrilla.barkpark.cloud/mcp` — the close criterion of the
deploy slice (`ve-w2-mcp-deploy`), which owns the systemd unit + Caddy route —
is recorded below (see "Live smoke — guerrilla remote, 2026-07-11").

## Remote endpoint (Streamable HTTP) — deploy shape + smoke recipe

The remote path (viable-everywhere charter D18/D19) exposes the SAME server at
`https://guerrilla.barkpark.cloud/mcp`: `deploy/instance-deploy.sh` arms an
idempotent `/mcp` Caddy route → `127.0.0.1:4010` where
`deploy/systemd/barkpark-mcp.service` runs `bp mcp serve --http`. The unit is
install-GUARDED (enabled only once the built binary advertises `--http`) and
holds **no API token** — forward-through: each caller's own
`Authorization: Bearer` rides through to the downstream API, so a missing or
bogus bearer fails closed with the downstream 401.

Honest scope (charter D20): this endpoint does **not** self-serve-unlock
Claude.ai — bearer/header auth for Claude.ai custom connectors is still
invite-gated. Live bearer targets today: ChatGPT Developer Mode (Plus/Pro
read), Perplexity (Pro+), Grok (SuperGrok), Mistral Vibe (all plans).

Live smoke recipe, to be run once both the transport slice and the deploy slice
are on the box. **This has been run** — the redacted transcript is recorded
below under "Live smoke — guerrilla remote, 2026-07-11".

```bash
# TOKEN from ~/.config/barkpark/config.json known_servers[guerrilla] — never echo it
claude mcp add --transport http bp-remote https://guerrilla.barkpark.cloud/mcp \
  --header "Authorization: Bearer $TOKEN"
# drive task_ready (read-only), then the deny path:
#   same call with a bogus bearer MUST fail closed — a tool-result error
#   (isError:true, code unauthorized) inside HTTP 200, never a successful result
```

## Live smoke — guerrilla remote, 2026-07-11 (transcript no longer pending)

Endpoint: `https://guerrilla.barkpark.cloud/mcp` (Streamable-HTTP). Binary HEAD
`cbef2af2`. Admin token from `~/.config/barkpark/config.json`
`known_servers[guerrilla]`, passed as `Authorization: Bearer <REDACTED>`; no
token byte appears below.

- **initialize** (authenticated) → HTTP 200:
  `{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"logging":{},"resources":{"listChanged":true},"tools":{"listChanged":true}},"protocolVersion":"2025-06-18","serverInfo":{"name":"barkpark-tasks","title":"Barkpark Tasks","version":"dev"}}}`
- **tools/list** (authenticated) → HTTP 200, **8 tools**: `task_close`,
  `task_create`, `task_next`, `task_prime`, `task_pulse`, `task_ready`,
  `task_show`, `task_stamp`.
- **tools/call `task_ready` `{"limit":2}`** (authenticated) → HTTP 200, result
  (NOT isError), real task JSON:
  `{"ok":true,"docs":[{"doc_id":"task-96a908af98698118",…},{"doc_id":"isu-reconcile-epic-close",…}]}`
- **DENY PATH** — the same `tools/call` with no bearer AND with a bogus bearer →
  HTTP 200, `isError:true`, no data:
  `{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"error\":{\"code\":\"unauthorized\",\"message\":\"missing or invalid token\",…}}"}],"isError":true}}`

The transport answers HTTP 200; the refusal is a JSON-RPC tool-result error
(`isError:true`, code `unauthorized`), not an HTTP 401. The server fails CLOSED —
no task data crosses without a valid dataset-scoped token. This smoke is the
close criterion of task `ve-w2-mcp-deploy`, which recorded its own live smoke
green 2026-07-11 ~14:32Z.

## Post-catalog re-run (2026-07-09, reviewer, wave-2 integrated)

Re-driven against live guerrilla with the full wave-2 branch (catalog +
resources merged): `tools/list` now returns **6** curated tools (`task_prime`
added) with honest annotations (`task_prime` `readOnlyHint:true`, `task_close`
`destructiveHint:true`); `resources/list` returned **65** published papers
(`barkpark://papers/<id>`, heading-derived titles), `resources/templates/list`
the `{id}` template, and a `resources/read` round-tripped a real 24.8 KB paper
verbatim. `task_ready` live, stdout byte-pure, exit 0 on stdin close.
