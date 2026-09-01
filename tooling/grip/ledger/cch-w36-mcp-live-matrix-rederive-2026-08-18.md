<!-- doc-tier: cold | canonical-for: cch-w36-mcp-live-matrix-rederive | budget: 900tok -->

# Wave 36 — authoritative public MCP live matrix (re-derivation recipe)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Ground truth the wave rests on. All L1 against `https://guerrilla.barkpark.cloud`, 2026-08-18. Re-run any row to re-derive.

## Route code matrix

```
for p in /mcp /connectors/mcp /connectors/health; do curl -s -o /dev/null -w "$p %{http_code}\n" https://guerrilla.barkpark.cloud$p; done
curl -s -o /dev/null -w "GET /mcp %{http_code}\n" https://guerrilla.barkpark.cloud/mcp
```

Expected: `/mcp 405` · `/connectors/mcp 404` · `/connectors/health 200` · `GET /mcp 405`.

`/connectors/mcp 404` is **correct-by-design** — MCP has its OWN Caddy route (`/mcp` → :4010 barkpark-mcp.service), separate from `/connectors` (→ :4020 Node bridge). No such path was ever meant to exist; the wave-35 surveyor conflated bridge port with MCP path.

## initialize handshake (through Caddy)

```
curl -s -D - -o /dev/null -X POST https://guerrilla.barkpark.cloud/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"0"}}}'
```

Expected: `HTTP/2 200`, header `via: 1.1 Caddy`, header `mcp-session-id: <ID>`, SSE body
`result.serverInfo.name:"barkpark-tasks"` (title "Barkpark Tasks", version "dev").

## tools/call fail-closed (assert on isError/code, NOT HTTP status — HTTP is 200)

Get a fresh `$SID` from the initialize response header, then:

```
# no bearer
curl -s -X POST .../mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_ready","arguments":{}}}' | grep '^data:'
# bogus bearer
curl -s -X POST .../mcp -H 'Authorization: Bearer bogus_xyz' ... (same body, id:4)
```

Both expected: `result.isError:true`, nested `content[0].text` JSON = `{"error":{"code":"unauthorized","message":"missing or invalid token", ...}}`. Forwarded-bearer design (internal/cli/mcp_serve.go): shim holds no ambient credential.

## Charter drift correction (Decide → D272 annotation)

Charter D272 (line 1272) says: `` `/mcp` 405 is Phoenix :4000, not the bridge. `` — **WRONG**. The initialize handshake returns `serverInfo.name:"barkpark-tasks"`, i.e. the barkpark-mcp shim (loopback :4010), NOT Phoenix :4000. `/mcp` is a live MCP server through Caddy, not a Phoenix 405. Correct in the D272 annotation; leave the cold ledger.

## Unproven leg (credential-gated, out of this wave)

Cross-tenant (A-reads-B → 404) needs two real distinct dataset-scoped tokens = same human-held block as the live crown; lives at API `Auth.verify_token`, not the MCP shim.
