<!-- doc-tier: human | canonical-for: remote-agent-onramp | budget: 1600tok -->
# Barkpark for remote agents — ChatGPT & Claude.ai

These two surfaces run in someone else's cloud, so they cannot shell out to a
local `bp`. The onramp is different for each, and honest about what ships
today: **ChatGPT has a real, zero-code path; Claude.ai does not yet.** The
overview for CLI-capable agents (Claude Code, Codex, Cursor) lives in
`docs/setup/AGENT-ONRAMPS.md`.

Both paths need a **publicly reachable hosted instance** (a local
`http://localhost:4000` Barkpark can't be reached from OpenAI or Anthropic
infra) and a **scoped bearer token** — never an admin token ([Token
scoping](#token-scoping)).

## ChatGPT — Custom GPT Actions (works today)

Barkpark publishes its whole `/v1` surface as an **OpenAPI 3.1** descriptor at
a public, token-free URL:

```
GET https://<instance>/v1/openapi.json
```

A **Custom GPT Action** imported from that URL turns every route — schema, doc,
task, and paper CRUD — into callable tools with **zero code**. Actions call
server-to-server from OpenAI's infra, so Barkpark's missing browser CORS is
irrelevant here.

Steps:

1. ChatGPT → **Create a GPT** → **Configure** → **Create new action**.
2. **Import from URL**: `https://<instance>/v1/openapi.json`.
3. **Authentication** → **API Key** → **Auth Type: Bearer** → paste a scoped
   token.
4. **Test** an operation. To prove the round trip, create a task — a task is a
   `type:"task"` document, so the GPT calls the mutate operation:

   ```
   POST /v1/data/mutate/production
   {"mutations":[
     {"create":{"_type":"task","_id":"hello-remote","title":"Filed from ChatGPT",
                "kind":"task","lifecycle_status":"open","priority":2}},
     {"publish":{"id":"hello-remote","type":"task"}}
   ]}
   ```

   A `200` carrying a `transactionId` back means the Action is live. Ask the
   GPT plainly: *"create a task titled …"* and it drives the same call.

Caveats, stated honestly:

- **Public instance required.** For a local-only Barkpark there is no reachable
  URL — the fallback is pasting the [curl recipes](#claudeai-manual-http)
  below into the GPT's instructions as literal text for the user to run.
- **Loose typing.** Request/response bodies are deliberately permissive
  (`Document` is `additionalProperties: true`), so the GPT gets thin
  field-level hints — spell out the fields you want in the prompt.
- **MCP vs Actions.** ChatGPT's native MCP **connectors** are beta-gated to
  Business/Enterprise/Edu. **Actions are the universal path** and need none of
  that.

## Claude.ai — the honest story

**There is no Barkpark connector for Claude.ai today, and this repo does not
ship one.** Claude.ai custom connectors are **remote-MCP only**: a public
Streamable HTTP (SSE) endpoint, plus OAuth 2.1 / PKCE for protected servers.
The shipped `bp mcp serve` is a **stdio** MCP server — it cannot be registered
as a Claude.ai connector, and the `bp-mcp-serve-epic` will not build a remote
one.

A hosted remote MCP endpoint (Phoenix-side Streamable HTTP + bearer/OAuth) is
filed as **net-new** backlog work under `bp task ao-backlog-remote-mcp` —
deliberately **not** a `bp-mcp-serve-epic` follow-on. Until it lands, use the
manual HTTP path.

<a id="claudeai-manual-http"></a>
### Manual path — direct HTTP with a scoped token

Every create move is a plain HTTPS call against a hosted instance. Set once:

```bash
export BP=https://<instance>
export TOK=<your-scoped-token>
```

**Learn the whole API** (every noun, verb, and route in one call):

```bash
curl -s $BP/v1/capabilities -H "Authorization: Bearer $TOK"
```

**Create a schema** (needs an admin-scoped token):

```bash
curl -s $BP/v1/schemas/production -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"name":"note","title":"Note","fields":[{"name":"title","type":"string"}]}'
```

**Create + publish a doc** (one atomic batch; swap `_type` to `note`, `task`,
`paper`, or any schema type):

```bash
curl -s $BP/v1/data/mutate/production -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"mutations":[
        {"create":{"_type":"note","_id":"first","title":"First note"}},
        {"publish":{"id":"first","type":"note"}}]}'
```

**Create a task** — same mutate endpoint, `_type:"task"` plus the task fields:

```bash
curl -s $BP/v1/data/mutate/production -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"mutations":[
        {"create":{"_type":"task","_id":"triage","title":"Triage inbox",
                   "kind":"task","lifecycle_status":"open","priority":1}},
        {"publish":{"id":"triage","type":"task"}}]}'
```

**Create a paper** — papers are `type:"paper"` documents; ingest one through
the Bulldocs route. The body carries `slug` + `blocks` at the **top level**
(no `content` wrapper), and this one route wants an **admin-tier** bearer (or
the instance's `BARKPARK_INGEST_TOKEN`) — a read/write scoped token 401s here:

```bash
curl -s $BP/v1/plugins/bulldocs/papers -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"slug":"welcome","blocks":[
        {"id":"t1","type":"heading","level":1,"text":"Welcome"},
        {"id":"p1","type":"paragraph","content":[{"type":"text","value":"First paper, filed remotely."}]}]}'
```

Paste any of these into a Claude.ai chat as a code block for the user to run.
Full route reference: [docs/api-v1.md](../api-v1.md).

## Token scoping

Mint a **scoped** token — never an admin token — before it touches a
third-party platform. Give it exactly the permissions the surface needs
(`read` + `write` for doc/task creation; `admin` only if you must create
schemas), bound to one workspace. How to mint, and the permission tiers, are in
[docs/auth.md](../auth.md). A leaked scoped token revokes cleanly and blast-
radius stays small; a leaked admin token is a whole-instance incident.
