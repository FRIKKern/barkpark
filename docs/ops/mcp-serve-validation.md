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

- `internal/cli/mcp_stdio_smoke_test.go:212` (`TestMCPServeStdioSmoke`) execs the
  **built binary** over real stdio, drives `initialize → notifications/initialized
  → tools/list`, and asserts **byte-pure ndjson JSON-RPC on stdout** plus exactly
  the curated tool set. But its manifest is the committed fixture
  (`docs/cli/fixtures/full-manifest.json`) and `BARKPARK_API_URL=http://127.0.0.1:0`
  — a stub it never dials; the session **stops at `tools/list`** (which needs no
  API). `TestMCPStdoutBytePurityHarness:331` proves that tripwire is non-vacuous.
- `internal/cli/mcp_serve_test.go:128` (`TestMCPServeToolsLiveOverInMemory`) drives
  `tools/call task_show` / `task_next` / `task_close` over the SDK's in-memory
  transport — but against an `httptest` stub HTTP server (`:64`), asserting the
  POSTed close body shape, not a real round-trip.
- `internal/cli/mcp_bridge_test.go:259` (`TestBridgeRoundTrip_ArgPlacement`) proves
  a `tools/call` reaches the CLI's arg-placement path — again vs `httptest` (`:223`).

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
