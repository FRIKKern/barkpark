<!-- doc-tier: agent | canonical-for: cli-m0-contract-decisions | budget: 1300tok -->
# Barkpark CLI — M0 contract decisions (DECIDED)

Approved at M0; binding for Wave 2+. Field names are the frozen
`manifest.schema.json` names.

## Part A — operational decisions

- **A1 · `--dry-run` is client-side request-printing in v1.** Manifest `dry_run` ships `false` on every command. The CLI prints the resolved method, path (`http.path_template` filled), headers, and body; announces "dry-run: client-side preview only"; exits `0`. Deferred: server validate-only — a `dry_run: true` command makes the CLI send the validate-only marker instead (rule C5).
- **A2 · Dataset discovery assumes `production` default.** `:dataset` resolves to `production` unless overridden by `-d/--dataset`, `BARKPARK_DATASET`, or the active context. No dataset listing in v1; a `datasets` discovery surface is deferred (no server surface lists datasets today).
- **A3 · `whoami` = `GET /v1/meta` + manifest top-level `auth_tier`; no new endpoint.** Shows active target (`base_url`, workspace/project/dataset, `⚠ PROD`) + caller `auth_tier` from the manifest; identity/time/schema-hash from `/v1/meta`. Deferred: dedicated identity endpoint (both halves already exist; plan open decision #6).

## Part B — forward-seams (shape locked, NOT built)

- **B1 · Plugin `kind` taxonomy: `bundled | declarative | code | external`.** Only `bundled` ships in v1 (`bulldocs`, `onixedit`, `frt`, `media` — compiled in, discovered from `priv/plugins/*/plugin.json`). Adding a non-bundled kind is additive; command provenance (`source: plugin:<name>`) stays stable.
- **B2 · Registry sources = disk AND DB.** v1 `Registry.all/0` walks disk only; the capabilities controller folds registry + `collect_*` outputs source-agnostically, so a later DB-backed install table is invisible to consumers.
- **B3 · Dynamic dispatcher `/v1/plugins/:slug/*` anticipated.** v1 compiles concrete routes at boot (`Registry.collect_routes/1`); the manifest emits each flat `http.path_template`, so a runtime dispatcher is a server-side detail the CLI never sees.

## Part C — five non-negotiable contract rules

1. **Existence-hiding, default-deny allow-list.** `nouns[]`/`commands[]` (and any enum surface) project through one default-deny allow-list keyed on caller `auth_tier`. An anonymous caller learns zero admin noun names or routes. A golden test enforces it.
2. **`scoped_admin` ≠ `admin` — the CLI never client-preflight-refuses it.** Only the server knows per-workspace roles (`RequireWorkspaceRole`). Global tiers `read`/`write`/`admin` MAY be preflight-refused; `scoped_admin` may not.
3. **One error↔exit table.** One mapping from envelope `error.code` to CLI exit code (`error-exit-table.md`); never re-derived from HTTP status.
4. **Flat path templates; the `scoped_prefix` hint is INERT in v1.** Every `http.path_template` is FLAT and exactly what the CLI calls. The CLI does NOT prepend `scoped_prefix` — prepending `/w/:ws/p/:project` onto a flat-only server 404/403s every core command. Prepend activates only when a server advertises the mirror (`Context.ScopedMirror`, false in v1).
5. **`dry_run` is honest.** `true` ONLY when the server genuinely supports validate-only for that command; `false` across the board in v1 (see A1).

## Part D — manifest-projection rules (rescued from `cli-commands-callback.md`)

Two wire rules from the archived `cli_commands/0` contract (§4 steps 3–4);
implemented in `Barkpark.Plugins.Capabilities` (code-verified).

- **D1 · `scoped_admin` no-blanket-hide.** The projection must NOT hide a `scoped_admin` command from a token that *might* hold a per-workspace role — only the server knows the role at request time; never a blanket client-side deny. As implemented: `Capabilities.visible?("scoped_admin", caller_tier)` keeps the command for any caller at global rank ≥ `read`; only `none` callers lose it. Server-side twin of rule C2.
- **D2 · Content-addressed, tier-projected ETag.** Projected `commands[]`/`nouns[]` differ per tier, so the `etag` is content-addressed over the projected document — admin and public manifests carry different etags (drives `304` + tier-keyed on-disk cache). As implemented: `Capabilities.project/2` recomputes the etag over the projected map minus `etag`/`generated_at` (SHA-256, first 16 hex chars, weak validator `W/"caps-<digest>"`); `CapabilitiesController.index/2` honors `If-None-Match` (lists and `*`) → `304`, empty body.

## Schema field references

Top-level `auth_tier` (caller echo, A3) + `manifest_version`; per-command
`dry_run` (A1), `auth_tier` (C1/C2), `http.path_template` + `scoped_prefix`
(C4, B3), `default_output`; noun `plugin` (B1). `datasets` (A2) is intentionally
**absent** — adding it later is additive within `manifest_version: "1"`.

## Code anchors

- `api/lib/barkpark/plugins/capabilities.ex` — `visible?/2`, `project/2`, `etag_for/1`, `tier_for_token/1`
- `api/lib/barkpark_web/controllers/capabilities_controller.ex` — `index/2`, `etag_matches?/2`
- `internal/cli/builtins.go` — `runWhoami` (A3), `runCapabilities`
- `docs/cli/manifest.schema.json` — the frozen field names
