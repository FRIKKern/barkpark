# Barkpark CLI — M0 Contract Decisions (DECIDED)

> **Status:** DECIDED. The user approved these defaults at M0. They are recorded
> here as binding for Wave 2 and beyond. Each decision states: the decision, the
> v1 behaviour, the deferred part, and a one-line rationale. All field names below
> are the frozen names from `manifest.schema.json`.

## Part A — Three operational decisions

### A1 · `--dry-run` is client-side request-printing for v1

- **Decision:** The CLI's `--dry-run` flag prints the request it *would* send and
  says so; it does NOT call a server validate-only endpoint. The manifest's
  per-command `dry_run` field ships **`false`** on every command in v1, unless a
  command is genuinely server-validate-only.
- **v1 behaviour:** `--dry-run` renders the resolved method, path
  (`http.path_template` with placeholders filled + any `scoped_prefix` prepended),
  headers (tier-appropriate), and body, then exits `0` without making the call.
  The CLI reads `dry_run` from the manifest; since it is `false`, it announces
  "dry-run: client-side preview only (server validate-only not available)".
- **Deferred:** Real server validate-only. When the batch team builds it for a
  command, that command's manifest `dry_run` flips to `true` and the CLI sends the
  request with the server's validate-only marker instead of printing.
- **Rationale:** No server validate-only exists today, so an "honest" `dry_run`
  must not claim a capability the server lacks (contract spine rule #5).

### A2 · Dataset discovery assumes `production` default for v1

- **Decision:** The CLI assumes the `production` dataset by default. A `datasets`
  field/endpoint is added later; v1 ships no dataset listing.
- **v1 behaviour:** `:dataset` resolves to `production` unless overridden by
  `-d/--dataset`, `BARKPARK_DATASET`, or the active context. No command enumerates
  available datasets.
- **Deferred:** A `datasets` discovery surface — either a manifest field or a
  dedicated endpoint — so `workspace datasets` can list real datasets.
- **Rationale:** No server surface lists datasets today; hardcoding the known
  `production` default keeps v1 shippable without inventing an endpoint.

### A3 · `whoami` reuses `/v1/meta` + manifest `auth_tier` — no new endpoint

- **Decision:** `barkpark whoami` is composed from the existing `GET /v1/meta`
  handshake plus the manifest's top-level `auth_tier` (the caller-tier echo). No
  new `/v1/auth/whoami` endpoint is built in v1.
- **v1 behaviour:** `whoami` shows the active target (server `base_url`,
  workspace/project/dataset, `⚠ PROD` when prod) and the caller's resolved
  `auth_tier` read from the manifest. Server identity/time/schema-hash come from
  `/v1/meta`.
- **Deferred:** A dedicated identity endpoint (token name, membership list,
  per-workspace roles) if a richer `whoami` is demanded.
- **Rationale:** The manifest already echoes the caller's tier and `/v1/meta`
  already returns server identity — a new endpoint would duplicate both
  (plan open decision #6).

## Part B — Three forward-seams (design-only, shape locked now, NOT built)

These lock the *shape* so v1 artifacts (manifest + CLI tree) don't have to break
later. None of them is implemented in v1.

### B1 · Plugin `kind` taxonomy — `bundled | declarative | code | external`

- **Decision:** Reserve a plugin `kind` taxonomy with four values. Only `bundled`
  ships in v1.
- **v1 behaviour:** Every plugin contributing nouns/commands today
  (`bulldocs`, `onixedit`, `frt`, `media`) is `kind: bundled` (compiled into the
  host, discovered from disk `priv/plugins/*/plugin.json`). The manifest's noun
  `plugin` field carries the slug; the kind is implicitly `bundled`.
- **Deferred:** `declarative` (config-only schema/route specs), `code`
  (out-of-tree compiled plugins), `external` (remote/HTTP-dispatched plugins). The
  manifest and `cli_commands/0` shape are designed so adding a non-bundled kind is
  additive — a new `kind` value does not change the per-command schema.
- **Rationale:** Naming the taxonomy now lets the manifest's command provenance
  (`source: plugin:<name>`) stay stable when non-bundled plugins arrive.

### B2 · Registry sources = disk AND DB

- **Decision:** Build the manifest/tree assembly assuming the live plugin set MAY
  come from a DB install table later, even though discovery is disk-only today.
- **v1 behaviour:** `Registry.all/0` walks disk
  (`priv/plugins/*/plugin.json`, the `:barkpark, :plugins` config key unset). The
  capabilities controller folds `Registry.all/0` + `collect_*` outputs without
  assuming *where* the registry sourced its plugins.
- **Deferred:** A DB-backed install table as an additional (or replacement)
  registry source. Nothing in the manifest projection reads the disk path
  directly, so swapping/adding a DB source is invisible to consumers.
- **Rationale:** Keeping the assembler source-agnostic now avoids a rewrite when
  installs become dynamic/per-tenant.

### B3 · Dynamic-route dispatcher `/v1/plugins/:slug/*`

- **Decision:** Anticipate a dynamic plugin-route dispatcher at
  `/v1/plugins/:slug/*` in the manifest and tree shape.
- **v1 behaviour:** Plugin HTTP routes are compiled in at boot via
  `Registry.collect_routes/1` (each emitted as a concrete Phoenix route, e.g.
  bulldocs ingest at `/v1/plugins/bulldocs/papers`). The manifest emits each
  concrete `http.path_template` per command — flat, real, today's routes.
- **Deferred:** A single runtime dispatcher that routes `/v1/plugins/:slug/*` to a
  plugin handler without a compiled route per path. Because commands carry their
  own `http.path_template`, the CLI works identically whether the path is
  compile-time-mounted or runtime-dispatched.
- **Rationale:** The manifest already abstracts "what call does this command make"
  behind `http.path_template`, so a dispatcher is a server-side implementation
  detail the CLI never sees.

## Part C — The five non-negotiable contract rules (restated)

These are the invariants every Wave-2 deliverable must uphold.

1. **Existence-hiding, default-deny allow-list.** The manifest projects `nouns[]`
   and `commands[]` (and any enum surface) through one default-deny allow-list
   keyed on the caller's `auth_tier`. An anonymous caller learns zero admin noun
   names or routes. A golden test enforces it.

2. **`scoped_admin` is distinct from `admin` — CLI never client-preflight-refuses
   it.** A command's `auth_tier` may be `scoped_admin` (per-workspace role,
   `RequireWorkspaceRole`). The CLI MUST NOT refuse it client-side — only the
   server knows the caller's per-workspace role. (Global tiers `read`/`write`/
   `admin` MAY be preflight-refused; `scoped_admin` may not.)

