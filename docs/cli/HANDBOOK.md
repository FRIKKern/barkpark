# Barkpark `bp` CLI — Handbook (M4 GA)

> The `bp` command is the headless client for a Barkpark server. The **same Go
> binary** is the interactive TUI (run with no arguments) and the CLI (run with a
> command). This handbook documents the CLI face as built.
>
> Everything in this document is grounded in the shipped code
> (`internal/cli/`, `internal/manifest/`) and the frozen manifest contract
> (`docs/cli/manifest.schema.json`, `docs/cli/m0-decisions.md`,
> `docs/cli/error-exit-table.md`). Where v1 intentionally defers a capability, it
> is called out — not hidden.

---

## 1 · Install

The CLI ships as a single static binary named `bp`. Install it with the curl|sh
installer, which downloads the right `dist/bp-<os>-<arch>` artifact for your
platform and drops it on your `PATH`:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
```

The installer detects your OS (`darwin`/`linux`) and arch (`arm64`/`amd64`),
downloads the matching `bp-<os>-<arch>` release asset, and installs it to
`/usr/local/bin` — falling back to `~/.local/bin` when that is not writable (it
prints a PATH hint if the chosen dir is not on your `PATH`). Two env tunables:
`BARKPARK_BIN_DIR` overrides the install directory, and
`BARKPARK_CLI_RELEASE_BASE` overrides the download base URL.

### Build from source

If you have Go ≥ 1.24 and a checkout, build it yourself:

```bash
# native binary for this host -> dist/bp
make cli-build

# or cross-compile all four targets -> dist/bp-{darwin,linux}-{arm64,amd64}
make cli-release

# put it on your PATH
install dist/bp /usr/local/bin/bp
```

Verify the install:

```bash
bp version          # -> barkpark 1.0.0
bp version -o json  # -> {"cli_version":"1.0.0"}
```

> **Note on the binary name.** The release artifact is `bp`. The Go module and
> repo are `barkpark`; the program prints `barkpark <version>` for `bp version`,
> and all diagnostic messages are prefixed `barkpark:`. Running the binary with
> **no arguments** launches the interactive TUI, not the CLI.

---

## 2 · The `bp <noun> <verb>` grammar

Every CLI invocation is:

```
bp [global flags] <noun> <verb> [positional args] [command flags]
```

- **noun** — a resource (`doc`, `schema`, `media`, `search`, …). Plugins add
  their own nouns (`bulldocs`, `onixedit`).
- **verb** — an action on that noun (`ls`, `get`, `query`, `mutate`, …).
- **args** — positional values bound by declared order (e.g. the type, then the
  doc id).
- **command flags** — per-command flags declared by the manifest (e.g.
  `--perspective`, `--file`, `--if-rev`).

The command tree is **not hardcoded**. It is a pure function of the capabilities
manifest the server returns from `GET /v1/capabilities`. A plugin that adds a
noun/verb appears in `bp` with zero client code change.

Global flags may appear **before or after** the noun — these are identical:

```bash
bp doc ls post -o json
bp -o json doc ls post
```

### Discovering the surface

```bash
bp capabilities          # human summary: server identity, your tier, all commands
bp help                  # list every command grouped by noun
bp <noun>                # list the verbs under one noun (exit 2 — incomplete usage)
bp <noun> <verb> -h      # show one command's args + flags
```

A few commands are **CLI-native built-ins** that do not come from the manifest
tree: `capabilities`, `whoami`, `version`, `login`, `completion`.

---

## 3 · Global flags

Parsed before the noun, recognised anywhere in the argument list. Source of
truth: `internal/cli/globals.go`.

| Flag | Takes value | Default | Effect |
|---|---|---|---|
| `-s`, `--server <url>` | yes | env / `http://localhost:4000` | API base URL. |
| `-w <slug>`, `--workspace <slug>` | yes | env / `default` | Workspace slug. |
| `-p <slug>`, `--project <slug>` | yes | env / `default` | Project slug. |
| `-d`, `--dataset <name>` | yes | env / `production` | Dataset. |
| `-o`, `--output <fmt>` | yes | `table` on a TTY, `json` when piped | Output shape: `table` \| `json` \| `yaml` \| `minimal`. Invalid value → exit 2. |
| `--json` | no | — | Shorthand for `-o json`. |
| `-q`, `--quiet` | no | off | Minimal receipt (rev + ids) on writes. Forces `minimal` output. |
| `-v`, `--verbose` | no | off | Extra diagnostics on stderr (e.g. `request_id` on errors). |
| `--no-color` | no | color on a TTY | Disable colour. |
| `--dry-run` | no | off | Print the request that *would* be sent, then exit 0 without sending. See §8. |
| `--yes` | no | off | Skip the production write-guard confirmation prompt. |
| `--limit <n>` | yes | command-declared (e.g. 50) | Pagination page size (paginated reads). |
| `--offset <n>` | yes | 0 | Pagination offset (paginated reads). |
| `--all` | no | off | Fetch every page of a paginated read (loops offsets, 100/page). |
| `--manifest <path>` | yes | — | Load the manifest from a local file instead of `GET /v1/capabilities`. |
| `-h`, `--help` | no | — | Usage. |

