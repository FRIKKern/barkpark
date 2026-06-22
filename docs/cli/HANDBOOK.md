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

`bp upgrade` self-updates from the latest `cli-v*` GitHub release: redirect-based latest detection (no API), sha256-verified, atomic same-dir rename; refuses on `dev` builds; on EACCES prints the sudo re-install one-liner. `bp upgrade --check` prints current vs latest — exit 1 when behind.

**Release runbook:** tag `cli-vX.Y.Z` → the `cli-release` workflow runs `go test`, cross-compiles 4 binaries + `checksums.txt`, publishes the GitHub Release (hyphenated versions get `--prerelease`, which `releases/latest` skips). Re-cut a botched release via workflow_dispatch with the tag. `cli-v*` owns `releases/latest` — the npm pipeline's `v1.*` tags create no GitHub Releases; keep it that way.

## Grammar

```
bp [global flags] <noun> <verb> [args] [command flags]
```

Command tree is a **pure function** of `GET /v1/capabilities` — plugins add noun/verb with zero client code change.

## Context precedence

```
flags  >  env (BARKPARK_*)  >  active context  >  defaults
```

Source: `manifest.Resolve`. Active context is persisted `config.json` (`bp setup`, `bp use <name>`).

## Auth tiers

| `auth_tier` | What the CLI sends |
|---|---|
| `none` | nothing |
| `read` | bearer only when path is scoped |
| `write`/`admin`/`scoped_admin` | `Authorization: Bearer <token>` |
| `ingest` | `Authorization: Bearer <secret>` (reads `BARKPARK_INGEST_TOKEN` → bearer fallback) |

**`scoped_admin` is never client-refused** (M0 contract rule #2) — the server's 403 is surfaced cleanly.

## Core verbs (summary)

| Command | Tier |
|---|---|
| `bp doc get/ls/query/mutate` | none / write |
| `bp schema get/apply` | none / admin |
| `bp media ls/upload` | none / write |
| `bp search query` | none |
| `bp workspace ls/project-create` | read / scoped_admin |
| `bp webhook ls/create` | admin / write |
| `bp plugin ls/settings` | read / admin |
| `bp bulldocs publish/patch/intents` | ingest |
| `bp onixedit export` | admin |
| `bp task ls/ready/get/claim/close/next` | read (plugin:tasks) |

## Output

`-o table|json|yaml|minimal` (or `--json`, `-q`). Default: `table` on TTY, `json` piped. The CLI **unwraps** `{"result":…}` envelopes.

Minimal receipts (writes, shape-keyed — never per-verb): `rev:`/`id:` lines when the body carries them; an `{"ok":true,"doc":{…}}` body prints the doc's identity line — `<doc_id>` plus `epoch=<n>` when the doc carries a claim (e.g. `drafts.task-992199 epoch=2`); a 2xx `{"ok":false,"reason":…}` prints the reason token (e.g. `no_ready`, exit 0); otherwise a bare `ok`.

## `--dry-run` (client-side only in v1)

Prints the resolved request (method, URL, headers redacted, body) then exits 0 **without sending**. Always announces:

```
dry-run: client-side preview only (server validate-only not available)
```

The manifest's per-command `dry_run` is `false` everywhere in v1. Flips to `true` (sends the request) only when a server later supports validate-only for a command.

### Production write-guard

Writes against a prod-looking target (`prod`/`production`/`api.barkpark.cloud`) prompt `⚠ PROD: … Continue? [y/N]` unless `--yes`. `localhost`/`127.0.0.1`/`0.0.0.0` are never prod. Local UX only — does not client-refuse `scoped_admin`.

## Exit codes

Source of truth: `docs/cli/error-exit-table.md`, `internal/cli/errors.go`. The CLI **never** re-derives from HTTP status (contract rule #3).

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

Server cache: every successful `connect` upserts into `known_servers` in `~/.config/barkpark/config.json` (0600, 0700 dir; tokens never exposed). `bp use <name>` switches the active server. `bp servers` lists all. `-s <name>` targets one command without switching.

## `bp migrate`

Copies documents between saved servers. Dry-run by default; `--yes` gates writes. Cloud-target guard prints `⚠ writing N docs to <url> [cloud]`. Uses `createOrReplace` mutations keyed by `_id` (both drafts and published via `perspective=raw`). 50 docs/batch, paged 100 at a time from source.

```bash
bp migrate local barkpark               # dry-run plan (nothing written)
bp migrate local barkpark --type post --yes   # execute one type
bp migrate prod local --include-schemas --yes -o json
```

## v1 deferrals

- `--dry-run` is client-side only; no server validate-only.
- Dataset discovery absent; `production` is the assumed default.
- `login` and `completion` are stubs.
- `scoped_prefix` is inert.
- Named contexts not persisted; no `context use`.
