<!-- doc-tier: agent | canonical-for: bp-cli-handbook | budget: 1800tok -->
# Barkpark `bp` CLI — Handbook (M4 GA)

> The same Go binary is the interactive TUI (no args) and the CLI (with a command). Source: `internal/cli/`, `internal/manifest/`. Frozen contracts: `docs/cli/manifest.schema.json`, `docs/cli/m0-decisions.md`, `docs/cli/error-exit-table.md`.

---

## Install & upgrade

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp version   # -> barkpark <version>
```

Detects OS (`darwin`/`linux`) + arch (`arm64`/`amd64`), installs to `/usr/local/bin` (fallback `~/.local/bin`), sha256-verifies against the release's `checksums.txt`. Wizard walkthrough: `docs/setup/QUICKSTART.md`.

| Env | Effect |
|---|---|
| `BARKPARK_CLI_VERSION` | pin a release, e.g. `1.0.1` (installer only) |
| `BARKPARK_CLI_RELEASE_BASE` | mirror override — asset DIR for the installer, release-tree ROOT for `bp upgrade` |
| `BARKPARK_BIN_DIR` | install dir |

`bp upgrade` self-updates from the latest `cli-v*` GitHub release: redirect-based latest detection (no API), sha256-verified, atomic same-dir rename; refuses on `dev` builds; on EACCES prints the sudo re-install one-liner. `bp upgrade --check` prints current vs latest — exit 1 when behind. After an eligible command bp may print one quiet **stderr** notice pointing at `bp upgrade` when a newer `cli-v*` release exists — checked at most once per interval, announced once per release, silent on any failure; never touches stdout or exit codes.

**Release runbook:** tag `cli-vX.Y.Z` → the `cli-release` workflow runs `go test`, cross-compiles 6 binaries (darwin/linux arm64+amd64, windows amd64+arm64) + `checksums.txt`, publishes the GitHub Release (hyphenated versions get `--prerelease`, which `releases/latest` skips). Re-cut a botched release via workflow_dispatch with the tag. `cli-v*` owns `releases/latest` — the npm pipeline's `v1.*` tags create no GitHub Releases; keep it that way.

## Grammar

```
bp [global flags] <noun> <verb> [args] [command flags]
```

Command tree is a **pure function** of `GET /v1/capabilities` — plugins add noun/verb with zero client code change.

## Context precedence

```
flags  >  env (BARKPARK_*)  >  .barkpark.json (repo)  >  active context  >  defaults
```

Source: `manifest.Resolve` + `internal/cli/repofile.go`. Active context is persisted `config.json` (`bp setup`, `bp use <name>`). The repo layer is a `.barkpark.json` discovered by walking up from cwd (nearest wins): fields `server` (a saved-server name or URL — a name resolves like `-s <name>`, adopting the entry's token), `workspace`, `project`, `dataset` — each field independent, unknown keys ignored. A `token` field is **rejected loudly** — tokens never live in the repo file.

## Auth tiers

| `auth_tier` | What the CLI sends |
|---|---|
| `none` | nothing |
| `read` | bearer only when path is scoped |
| `write`/`admin`/`scoped_admin` | `Authorization: Bearer <token>` |
| `ingest` | `Authorization: Bearer <secret>` (reads `BARKPARK_INGEST_TOKEN` → bearer fallback) |

**`scoped_admin` is never client-refused** (M0 contract rule #2) — the server's 403 is surfaced cleanly.

## Core verbs (summary)

A **worked subset** — the tree is a pure function of the live manifest, so `bp capabilities`
(`GET /v1/capabilities`) is the authority and this table can only lag it. Nouns not broken
out below but carried by the manifest: `data`, `access`, `cycle`, `chat`, `github`, `fleet`
(`roster`/`beat`), `ticket` + `ticket-key` (cards/cli.md), and the `search`/`media` synonym,
settings and insights tuning verbs.

| Command | Tier |
|---|---|
| `bp doc get/ls/query/backlinks/related/history/revision/restore-revision/mutate/create/create-or-replace/create-if-not-exists/patch/publish/unpublish/discard-draft/delete` | none / write |
| `bp schema get/ls/apply/delete` | none / admin |
| `bp media ls/get/collections/collection-assets/add-member/remove-member/share-collection/revoke-share/relations/checkout/undo-checkout/search/suggest/update/upload/delete` | none / write |
| `bp search query` | none |
| `bp dataset stats` | read — dataset content overview (total docs, per-type published/draft, recent activity; SDK `getAnalytics`) |
| `bp listen [type,…]` | read — SSE live change feed (one JSON event per line; `/v1/data/listen`); resumes via `Last-Event-ID` on drop |
| `bp workspace ls/create/project-ls/project-create/dataset-ls/member-ls/member-add/member-rm/member-role` | read / scoped_admin |
| `bp webhook ls/get/create/update/delete/deliveries/replay/rotate/reenable/test-send` | admin / write — `test-send`/`replay` answer 200 with the verdict INSIDE the body (error-exit-table.md) |
| `bp token create/ls/revoke` | scoped_admin — mint, inventory and revoke workspace-bound API tokens |
| `bp plugin ls/settings` | read / admin |
| `bp bulldocs publish/patch/propose/intents/intent-processed` | ingest |
| `bp onixedit export` | admin |
| `bp task ls/ready/prime/events/get/claim/release/stamp/pulse/close/next/move/stage` | read (plugin:tasks) |
| `bp share ls/add/rm/link-ls/link-mint/link-revoke/token-ls/token-mint/token-revoke` | admin |
| `bp graph show/corpus/orphans/dangling/tasks` | read |
| `bp auth login/logout/me/register/verify-email/request-reset/reset/mfa-enroll/mfa-verify/mfa-disable` | user session — `docs/auth-user-sessions.md` |
| `bp secret ls/get/set/rm` + `scoped-ls/scoped-get/scoped-set/scoped-rm` | admin / scoped_admin (Cloud run-secrets, encrypted) |

## Share & graph

`bp share` manages **LAN scope shares** — `add` upserts a persisted share exposing a scope's surfaces (`--surfaces papers,docs,media`, `--access read|edit`); `ls` lists env-baseline + persisted shares; `rm` removes a persisted one (env shares unaffected).

`bp graph` inspects the **content reference graph** — `show <id>` traverses from a root doc (`--depth 1..5`, `--kinds`, `--sources` filters); `orphans` lists docs with no inbound/outbound edges; `dangling` lists broken references (targets unresolvable under the published lens); `tasks <id>` lists the tasks that cite a document (a paper's driven tasks) with their acceptance-criteria state.

## Output

`-o table|json|yaml|minimal` (or `--json`, `-q`). Default: `table` on TTY, `json` piped. The CLI **unwraps** `{"result":…}` envelopes.

Minimal receipts (writes, shape-keyed — never per-verb): `rev:`/`id:` lines when the body carries them; an `{"ok":true,"doc":{…}}` body prints the doc's identity line — `<doc_id>` plus `epoch=<n>` when the doc carries a claim fence, including a released claim whose worker is now null (e.g. `drafts.task-992199 epoch=2 rev=a1b2c3`); a 2xx `{"ok":false,"reason":…}` prints the reason token (e.g. `no_ready`, exit 0); otherwise a bare `ok`.

## `--dry-run` (client-side only in v1)

Prints the resolved request (method, URL, headers redacted, body) then exits 0 **without sending**. Always announces:

```
dry-run: client-side preview only (server validate-only not available)
```

The manifest's per-command `dry_run` is `false` everywhere in v1. Flips to `true` (sends the request) only when a server later supports validate-only for a command.

### Production write-guard

Writes against a prod-looking target (`prod`/`production`/`api.barkpark.cloud`) prompt `⚠ PROD: … Continue? [y/N]` unless `--yes`. `localhost`/`127.0.0.1`/`0.0.0.0` are never prod. Local UX only — does not client-refuse `scoped_admin`.

## Exit codes

Source of truth: `docs/cli/error-exit-table.md`, `internal/cli/errors.go`. The CLI **never** re-derives a CODED error's exit from HTTP status (contract rule #3); only a no-`code`, non-envelope body (a gateway/proxy page) keys off status as a last resort.

| Exit | When |
|---|---|
| 0 | success |
| 1 | generic / network / unknown error code |
| 2 | usage / bad args / malformed |
| 3 | auth / forbidden |
| 4 | not-found |
| 5 | validation |
| 6 | conflict / rev mismatch / precondition |
| 7 | rate-limited |
| 8 | server 5xx |

## `scoped_prefix` is INERT in v1

A command's manifest `scoped_prefix` hint does nothing in v1 — the CLI calls the flat `http.path_template`. Prepending against a flat-only server 404/403s (contract rule #4, `manifest.BuildURL`). Activates only when a future server advertises the mirror (`Context.ScopedMirror`, currently `false` everywhere).

## `bp setup`

On-ramp CLI-native built-in (no manifest needed). Four targets:

| Target | Effect |
|---|---|
| `connect` | Points bp at an existing server; non-destructive |
| `local` | Brings up a local dev server (destructive — resets DB) |
| `deploy` | Installs Barkpark on a remote over SSH (destructive/outbound) |
| `provision` | STAGED — plans only unless provider CLI + credential + `--yes` present |

`--dry-run` prints the plan object (`-o json` → machine-readable Plan). `--yes` gates destructive/outbound runs. Wizard on bare `bp setup` only when stdin+stdout are a TTY with no `--target`/`-o json`/`--yes`.

Server cache: every successful `connect` upserts into `known_servers` in `~/.config/barkpark/config.json` (0600, 0700 dir; tokens never exposed). `bp use <name>` switches the active server. `bp servers` lists all. `-s <name>` targets one command without switching. A committed `.barkpark.json` (`{"server":"<name-or-url>"}`) pins a whole repo without switching (see Context precedence).

## `bp migrate`

Copies documents between saved servers. Dry-run by default; `--yes` gates writes. Cloud-target guard prints `⚠ writing N docs to <url> [cloud]`. Uses `createOrReplace` mutations keyed by `_id` (both drafts and published via `perspective=raw`). 50 docs/batch, paged 100 at a time from source.

```bash
bp migrate local barkpark               # dry-run plan (nothing written)
bp migrate local barkpark --type post --yes   # execute one type
bp migrate prod local --include-schemas --yes -o json
```

## `bp make` · `bp seed` · `bp tinker` (authoring + dev built-ins)

CLI-native built-ins (no manifest), like `setup`/`migrate`:
- `bp make schema <name>` — print a fill-the-blanks **schema v2 JSON skeleton** (stdout or file; purely local, no network).
- `bp seed <type> [--count N] [--publish]` — fabricate schema-valid sample docs as **drafts** (honours the prod write-guard); `--publish` also publishes them so they're visible to the public read API.
- `bp tinker [--dataset <ds>]` — interactive authenticated **REPL** (query/doc/mutate) against a live dataset.
- `bp export [--type <t>] [--perspective <p>] [--out <file>]` — stream the active dataset as **NDJSON** (one doc per line) for backup: `bp export > backup.ndjson`. CLI twin of the SDK `exportDataset`. `--out` streams into `<file>.partial` (same directory, so the promoting rename is atomic) and moves it onto `<file>` **only after a clean completion**, followed by its `<file>.meta` sidecar `{documents,bytes,sha256,scope,completed_at}` — artifact renamed first, the stale sidecar removed, the new sidecar renamed LAST, so the only reachable in-between state is file-without-sidecar. A run that dies leaves the stub at `<file>.partial` and does **not** touch the backup already at `<file>` or its sidecar; a sidecar's ABSENCE is still the truncation signal on an unattended box. `bp export --verify <file>` re-derives sha/count/bytes from the artifact alone and **fails closed** on a missing, empty, unparsable or sha-less sidecar.

## Other built-ins (CLI-native, no manifest)

- `bp attach root@<host> --name <n>` (alias `bp register ssh root@<host> --name <n>`) — add a self-hosted server to local config; no network call.
- `bp uninstall [--local]` — remove bp's local state (config; `--local` also tears down the local dev stack). Never the binary, never a remote server.
- `bp paper view <slug>` — one-shot terminal render of a Bulldocs paper (headless counterpart to the browser reader).
- `bp instance credentials <id>` — retrieve a provisioned instance's admin token (team-admin-gated; needs `bp login`).
- `bp doctor [--name <handle>] [--url <url>]` — post-deploy health gate against the active/named server; exits non-zero on any failing check.
- `bp agent disable|uninstall [--name <handle>]` — local surface for the managed agent (renders the SSH command it would run; does not execute). `bp vercel quick-setup …` — stand up a Barkpark-backed site and ship it to Vercel in one shot.
- `bp deploy <site> --artifact-url <url>` — enqueue a deployment for a hosted site through the control plane (needs `bp login`).
- `bp cloud hetzner <resource> <verb>` — direct Hetzner control via the provider's own API (server: list/get/create/delete/poweron/poweroff; ssh-key: list/get/create/delete; read-only discovery: server-types/locations/datacenters/images/isos/pricing). No control plane, no `bp login` Plus `instance`: archive/archives/decommission/resurrect/adopt/eject/audit + export/import — whole-instance fleet lifecycle (server + DNS record + registry row as one unit, so teardown/move never strands half; `export`/`import` make an instance portable migrate-to-anywhere).
- `bp mcp serve [--tools tasks|all]` — run a **stdio MCP server** so Cursor and any MCP client reach Barkpark as first-class tools. `tasks` (default) exposes the eight curated task tools (`task_ready`/`task_next`/`task_show`/`task_close`/`task_create`/`task_prime`/`task_stamp`/`task_pulse`); `all` generates one tool per manifest verb (mind Cursor's 40-tool cap). The manifest is fetched once at startup; **stdout carries only JSON-RPC frames** — all chrome goes to stderr. Registration recipe: `docs/setup/CURSOR.md`.

## v1 deferrals

- `--dry-run` is client-side only; no server validate-only.
- Dataset discovery absent; `production` is the assumed default.
- `login`/`signup` authenticate to Barkpark Cloud; `completion` generates bash/zsh/fish scripts (`bp completion bash|zsh|fish`); `bp --version`/`-V` prints the version offline.
- `scoped_prefix` is inert.