> **Output default.** When you do **not** pass `-o`/`--output`/`--json`, the CLI
> picks `table` if stdout is a terminal and `json` when it is piped, so
> `bp doc ls post | jq` Just Works. A write command whose manifest
> `default_output` is `minimal` prints the minimal receipt by default on a TTY;
> `-q` forces `minimal` everywhere.

---

## 4 · Auth tiers and credentials

Each command declares an `auth_tier` in the manifest. The CLI attaches the
correct credential per tier (`internal/cli/run.go` `authHeaders`):

| `auth_tier` | What the CLI sends | Credential source |
|---|---|---|
| `none` | nothing | public, unauthenticated |
| `read` | bearer token **only when the path is scoped** (`scoped_prefix` set + token present); flat public reads send nothing | resolved token |
| `write` / `admin` / `scoped_admin` | `Authorization: Bearer <token>` | resolved token |
| `ingest` | `Authorization: Bearer <secret>` | ingest secret (see below) |

Notes that match the as-built behaviour:

- **`scoped_admin` is never client-preflight-refused** (M0 contract rule #2).
  Only the server knows your per-workspace role, so the CLI sends the request
  with the bearer token and surfaces the server's 403 cleanly.
- **`ingest` uses a different secret**, not your api token. The CLI reads
  `BARKPARK_INGEST_TOKEN`, then the `PAPERFLOW_INGEST_TOKEN` alias, then falls
  back to the resolved bearer token (single-secret dev setups). It rides the same
  `Authorization: Bearer` header — the server's `RequireIngestToken` plug
  constant-time-compares it against the configured ingest token.

### Environment variables (`BARKPARK_*`)

The CLI and TUI share one env contract (`apiclient.ConfigFromEnv`). Each var has
a baked-in v1 fallback so the CLI works out of the box against a local dev server:

| Env var | Falls back to | Maps to |
|---|---|---|
| `BARKPARK_API_URL` (then `BARKPARK_SERVER`) | `http://localhost:4000` | server |
| `BARKPARK_API_TOKEN` | `barkpark-dev-token` | bearer token |
| `BARKPARK_WORKSPACE` | `default` | workspace |
| `BARKPARK_PROJECT` | `default` | project |
| `BARKPARK_DATASET` | `production` | dataset |
| `BARKPARK_PERSPECTIVE` | `drafts` (TUI only) | dataset view (`published` / `drafts` / `raw`) the **interactive TUI** reads |
| `BARKPARK_INGEST_TOKEN` (then `PAPERFLOW_INGEST_TOKEN`) | resolved bearer token | ingest secret (`ingest`-tier commands) |
| `BARKPARK_MANIFEST` | — | local manifest file (same as `--manifest`) |

> There is **no interactive `login`** in v1. `bp login` is a stub that explains
> the token mechanism and exits 0. Configure auth via `BARKPARK_API_TOKEN` or
> `-s` + the dev token.

### Context precedence

Server / workspace / project / dataset / output each resolve **independently**,
field by field, by this precedence (`manifest.Resolve`):

```
flags  >  env (BARKPARK_*)  >  active context  >  defaults
```

The **active context** layer is the persisted `config.json` (`bp setup`,
`bp use <name>` — see §13). With **no** env var set, the active server wins over
the baked default, so flipping it with `bp use <name>` repoints every later
command (and the TUI — below). An explicit `BARKPARK_API_URL` / `BARKPARK_SERVER`
still sits above it and overrides per-invocation. (The interactive TUI resolves
through this exact chain via `ResolvedAPIConfig`, then adds its own
`drafts`-perspective default — `BARKPARK_PERSPECTIVE` to change.)

---

## 5 · The core noun → verb surface

This is the core (non-plugin) surface as it appears in the manifest fixtures.
Your live surface comes from your server's `GET /v1/capabilities`; run
`bp capabilities` to see exactly what your token can reach (the manifest is
auth-tier projected — an anonymous caller does not even see admin noun names).

| Command | HTTP | Tier | Notes |
|---|---|---|---|
| `bp doc get <type> <doc_id>` | GET | none | `--perspective published\|drafts\|raw` (default `published`). |
| `bp doc ls <type>` | GET | none | Paginated. `--limit`, `--offset`, `--all`. |
| `bp doc query <type>` | GET | none | Paginated; `--query <expr>` filter. |
| `bp doc mutate` | POST | write | **Batch**; body `{"mutations":[…]}` via `-f`. |
| `bp schema get <name>` | GET | none | Fetch one public schema. |
| `bp schema apply <name>` | PUT | admin | Register/update a schema; body via `-f`. |
| `bp media ls` | GET | none | Paginated. |
| `bp media upload <file>` | POST | write | Upload an asset (positional file). |
| `bp search query <q>` | GET | none | `--engine postgres\|indx`, `--limit`. Paginated. |
| `bp workspace ls` | GET | read | List workspaces your token reaches. |
| `bp workspace project-create <name>` | POST | scoped_admin | Project verbs fold under `workspace`. |
| `bp task ls` | GET | read | Paginated; `--limit`. |
| `bp task claim <task_id>` | POST | admin | Claim a ready task. |
| `bp webhook ls` | GET | admin | List webhook subscriptions. |
| `bp webhook create <url>` | POST | write | Create a subscription. |
| `bp rail path <goal_id>` | GET | read | Goal-path lifecycle events. |
| `bp plugin ls` | GET | read | List installed plugins. |
| `bp plugin settings <slug>` | PUT | admin | `--set key=value` (repeatable). |

### Plugin verbs

Plugins contribute ergonomic verbs into the same `commands[]` array via the
`cli_commands/0` callback — **no host edit, no client edit**. They appear in the
tree tagged with `source: plugin:<slug>` and the owning noun carries the plugin
slug. From the fixtures:

| Command | HTTP | Tier | Notes |
|---|---|---|---|
| `bp bulldocs publish <slug>` | POST | ingest | Upsert a paper from a portable-doc/HTML payload; body via `-f`. |
| `bp bulldocs patch <slug>` | POST | ingest | **Batch** block ops `{"ops":[…]}` via `-f`; `--if-rev <n>` optimistic guard. |
| `bp bulldocs intents` | GET | ingest | List pending actionable paper intents. |
| `bp bulldocs intent-processed <id>` | POST | ingest | Mark an intent processed. |
| `bp onixedit export <dataset> <id>` | GET | admin | Export a book document as ONIX 3.0 XML. |

---

## 6 · Batch writes (`{ops:[…]}` / `{mutations:[…]}`) with `-f`

A command marked `batch: true` in the manifest accepts a JSON payload that wraps
an array of operations and applies them **atomically in one request**. The
universal short flag `-f` aliases the declared `--file` flag; pass a path, or `-`
for stdin.

```bash
# Mutations batch (doc mutate) — create + publish in one atomic call
bp doc mutate -f mutations.json

# Block-ops batch (bulldocs patch) — append/patch/move blocks atomically
bp bulldocs patch 2026-06-07-demo -f ops.json

# From stdin
cat ops.json | bp bulldocs patch 2026-06-07-demo -f -
```

The body is sent verbatim with `Content-Type: application/json`. The CLI does
not reshape it — `mutations.json` must already be `{"mutations":[…]}` and
`ops.json` must already be `{"ops":[…]}` (optionally with `ifRev`). A write with
no `-f` and no `--set` sends an empty `{}` body.

> Some non-batch writes (e.g. `schema apply`, `bulldocs publish`) also take their
> body via `-f`; "batch" specifically means the payload is an array of
> operations applied atomically.

---

## 7 · Output formats

`-o table | json | yaml | minimal` (or `--json` for json, `-q` for minimal).

- **table** — human-readable columns for list/object payloads; system
  (underscore) keys are hidden from the table view (full data is one `-o json`
  away). Eyeballs only.
- **json** — pretty, stable JSON. The API wraps data in `{"result": …}`; the CLI
  **unwraps** it so you see the payload, not the envelope.
- **yaml** — the same value space as YAML (hand-rolled emitter, sorted keys).
- **minimal** — the token-efficient write receipt: `rev: …` plus any `id: …`
  lines found in the payload, else `ok`. This is the default for writes whose
  manifest `default_output` is `minimal`, and the shape `-q` forces.

```bash
bp doc ls post -o json | jq '.documents[].title'
bp doc get post p2 -o yaml
bp doc mutate -f mutations.json -q     # -> rev: <txn>   id: <created id>
```

---

## 8 · `--dry-run` (client-side only in v1)

`--dry-run` prints the **resolved** request — method, absolute URL (placeholders
filled), tier-appropriate headers with credentials **redacted**, and the body —
then exits 0 **without sending** (M0 decision A1). It is honest about its limits:
the manifest's per-command `dry_run` is `false` across the board in v1 (no server
validate-only endpoint exists), so the CLI announces:

