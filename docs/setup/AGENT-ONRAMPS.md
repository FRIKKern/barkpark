<!-- doc-tier: human | canonical-for: agent-onramps | budget: 1600tok -->
# Agent Onramps

One command, any agent. Point an AI at Barkpark — local or Cloud — and it goes from "never heard of it" to a schema, a document, a task, and a paper in under two minutes. This hub owns the two shared journeys (**AUTH**, **CREATE**); each per-target doc hands you the config that surface understands and points back here.

## Pick your target

Every target below wires the same `bp mcp serve` tool catalog (curated task tools) into that surface's native config.

| Surface | Config it speaks | Onramp |
|---|---|---|
| Cursor (desktop) | `.cursor/rules` + `.cursor/mcp.json` | [CURSOR.md](CURSOR.md) |
| Cursor Cloud | `.cursor/environment.json` + Secrets | [CURSOR-CLOUD.md](CURSOR-CLOUD.md) |
| Claude Code | `CLAUDE.md` + `.mcp.json` | [CLAUDE-CODE.md](CLAUDE-CODE.md) |
| Codex CLI / Desktop | `AGENTS.md` + `~/.codex/config.toml` | [CODEX.md](CODEX.md) |
| Windsurf (Cascade) | `~/.codeium/mcp_config.json` (merge the key) | [WINDSURF.md](WINDSURF.md) |
| Gemini CLI | `.gemini/settings.json` (merge the key) | [GEMINI-CLI.md](GEMINI-CLI.md) |
| VS Code (GitHub Copilot) | `.vscode/mcp.json` (top-level `servers`) | [COPILOT.md](COPILOT.md) |
| ChatGPT · Claude.ai | Custom GPT Actions · remote MCP | [REMOTE.md](REMOTE.md) |

## AUTH

Three paths. Each ends with `bp` holding a valid server + token; verify with `bp whoami`.

**Local, unattended** — a fresh dev server on this machine. Destructive: runs `mix ecto.reset` (wipes the dev DB).

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup --target local --yes
```

Setup mints a `bp_admin_` token at execute time, prints it **once**, and persists it to `~/.config/barkpark/config.json` (mode `0600`). That token is your read/write/admin bearer for this server — store it.

**Connect** — point `bp` at a server that already exists (yours or a teammate's). Non-destructive.

```bash
bp setup --target connect --server https://api.example.com --token "$TOKEN" --yes
```

…or skip the config file entirely — the environment layer sits **above** `~/.config/barkpark/`:

```bash
export BARKPARK_API_URL=https://api.example.com
export BARKPARK_API_TOKEN=bp_admin_...
```

**Cloud** — an agent on Barkpark Cloud logs into the control plane, reads its fleet, pulls a live instance's admin token, and connects to it:

```bash
BARKPARK_PASSWORD=... bp login --email you@example.com   # control-plane session
bp barkparks -o json                                     # your fleet — each carries `id`
bp instance credentials <id> -o json                     # per-instance admin token + url
bp setup --target connect --server <url> --token <admin_token> --yes
```

Plainly, what the Cloud path can and can't do unattended:

- The Cloud session token is **control-plane only** — it manages your fleet and never authenticates content writes. The per-instance `admin_token` from `instance credentials` is the one that does.
- **2FA blocks unattended `bp login`** — a second factor can't be entered non-interactively.
- **Provisioning a NEW hosted instance is browser-gated** (Stripe Checkout). `bp login` can only reach instances that already exist. To stand one up, see [Cloud Quickstart](CLOUD-QUICKSTART.md).
- `instance credentials` can **404 (`no_admin_token`)** on legacy instances — the token is captured at provision time, so a pre-existing box may need a re-provision to store one.

## CREATE

With `bp` connected, the whole API is one call away — `bp capabilities -o json` returns every noun, verb, and route. The full arc:

```bash
# 0. Learn the surface — every noun, verb, route, in one call.
bp capabilities -o json | less

# 1. A content type (schema v2) — a minimal two-field type, upserted as-is.
cat > note.schema.json <<'JSON'
{"name":"note","title":"Note","fields":[
  {"name":"title","title":"Title","type":"string"},
  {"name":"body","title":"Body","type":"text"}
]}
JSON
bp schema apply --file note.schema.json
# Richer types: `bp make schema note` prints a full annotated skeleton —
# edit it down (its _comment keys explain each field), then apply.

# 2. A document of that type — `seed` fabricates a schema-valid draft.
bp seed note --count 1
bp doc ls note --perspective raw

# 3. A task — a claimable, dependency-aware work item.
bp task create "Draft the launch note" --publish \
  --set 'priority:=1' \
  --set 'acceptance_criteria:=[{"criterion":"note published","met":false,"evidence":""}]'
bp task ready

# 4. A paper — Barkpark's block document, read anywhere.
cat > paper.json <<'JSON'
{"slug":"hello","blocks":[
  {"id":"t1","type":"heading","level":1,"text":"Hello"},
  {"id":"p1","type":"paragraph","content":[{"type":"text","value":"My first paper, from an agent."}]}
]}
JSON
bp bulldocs publish hello --file paper.json
bp paper view hello
```

## MCP

Every target with a local shell registers the same server: `bp mcp serve` (stdio) turns the capability manifest into a tool catalog the agent calls directly — claim, read the brief, close with epoch-CAS, no shell. The default `--tools tasks` ships six curated task tools (task_ready · task_next · task_show · task_close · task_create · task_prime); `--tools all` is expert-only (Cursor hard-caps 40 tools vs ~107 manifest commands). The server **fails fast** if the target Barkpark has the Tasks plugin disabled — point it at one with Tasks enabled. Registration stanza per surface: each target doc above.