3. **One error↔exit table.** Exactly one mapping from envelope `error.code` to CLI
   exit code (`error-exit-table.md`). The CLI maps the `code`, never re-derives
   from HTTP status.

4. **Flat path templates; the `scoped_prefix` hint is INERT in v1.** Every
   command's `http.path_template` is FLAT and is exactly what the CLI calls in v1.
   A command MAY carry a `scoped_prefix` hint, but because the scoped *mirror
   endpoint* is deferred (it exists on no server today), the CLI does **NOT**
   prepend it in v1 — prepending `/w/:ws/p/:project` onto a flat-only server turns
   `/v1/data/...` into `/w/default/p/default/v1/data/...`, which 404/403s and would
   break every core command. The hint ships in the manifest for
   forward-compatibility; the CLI activates the prepend only when a server
   advertises the mirror (gated by `Context.ScopedMirror`, false in v1).

5. **`dry_run` is honest.** The manifest's `dry_run` is `true` ONLY when the server
   genuinely supports validate-only for that command. It ships `false` across the
   board in v1; the CLI's `--dry-run` degrades to client-side request-printing and
   says so.

## Schema field references

Every decision above is expressed in the frozen `manifest.schema.json` field
names: top-level `auth_tier` (caller echo, used by A3) and `manifest_version`;
per-command `dry_run` (A1), `auth_tier` (rules 2 & C), `http.path_template` +
`scoped_prefix` (rule 4, B3), `default_output`, and noun `plugin` (B1). The
deferred `datasets` surface (A2) is intentionally **absent** from the frozen
schema — adding it later is an additive bump within `manifest_version: "1"`.