```
dry-run: client-side preview only (server validate-only not available)
```

```bash
bp doc mutate -f mutations.json --dry-run
# stderr: dry-run: client-side preview only (server validate-only not available)
# stdout: POST http://localhost:4000/v1/data/mutate/production
#         Authorization: Bearer ****
#         Content-Type: application/json
#
#         {"mutations":[...]}
```

When a server later supports validate-only for a command, that command's
manifest `dry_run` flips to `true` and `--dry-run` sends the request instead of
printing.

### Production write-guard

A **write** against a prod-looking target prompts `⚠ PROD: … Continue? [y/N]` on
stderr unless `--yes` is passed. "Prod-looking" is a local heuristic on the
server name/URL (`prod`/`production`, or `api.barkpark.cloud`; `localhost` /
`127.0.0.1` / `0.0.0.0` are never prod). This guard is local UX only — it does
not preflight-refuse `scoped_admin` (contract rule #2).

---

## 9 · Exit codes

The CLI maps the API error envelope's `error.code` string to a process exit code.
It **never** re-derives the exit from the HTTP status (contract rule #3). Source:
`docs/cli/error-exit-table.md`, `internal/cli/errors.go`.

| Exit | Bucket | When |
|---|---|---|
| `0` | success | Command completed (prints result, or the minimal receipt on writes). |
| `1` | generic / unexpected | Network / timeout, unknown `error.code`, or an unrecognised error shape. |
| `2` | usage / unknown command | Bad args, malformed request, unknown command/sub-command. |
| `3` | auth / forbidden | Missing/invalid credential or insufficient permission. |
| `4` | not-found | Resource or schema does not exist. |
| `5` | validation | Payload failed schema or op validation. |
| `6` | conflict | Optimistic-concurrency / write-conflict / precondition (`rev_mismatch`, `precondition_failed`, `conflict`, lifecycle `halted`). |
| `7` | rate-limited | Throttled. |
| `8` | server (5xx) | Server-side `internal_error`. |

Representative `error.code` → exit mappings (the full table is canonical):

| `error.code` | Exit |
|---|---|
| `not_found`, `schema_unknown`, `share_expired` | 4 |
| `unauthorized`, `forbidden`, `cors_forbidden`, `csrf_required` | 3 |
| `malformed` | 2 |
| `validation_failed`, `invalid_paper`, `malformed_op`, `invalid_op`, `block_not_found`, `type_mismatch`, `duplicate_id` | 5 |
| `rev_mismatch`, `precondition_failed`, `conflict` | 6 |
| `rate_limited` | 7 |
| `internal_error` | 8 |

A few non-canonical wire shapes are handled too: the bare `{"error":"halted"}`
lifecycle veto → 6; the tasks `{"ok":false,"reason":…}` shape → 2; bare-string
`{"error":"not_found"}` (intents / plugin-settings) → 4; a code-less
`{"error":{"message":…}}` → 2 (or 4 when the message reads like a not-found).

---

## 10 · `scoped_prefix` is INERT in v1

A command's manifest may carry a `scoped_prefix` hint (e.g.
`/w/:workspace_slug/p/:project_slug`). In v1 **this hint does nothing** — the
scoped route *mirror* exists on no server today, so the CLI calls the **flat**
`http.path_template` and does **not** prepend the prefix (contract rule #4,
`manifest.BuildURL`).

Prepending against a flat-only server would turn `/v1/data/query/…` into
`/w/default/p/default/v1/data/query/…`, which 404/403s and would break every
scoped command. The prepend activates only when a future server advertises the
mirror (gated by `Context.ScopedMirror`, which is `false` everywhere in v1). The
hint ships in the manifest now purely for forward-compatibility — your
workspace/project flags still resolve other things (e.g. `workspace
project-create`), but they do **not** rewrite flat data paths in v1.

> The `--manifest <path>` / `BARKPARK_MANIFEST` override exists for the same
> forward-compat reason: `/v1/capabilities` is not live on every server yet, so a
> committed fixture lets the CLI run end-to-end against an API that only has the
> data endpoints.

---

## 11 · Copy-paste examples

All examples assume a local dev server with the baked-in token; set
`BARKPARK_API_URL` / `BARKPARK_API_TOKEN` to point elsewhere.

```bash
# 1. List documents of a type as JSON, pull titles with jq
bp doc ls post -o json | jq '.documents[].title'

# 2. Fetch one document by type + id
bp doc get post p2

# 3. List draft documents (perspective flag), as a table
bp doc ls post --perspective drafts

# 4. Apply an atomic mutation batch from a file, minimal receipt
bp doc mutate -f mutations.json -q
#    mutations.json: {"mutations":[{"create":{"_type":"post","_id":"x","title":"New"}}]}

# 5. Publish a Bulldocs paper (ingest tier) — slug arg + payload via -f
bp bulldocs publish 2026-06-07-demo -f paper.json

# 6. Apply a batch of block-ops to a paper, guarded by the current rev
bp bulldocs patch 2026-06-07-demo -f ops.json --if-rev 1
#    ops.json: {"ops":[{"op":"append-block","block":{"id":"b9","type":"paragraph","content":["Added."]}}]}

# 7. Inspect the resolved manifest and filter commands with jq
bp capabilities -o json | jq '.commands[] | {id, auth_tier, path: .http.path_template}'

# 8. Who am I / what am I pointed at (note ⚠ PROD marker when prod)
bp whoami

# 9. Dry-run a write to preview the request without sending it
bp doc mutate -f mutations.json --dry-run

# 10. Full-text search via the indx engine, fetch every page
bp search query "barkpark" --engine indx --all -o json
```

---

## 12 · v1 deferral summary

These are declared v1 constraints (not bugs), each with a forward seam:

- **`--dry-run`** is client-side request-printing; no server validate-only yet.
- **Dataset discovery** is absent — `production` is the assumed default (A2).
- **`whoami`** is composed from `GET /v1/meta` + the manifest's caller
  `auth_tier`; no dedicated identity endpoint (A3).
- **`login`** and **`completion`** are stubs that print and exit 0.
- **`scoped_prefix`** is inert; the flat path is what the CLI calls (rule #4).
- **Active/named contexts** are not persisted; there is no `context use` (§4).

---

## 13 · Setup (`bp setup`)

`bp setup` is the on-ramp — it points `bp` at a server, or brings one into
existence. It is a **CLI-native built-in** (outside the manifest tree, like
`whoami` / `capabilities`): it does not need a reachable server to run, because
its whole job is to get you connected to one. Source: `internal/cli/setup_cmd.go`
(flag parser + help + wizard gate) and the `internal/cli/setup` engine package.

> **Two unrelated `--dry-run`s.** §8's `--dry-run` previews an *API write request*.
> The `bp setup --dry-run` here previews a *setup plan* (ordered steps, env,
> prerequisites) and emits a structured Plan object under `-o json`. Same flag
> name, different surface.

### The four modes

| Target | What it does | Rides |
|---|---|---|
| `connect` | Points `bp` at an existing server: probes `GET /v1/capabilities` + `GET /v1/meta` to confirm reachability and resolve the caller's auth tier, then persists the connection + scope so `bp` defaults there. | `apiclient` (HTTP); writes `${XDG_CONFIG_HOME:-~/.config}/barkpark/config.json` (0600) |
| `local` | Brings up a local dev server at `http://localhost:4000`, then chains into `connect`. **Destructive** — it resets a database (drop/create/migrate/seed). | `docker compose up -d` + `ecto.reset` (with `--docker`), else native `mix deps.get` / `mix ecto.reset` / `mix phx.server` in `api/` |
| `deploy` | Installs Barkpark on a server you already own over SSH, streaming the repo's `deploy.sh` into `bash -s` on the remote with `DOMAIN` / `PHX_SCHEME` / `BARKPARK_PLUGINS` env, verifies `/v1/capabilities` + `/studio`, then chains into `connect`. **Destructive/outbound** — provisions and restarts a live server. | `ssh <host> '<env> bash -s' < deploy.sh` |
| `provision` | **STAGED.** Creates a cloud host, then chains into `deploy`. By default it only *plans* — it prints the exact provider-CLI create commands plus a "needs `<credential>` + `--yes`" line. Real creation runs only when the provider CLI **and** a credential **and** `--yes` are all present. | `hcloud server create` (Hetzner) or `az group/vm create` (Azure); then the `deploy` ride |

`local`, `deploy`, and `provision` all finish by re-using the `connect` executor,
so a successful bring-up leaves `bp` pointed at the new server automatically.

### Interactive (the wizard)

On a genuine interactive terminal, a bare `bp setup` (no `--target`) launches the
premium Bubble Tea wizard. The wizard walks the four modes, shows the dry-run plan,
takes an explicit confirm, then runs for real. It launches **only** when *all* of:
stdin **and** stdout are a TTY, no `-o json` / `--json`, and no `--yes`. Any other
no-target invocation is a clean usage error (exit 2) — `bp setup` never opens
`/dev/tty` in a non-interactive context, so an agent or CI job is never blocked
on a prompt.

```bash
bp setup            # interactive wizard (TTY only)
```

### Automation / AI (flags)

Pass `--target` and the run is fully non-interactive. The complete flag list
(mirrors `bp setup -h` exactly):

| Flag | Applies to | Meaning |
|---|---|---|
| `--target <t>` | all | one of `connect` \| `local` \| `deploy` \| `provision` |
| `--server <url>` | connect | server URL (must start `http://` or `https://`) |
| `--token <tok>` | all | bearer token to persist with the connection |
| `-w, --workspace <w>` | all | workspace scope (default: `default`) |
| `-p, --project <p>` | all | project scope (default: `default`) |
| `-d, --dataset <ds>` | all | dataset scope (default: `production`) |
| `--docker` | local | bring up via `docker compose` (else native `mix`) |
| `--ssh-host <h>` | deploy | `user@host` (a bare host defaults to `root@`) |
| `--domain <d>` | deploy | public DNS hostname (**required** for deploy) |
| `--scheme <http\|https>` | deploy | public scheme (default: `https`) |
| `--provider <p>` | provision | `hetzner` \| `azure` |
| `--region <r>` | provision | region (provider default if omitted) |
| `--server-type <t>` | provision | instance type (provider default if omitted) |
| `--plugins <csv>` | all | plugin whitelist; `""` = none (kill switch); absent = all |
| `--dry-run` | all | print the plan; run **nothing** |
| `--yes` | all | confirm a destructive/outbound real run (no prompt) |
| `-o json` / `--json` | all | emit one machine-readable JSON object on stdout |
| `-h, --help` | all | print help (never opens a TTY) |

The setup-local flags fall through to the global `-s` / `-w` / `-p` / `-d` when
absent, so `bp -s URL setup --target connect` works too.

### Known servers (cache)

Every successful `connect` is remembered, so a returning user (or agent) does not
re-type a URL. The cache lives in the same file as the active connection —
`${XDG_CONFIG_HOME:-~/.config}/barkpark/config.json` (written 0600 in a 0700 dir,
since it holds tokens) — under the `known_servers` key. It builds up as you
connect: a fresh install starts with an empty cache.

- **Recorded on every connect.** A successful connect upserts an entry into
  `known_servers` (`RememberServer`, `internal/cli/config.go`). Upsert is by
  normalized server URL (trailing slash trimmed, scheme + host lowercased), so
  connecting to the same server twice collapses to one entry that moves to the
  front. The list is most-recent-first and capped at 20 entries. The connected
  server is also promoted to the active flat context, so it is the head of the
  list **and** the server bare `bp` defaults to.
- **Interactive pick-list.** In the wizard, choosing `connect` with a non-empty
  cache shows a pick-list — one row per remembered server (URL + a dim
  "last connected …"), the active one marked ★, then a final
  "＋ enter a new server…" escape row. Picking a saved row fills the server URL +
  its token/scope from history and skips the text input.
- **No `--server` default (non-interactive).** `bp setup --target connect` with no
  `--server` (and no global `-s` fall-through) reconnects to your **active** saved
  server; its token + scope ride along so the reconnect is complete (an explicit
  `--server`/`--token`/scope flag always overrides). The human path prints
  `reconnecting to saved server <url> (pass --server to override)`. With an empty
  cache there is nothing to fall back on, so it is a clean usage error
  (exit **2**), never a prompt:

  ```
  no --server and no saved server yet — pass --server <url> or run `bp setup` interactively
  ```

- **JSON view.** A connect dry-run (`--dry-run -o json`) carries a credential-free
  `known_servers` array so an agent can inspect the cache before connecting. Each
  entry is `{ "server", "active", "last_connected"? }` — tokens are never exposed.
  The array is always present on a connect plan (empty `[]` on a fresh cache).

  ```bash
  bp setup --target connect --dry-run -o json | jq '.known_servers'
  ```
  ```json
  [
    { "server": "https://api.example.com",     "active": true,  "last_connected": "2026-06-05T12:00:00Z" },
    { "server": "https://staging.example.com", "active": false, "last_connected": "2026-06-01T09:30:00Z" }
  ]
  ```

### Switching servers

Once two or more servers are in the cache, three built-ins (no manifest, no
network) move between them. Switching is **local and instant** — `bp use` only
rewrites the active fields in `config.json`; nothing is contacted. Any number of
servers coexist — several locals **and** several remotes in the same cache.

**Server kinds.** Each server is classified `local` or `cloud`, derived from its
host alone (`ServerKind`, `internal/cli/config.go`): the loopback family
(`localhost` / `127.0.0.1` / `::1`), any `*.local` mDNS name, and the RFC1918
private IPv4 ranges (`10.0.0.0/8`, `192.168.0.0/16`, `172.16.0.0/12`) are
`local`; every public DNS name or public IP is `cloud`. The cache happily holds
**multiple of each kind** — `bp servers` shows the kind as `[local]`/`[cloud]`
on every row, and you can filter with `bp servers --kind local|cloud`. (An entry
may pin an explicit `kind` in `config.json` to override the derivation;
`Config.KindOf` honours the pin, falling back to the host derivation when empty.)
The kind also drives the `bp migrate` cloud-target guard (below).

**Names.** Each remembered server has a short handle you type instead of a URL.
A handle is **auto-derived** from the URL unless you set one with
`bp setup --name <handle>` on connect:

- `localhost` / `127.0.0.1` / `::1` → `local`
- any other host → the first meaningful DNS label, with a leading `api`/`www`
  dropped (`api.barkpark.cloud` → `barkpark`, `staging.foo.com` → `staging`)
- a bare IPv4 → the address verbatim
- two unnamed servers that derive the same base get `-2`/`-3` suffixes so the
  printed handles never collide

(`deriveName` / `DisplayName`, `internal/cli/config.go`.) An explicit `--name`
always wins and is shown verbatim.

**`bp use <name|url>`** — make a saved server the active default. The argument
matches, in order, an entry's explicit name, its display handle, or its
normalized URL (`FindServer`). On a hit it promotes that entry's server + token
+ scope to the active context and saves:

```
$ bp use prod
✓ now using prod [cloud] — https://api.barkpark.cloud  (scope w=default p=default d=production)
```

The **interactive TUI shares this same active server**: launching `barkpark`
with no args resolves the connection through the identical
`flags > env > active-config > defaults` chain (`ResolvedAPIConfig` →
`resolveContext`, `internal/cli/cli.go`), so `bp use <name>` repoints the TUI
too — no env var needed. An explicit `BARKPARK_API_URL` still overrides. One
extra TUI-only default rides on top: the dataset view is **`drafts`** (so the
editing desk shows unpublished work), overridable with
`BARKPARK_PERSPECTIVE=published|drafts|raw` (`PerspectiveFromEnv`,
`internal/apiclient/client.go`). The CLI's manifest-driven reads never set a
perspective, so they keep the server's `published` default.

With **no argument** it reports the active server and lists the known handles:

```
$ bp use
active: local [local] — http://localhost:4000  (scope w=default p=default d=production)
known:  local, prod
hint:   bp use <name>   to switch
```

An unknown name/URL is a clean usage error (exit **2**) that lists the known
handles so you can fix the typo:

```
$ bp use staging
barkpark: no known server matches "staging"
known servers: prod, local
run `bp servers` for details.
```

**`bp servers`** (alias `bp server ls`) — list every saved server, the active
one marked ★, with its kind, tier, and last-connected stamp. Read-only, no
network. `--kind local|cloud` filters the list:

```
$ bp servers
★ local        [local]  http://localhost:4000  (admin, 2026-06-04T09:00:00Z)
  prod         [cloud]  https://api.barkpark.cloud  (admin, 2026-06-05T10:00:00Z)
```

**`-s <name|url>`** — target one server for a single command without changing
the active default. The global `-s` flag (§3) resolves a saved name the same way
`bp use` does (`resolveContext`, `internal/cli/cli.go`); the resolved URL **and**
that entry's saved token + scope ride along at flag precedence — except where you
passed an explicit `--token`/`-w`/`-p`/`-d`, which still win. A value matching no
known server is treated as a raw URL (today's behaviour), so `-s https://…` keeps
working:

```bash
bp use local                       # default = local
bp -s prod doc ls post             # this one command hits prod
bp doc ls post                     # back to local — the default never moved
bp -s https://other.example.com whoami   # raw URL: unknown name → used verbatim
```

`-o json` is available on all three: `bp use`/`bp use <name>` emit
`{ ok, active, known? }`, `bp servers` emits `{ servers:[…], active }`, and an
unknown `bp use` target emits `{ ok:false, error:{ code:"not_found", … } }`.

### The JSON contract

With `-o json` (or `--json`) setup emits exactly one JSON object on stdout. There
are three shapes. JSON mode is opt-in only — a plain piped run still gets human
prose, not machine output.

**Dry-run → Plan** (`--dry-run -o json`). Fields, from `internal/cli/setup/plan.go`
plus the `ok` envelope:

| Field | Type | Notes |
|---|---|---|
| `ok` | bool | `true` for a built plan |
| `target` | string | the resolved target |
| `dry_run` | bool | always `true` here |
| `destructive` | bool | `true` for local / deploy / provision |
| `requires_confirm` | bool | `true` when `--yes` gates the real run |
| `steps` | array of `{n, description, command?}` | ordered actions; `command` is the copy-pasteable shell line, omitted for narration-only beats |
| `env` | object (string→string) | env the run would set (e.g. `BARKPARK_PLUGINS`, `DOMAIN`, `PHX_SCHEME`); omitted when empty |
| `plugins` | object `{mode, value?}` | `mode` is `all` \| `none` \| `whitelist`; `value` is the CSV in whitelist mode |
| `needs` | array of `{what, present}` | prerequisites (provision: provider CLI + credential), with live presence; omitted when empty |
| `connect_to` | string | the server `bp` ends up pointed at; omitted when empty |
| `provider` / `region` / `server_type` | string | provision-only; `null` for other targets |

**Real run → Result** (`--yes -o json`). Fields, from the `Result` struct in
`plan.go`:

| Field | Type | Notes |
|---|---|---|
| `ok` | bool | `true` on success |
| `target` | string | the mode that actually ran (re-stamped through chains, e.g. `local` not `connect`) |
| `server` | string | the server `bp` is now pointed at; omitted when empty |
| `tier` | string | the caller's resolved auth tier; omitted when empty |
| `config_path` | string | where the connection was written; omitted when empty |
| `message` | string | short human one-liner; omitted when empty |

**Error** (either path). Usage/validation failures and real-run failures share one
shape:

```json
{ "ok": false, "error": { "code": "usage", "message": "setup connect: --server is required" } }
```

`code` is `usage` for flag/validation errors (exit **2**) and `failed` for an
operational real-run failure — network / SSH / install (exit **1**).

**Exit codes:** `0` ok (built plan or successful run), `2` usage/validation (bad
flags, unknown target, missing required input), `1` real-run failure. (Note: piping
through `jq` masks the process exit — branch on `bp`'s own exit code, or on the
`ok` field.)

### Safety

- **Dry-run first.** Every target builds the same Plan in dry-run that it executes
  for real, so `--dry-run` is a faithful preview with no network call, no writes,
  no shelling out.
- **`--yes` gates side effects.** Destructive/outbound runs — `local` (resets a
  DB), `deploy` (provisions/restarts a live server), and `provision`-create —
  refuse to run without `--yes`. Connect is non-destructive and needs no confirm.
- **Provision is staged.** Even with `--yes`, provision only creates a host when
  the provider CLI is on PATH **and** a credential is present (`HCLOUD_TOKEN` /
  active `hcloud context` for Hetzner; an `az login` session for Azure). Otherwise
  it prints install/auth guidance and exits non-zero.
- **Never prompts non-interactively.** The wizard launches only on a real TTY with
  no `--target` / `-o json` / `--yes`; every other path is a clean structured error,
  never `/dev/tty`.

### Plugin selection

`--plugins` maps onto the `BARKPARK_PLUGINS` env the server reads, with kill-switch
semantics (`internal/cli/setup/plugins.go`, mirroring `Barkpark.Plugins.EnvConfig`):

| `--plugins` | `plugins.mode` | `BARKPARK_PLUGINS` | Effect |
|---|---|---|---|
| *absent* | `all` | unset (no env line) | registry discovers every bundled plugin |
| `--plugins ""` | `none` | `BARKPARK_PLUGINS=` (empty) | the kill switch — **no** plugins registered |
| `--plugins bulldocs,onixedit` | `whitelist` | `BARKPARK_PLUGINS=bulldocs,onixedit` | only the listed plugins |

The list is honoured by the registry kill-switch — an empty value is the explicit
"register nothing" signal, distinct from the flag being absent.

### Copy-paste examples

```bash
# 1. Point bp at an existing server (connect is non-destructive — no --yes needed)
bp setup --target connect --server https://api.example.com --token "$TOKEN"

# 2. AI flow: preview the plan as JSON (zero side effects)…
bp setup --target connect --server https://api.example.com --dry-run -o json | jq .
#    …then execute and parse the structured receipt
bp setup --target connect --server https://api.example.com --yes -o json | jq '.server, .tier'

# 3. Bring up a local dev server via docker compose with two plugins (resets the DB)
bp setup --target local --docker --plugins bulldocs,onixedit --yes

# 4. Preview a local native bring-up without touching anything
bp setup --target local --dry-run -o json | jq '.destructive, .steps[].command'

# 5. Deploy to a server you own over SSH
bp setup --target deploy --ssh-host root@1.2.3.4 --domain d.example.com --scheme https --yes

# 6. Provision a Hetzner host (staged — plans unless hcloud + HCLOUD_TOKEN + --yes)
bp setup --target provision --provider hetzner --region nbg1 --server-type cax11 \
  --domain d.example.com --dry-run -o json | jq '.needs, .steps[].command'
```

### Migrating between servers (`bp migrate`)

`bp migrate <from> <to>` copies documents from one saved server to another in a
single command — the companion to switching servers. It is a built-in (no
manifest, no `<noun> <verb>`), and like `bp setup` it is **safety-first**: it
always computes a full plan from the source first, prints that plan on a dry-run
(**the default**), and writes **only** when `--yes` is given.

**Synopsis**

```
bp migrate <from> <to> [--dataset <name>] [--type <t>] [--include-schemas]
                       [--dry-run] [--yes] [-o json]
```

`<from>` and `<to>` are saved-server references resolved exactly like
`bp use` / `-s` (`FindServer` — explicit name, then display handle, then
normalized URL). An unresolvable end is a clean usage error (exit **2**) listing
the known handles. Each endpoint's saved token + workspace/project scope ride
along; when an entry carries no token, a shared fallback is used — the global
`--token` flag, else `BARKPARK_API_TOKEN`. For distinct creds per end, save them
on the entries via `bp setup`.

**Flags**

| Flag | Effect |
|---|---|
| `--dataset <name>` | dataset to migrate (default: the source entry's dataset, else `production`) |
| `--type <t>` | migrate just one type; omit to migrate **all** source types (enumerated via `GET /v1/schemas/:dataset`, which needs admin on the source) |
| `--include-schemas` | POST the source schemas to the target **first**, so the target knows the types before documents land (best-effort per schema; a failure is recorded, not fatal) |
| `--dry-run` | plan only, write nothing — **the default**, accepted explicitly as a no-op |
| `--yes` | execute the migration (required to write anything) |
| `-o json` / `--json` | machine-readable plan (dry-run) or result (execute) |

**Safety model.** Three guards, all enforced in `runMigrate`
(`internal/cli/migrate_cmd.go`):

- **Dry-run first.** With no `--yes`, `bp migrate` prints the plan and writes
  nothing. The plan is computed from the source for real (it pages the source to
  count docs), so it is a faithful preview, not an estimate.
- **`--yes` gates every write.** No document or schema is POSTed to the target
  unless `--yes` is set.
- **Cloud-target guard.** When the target's kind is `cloud`, a real run prints a
  loud `⚠ writing N docs to <url> [cloud]` line first; the dry-run prints
  `⚠ target <url> is CLOUD — a real run writes to a remote server.` A cloud
  target is therefore never written silently, and never without `--yes`.

**Overwrite semantics.** Migration uses **`createOrReplace`** mutations keyed by
each document's `_id`: the source document JSON becomes the body of a
`createOrReplace` op verbatim, so `_id` / `_type` and every field round-trip. On
the target this is **overwrite-by-id** — a document with the same id is replaced
in full, not merged; a new id is created. The source is read with
`perspective=raw`, so **both drafts and published rows** migrate. Documents are
written in batches (50 per request); the source is paged 100 at a time.

**JSON shapes** (`migratePlanJSON`). The dry-run **plan**:

```json
{
  "from":    { "name": "local",    "url": "http://localhost:4000",       "kind": "local" },
  "to":      { "name": "barkpark", "url": "https://api.barkpark.cloud",  "kind": "cloud" },
  "dataset": "production",
  "types":   [ { "type": "post", "count": 38 } ],
  "total":   38,
  "include_schemas": false,
  "dry_run": true
}
```

The execute **result** adds, alongside `"dry_run": false`, the per-type counts
actually written, the grand total, and any per-batch errors:

```json
{
  "from": { … }, "to": { … }, "dataset": "production",
  "types": [ { "type": "post", "count": 38 } ], "total": 38,
  "include_schemas": false, "dry_run": false,
  "migrated": [ { "type": "post", "count": 38 } ],
  "total_migrated": 38,
  "errors": []
}
```

An execute that completes with one or more batch/schema errors still emits the
result but exits **1**, with `errors[]` populated. An unresolvable server emits
`{ "ok": false, "error": { "code": "not_found", … } }` (exit **2**).

**Examples**

```bash
# 1. Dry-run (default): plan only, nothing written. Counts every type on the source.
bp migrate local barkpark
#    migration plan (DRY RUN — nothing written)
#      from:    local [local] — http://localhost:4000
#      to:      barkpark [cloud] — https://api.barkpark.cloud
#      …
#    ⚠ target https://api.barkpark.cloud is CLOUD — a real run writes to a remote server.

# 2. Execute one type to a cloud target (prints the ⚠ guard, then writes)
bp --token "$TOKEN" migrate local barkpark --type post --yes

# 3. Pull a remote down to local, schemas first, as a JSON receipt
bp migrate prod local --include-schemas --yes -o json | jq '.total_migrated, .errors'
```
