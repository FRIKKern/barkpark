<!-- doc-tier: human | canonical-for: agent-onramps | budget: 1600tok -->
# Agent Onramps

One command, any agent. Point an AI at Barkpark — local or Cloud — and it goes from "never heard of it" to a schema, a document, a task and a paper in under two minutes. This hub owns the doctrine and the two shared journeys (**AUTH**, **CREATE**); each per-target doc hands you that surface's config and points back here.

## Register the movement

Every unit of work — build, research, plan, audit, spike — runs under a claimed task: if no row names it, create one and claim it FIRST, then work. Unregistered work is unrecoverable — a lost session is rebuilt only from the ledger, and "what has been going on lately" is answerable only from task events.

Written as mechanism, not exhortation — an agent that *believes* it registered its work behaves exactly like one that did. Three ways a registration you think you made never landed:

- A redirected or piped stdin makes `bp` REFUSE a mutating write — exit 2, `piped stdin is unused and <noun> <verb> does not accept --file`. In a heredoc-fed script every `claim`/`create`/`stamp` aborts **while the reads around them succeed**, so the run looks healthy. Pass arguments, never a pipe.
- A write to a remote server without `--yes` aborts — exit 2, `prod write not confirmed`. It fires only *after* the stdin refusal clears, so fixing one can reveal the other.
- A printed receipt is not persistence. Read the row back and match a string you wrote.

One Go constant (`internal/cli/movement_doctrine.go`) feeds the `bp onramp agents-md` block, the `bp mcp serve` instructions and `bp task prime`'s lead line; `movement_doctrine_test.go` reds if a surface drops it. Repo-local mechanics (PR trailers, merge gates) stay out — that block lands in other people's repos — and live in [TASK-SYSTEM](TASK-SYSTEM.md).

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

**Local, unattended** — a fresh dev server here. Destructive: `mix ecto.reset` wipes the dev DB.

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup --target local --yes
```

Setup mints a `bp_admin_` token at execute time, prints it **once**, and persists it to `~/.config/barkpark/config.json` (mode `0600`) — your read/write/admin bearer for this server.

**Connect** — point `bp` at an existing server (yours or a teammate's). Non-destructive.

```bash
bp setup --target connect --server https://api.example.com --token "$TOKEN" --yes
```

…or skip the config file — the environment layer sits **above** `~/.config/barkpark/`:

```bash
export BARKPARK_API_URL=https://api.example.com
export BARKPARK_API_TOKEN=bp_admin_...
```

First set wins (canonical beats alias): server `BARKPARK_API_URL` → `BARKPARK_SERVER` → `BARKPARK_URL`; token `BARKPARK_API_TOKEN` → `BARKPARK_TOKEN`. The aliases are the Next.js template dialect.

**Cloud** — log into the control plane, read the fleet, pull an instance's admin token, connect:

```bash
BARKPARK_PASSWORD=... bp login --email you@example.com   # control-plane session
bp barkparks -o json                                     # your fleet — each carries `id`
bp instance credentials <id> -o json                     # per-instance admin token + url
bp setup --target connect --server <url> --token <admin_token> --yes
```

What the Cloud path can and can't do unattended:

- The Cloud session token is **control-plane only** — it never authenticates content writes. The per-instance `admin_token` from `instance credentials` is the one that does.
- **2FA blocks unattended `bp login`** — a second factor can't be entered non-interactively.
- **Provisioning a NEW hosted instance is browser-gated** (Stripe Checkout); `bp login` reaches only instances that already exist — [Cloud Quickstart](CLOUD-QUICKSTART.md).
- `instance credentials` can **404 (`no_admin_token`)** on legacy instances: the token is captured at provision time, so a pre-existing box may need a re-provision.

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
# Richer types: `bp make schema note` prints an annotated skeleton to edit down.

# 2. A document of that type — `seed` fabricates a schema-valid draft.
bp seed note --count 1
bp doc ls note --perspective raw

# 3. A task — a claimable, dependency-aware work item.
# The publish WALL applies to `task` and `paper` docs: a published one needs a
# `description` (≥20 chars) AND weighted `tags` [{tag, strength 1–100 distinct,
# rationale ≥20 chars}] whose every `tag` is already a registered tag doc — else
# 422 `label_spine` or 422 `unknown_tag`. A FRESH instance registers NO tags;
# register one by publishing a `type:tag` doc whose id IS the tag string:
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

# 4. A paper — Barkpark's block document. Papers hit the SAME wall, so the
# payload carries `description` + weighted `tags` (`bulldocs publish --file`
# forwards both into the ingest params). Tags must be registered — step 3 did it.
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

Every target with a local shell registers the same server: `bp mcp serve` (stdio) turns the capability manifest into a tool catalog the agent calls directly — claim, read the brief, close with epoch-CAS, no shell. Its `initialize` reply carries the doctrine above as MCP **instructions**, so an MCP-only client is primed without reading this page. Default `--tools tasks` ships eight curated tools (task_ready · task_next · task_show · task_close · task_create · task_prime · task_stamp · task_pulse); `--tools all` is expert-only (Cursor hard-caps 40 tools vs ~107 commands). It **fails fast** if the target has the Tasks plugin disabled. Stanza per surface: each target doc above.

## One-step onramp — `bp onramp <target>`

`bp onramp <target>` prints the exact config block(s) for one surface, where they belong, and how to verify — paste-by-hand by default, nothing written. Targets: `cursor`, `claude-code`, `codex`, `cursor-cloud`, `windsurf`, `gemini-cli`, `copilot`, `zed`, `agents-md` (`chatgpt` / `claude-ai` are remote — [REMOTE.md](REMOTE.md)). `--server URL` bakes the API URL in; `--token TOKEN` bakes a literal token instead of the safe `${…}` placeholder; `-o json` emits `{target, files:[{path,content}], verify}`.

### `--write` — merge it for you

`bp onramp <target> --write` merges **only** the `barkpark` entry: every other MCP server and unrelated key survives verbatim (JSON re-emits in canonical 2-space form — values are never altered; Codex's `config.toml` is a textual span splice over `[mcp_servers.barkpark]*`, no TOML library). Writes are **atomic** (temp + rename) at mode `0644` / dir `0755` — they hold a `${env:}` placeholder, not secrets.

It is **idempotent** and honest per file:

| action | when |
|---|---|
| `created` | the file did not exist — written with just the barkpark stanza |
| `updated` | the file existed with no barkpark entry (or a differing one under `--force`) — barkpark merged in, everything else preserved |
| `unchanged` | the barkpark entry already matches — exit 0, nothing written |
| `skipped` | a **different** barkpark entry is already present — left untouched; re-run with `--force` to overwrite it |

Re-running is always safe; `--force` only changes `skipped`→`updated`. `--write -o json` emits `{target, actions:[{path,action,note}]}` (progress on stderr, so stdout is one parseable report); `--write --dry-run` computes the same actions and writes **nothing** — not one byte, not even the parent directory.

```bash
bp onramp cursor --write            # merge barkpark into .cursor/mcp.json
bp onramp cursor --write --force    # overwrite an existing, differing barkpark entry
bp onramp cursor --write --dry-run  # report what --write would do; write nothing
bp onramp cursor-cloud --write      # both .cursor/environment.json + .cursor/mcp.json, per file
bp onramp codex --write             # merge the [mcp_servers.barkpark] span into ~/.codex/config.toml
```
