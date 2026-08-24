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
| Zed | `~/.config/zed/settings.json` (`context_servers`, merge the key) | [ZED.md](ZED.md) |
| Codex · Aider · any AGENTS.md agent | `./AGENTS.md` (marker-managed teach block) | [AGENTS-MD.md](AGENTS-MD.md) |
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

Recognized names, first set wins (canonical beats alias): server `BARKPARK_API_URL` → `BARKPARK_SERVER` → `BARKPARK_URL`; token `BARKPARK_API_TOKEN` → `BARKPARK_TOKEN`. Aliases: the Next.js template dialect (`templates/DEPLOYING.md`).

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
# The publish WALL applies to `task` and `paper` docs (authoring-excellence): a
# published one needs a `description` (≥20 chars) AND weighted `tags`
# [{tag, strength 1–100, rationale}] whose every `tag` is already a registered
# tag doc — else 422 `label_spine` (missing description/tags) or 422
# `unknown_tag`. Strengths must be distinct (the max is the main tag); each
# `rationale` is ≥20 chars. A FRESH instance registers NO tags, so register the
# ones you'll use first — a tag is registered by publishing a `type:tag` doc
# whose id is the tag string (tag docs are not walled):
bp doc create tag --yes --set _id=docs --set title="Docs"
bp doc publish tag docs --yes
bp doc create tag --yes --set _id=search --set title="Search"
bp doc publish tag search --yes
bp doc ls tag                                    # both now registered

bp task create "Draft the launch note" --publish \
  --set 'priority:=1' \
  --set description="Write and publish the product launch note as a first agent-authored task." \
  --set 'tags:=[{"tag":"docs","strength":80,"rationale":"launch-note authoring is documentation work"},{"tag":"search","strength":40,"rationale":"the note should be findable via FTS once published"}]' \
  --set 'acceptance_criteria:=[{"criterion":"note published","met":false,"evidence":""}]'
bp task ready

# 4. A paper — Barkpark's block document, read anywhere. Papers hit the SAME
# wall, so the ingest payload carries a `description` and weighted `tags`
# (`bp bulldocs publish --file` forwards the file's top-level `tags`/`description`
# into the ingest params the wall reads). The tags must already be registered
# (step 3 did that).
cat > paper.json <<'JSON'
{"slug":"hello",
 "description":"My first Barkpark paper, authored end-to-end by an agent.",
 "tags":[{"tag":"docs","strength":80,"rationale":"a hello-world paper is documentation content"},
         {"tag":"search","strength":40,"rationale":"the paper should surface in full-text search"}],
 "blocks":[
  {"id":"t1","type":"heading","level":1,"text":"Hello"},
  {"id":"p1","type":"paragraph","content":[{"type":"text","value":"My first paper, from an agent."}]}
]}
JSON
bp bulldocs publish hello --file paper.json
bp paper view hello
```

## MCP

Every target with a local shell registers the same server: `bp mcp serve` (stdio) turns the capability manifest into a tool catalog the agent calls directly — claim, read the brief, close with epoch-CAS, no shell. The default `--tools tasks` ships eight curated task tools (task_ready · task_next · task_show · task_close · task_create · task_prime · task_stamp · task_pulse); `--tools all` is expert-only (Cursor hard-caps 40 tools vs ~107 manifest commands). The server **fails fast** if the target Barkpark has the Tasks plugin disabled — point it at one with Tasks enabled. Registration stanza per surface: each target doc above.

## One-step onramp — `bp onramp <target>`

`bp onramp <target>` prints the exact config block(s) for one surface, where they belong, and how to verify — paste-by-hand by default (nothing is written). Targets: `cursor`, `claude-code`, `codex`, `cursor-cloud`, `windsurf`, `gemini-cli`, `copilot`, `zed` (`chatgpt` / `claude-ai` are remote — see [REMOTE.md](REMOTE.md)). `--server URL` bakes the API URL in; `--token TOKEN` bakes a literal token instead of the safe `${…}` env placeholder; `-o json` emits `{target, files:[{path,content}], verify}`.

### `--write` — merge it for you

`bp onramp <target> --write` does the work: it merges **only** the `barkpark` entry into the target's config and touches nothing else. Every other MCP server and every unrelated top-level key survives verbatim — only the barkpark key is swapped (a JSON merge re-emits the file in canonical 2-space form, so unusual whitespace or key order is normalised; values are never altered, and a fresh `created` file is the doc stanza byte-for-byte). Codex's `~/.codex/config.toml` is merged as a textual **span splice** (no TOML library): the owned span is the `[mcp_servers.barkpark]` table plus every `[mcp_servers.barkpark.*]` sub-table; every byte outside it survives verbatim, and `--force` replaces the whole span with the canonical flat stanza. Writes are **atomic** (temp file + rename, so a crash never leaves a half-written config) and land at mode `0644` / dir `0755` — these are project-committed configs holding a `${env:}` placeholder, not secrets.

It is **idempotent** and honest per file:

| action | when |
|---|---|
| `created` | the file did not exist — written with just the barkpark stanza |
| `updated` | the file existed with no barkpark entry (or a differing one under `--force`) — barkpark merged in, everything else preserved |
| `unchanged` | the barkpark entry already matches — exit 0, nothing written |
| `skipped` | a **different** barkpark entry is already present — left untouched; re-run with `--force` to overwrite it |

Re-running `--write` is always safe: an already-correct config reports `unchanged` and is not rewritten. `--force` only changes the `skipped`→`updated` case; it still never touches a foreign server or an unrelated key.

`--write -o json` emits one document, `{target, actions:[{path,action,note}]}`; human progress stays on stderr so stdout is a single parseable report.

Add the global `--dry-run` to preview: `--write --dry-run` computes and reports the exact per-file actions (`created` / `updated` / `skipped` / `unchanged`) and writes **nothing** — not one byte, not even the parent directory. The JSON report carries `"dryRun": true`; the human report is marked `DRY RUN`. It is the honest doctor mode — re-run without `--dry-run` to apply.

```bash
bp onramp cursor --write            # merge barkpark into .cursor/mcp.json
bp onramp cursor --write --force    # overwrite an existing, differing barkpark entry
bp onramp cursor --write --dry-run  # report what --write would do; write nothing
bp onramp cursor-cloud --write      # both .cursor/environment.json + .cursor/mcp.json, per file
bp onramp codex --write             # merge the [mcp_servers.barkpark] span into ~/.codex/config.toml
```
