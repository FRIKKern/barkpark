<!-- doc-tier: agent | canonical-for: deferral-ledger | budget: 400tok -->
# Deferred ledger

| What | State today | Gate to activate |
|---|---|---|
| `@barkpark/groq` | 1.1 roadmap; `0.0.0-placeholder`; runtime import throws. 1.0 uses `@barkpark/core` filter-builder DSL | 1.1 |
| `@barkpark/nextjs-query` | 1.1 roadmap; placeholder. 1.0: `useOptimisticDocument()` from `@barkpark/nextjs/actions` | 1.1 |
| twoslash | `twoslash.yml` runs — its guard now finds `js/docs/` and builds it; the twoslash transformer itself is still unwired (no `transformerTwoslash` in `source.config.ts`, no `twoslash` fences) | docs snippets adopt twoslash fences |
| bp CLI `scoped_prefix` | LIVE for the scoped tiers — `Manifest.BuildURL` prepends it when `isScopedTier(cmd.AuthTier)` OR `Context.ScopedMirror`; a scoped-tier command that did NOT compose it hit a non-existent flat path and 404'd. The global tiers (`none`/`read`/`write`/`admin`) still wait on the mirror | scoped mirror endpoint ships — for the GLOBAL tiers only |
| schema-v2 Phase 1+ | Oban+cloak_ecto wiring (schema-v2-specific), Thema tree picker, Simplified/Advanced toggle, drag reorder | feature demand |
| search Phase 9 (scale) | not started | events > 5M/scope OR prune > 30s OR suggest p95 > 50ms at 100k events |
| search Phase 10 (retriever) | SHIPPED, not a spike: `Barkpark.Plugins.Indx.Retriever` rides the `Barkpark.Search.Retriever` seam and is registered by default (`config :barkpark, :search_retrievers`), reachable as `?engine=indx`. Intelligence did stay in Postgres — the retriever records no events | n/a — landed |
| `/v1/paperflow/*` alias | back-compat alias of `/v1/plugins/bulldocs/*`; ingest auth via `BARKPARK_INGEST_TOKEN` (legacy `PAPERFLOW_INGEST_TOKEN` still honored) | drop only after legacy external producers repoint |
| TUI media browse + sharing UI | parity sprint closed gaps 1–7 (publish/create/delete/task c·x/ref picker//search/y dup, cli-v1.4.0); media + share management (incl. per-doc item-share links) stay Studio/`bp` | demand — terminal-niche |
| TUI long-tail vs Studio | content preview, secondary pane, object-array rows (string-array + multiline text/richText editing shipped 2026-06-12; diff, history, ws/proj-create, bulk 06-11) — Studio is the rich desk; TUI covers the solo edit loop incl. the full draft lifecycle (publish/unpublish/discard, 2026-06-11 audit) | demand per item |
| CLI long-tail | only `doc.duplicate` is still absent (use a `create` mutation with the content). The history verbs (`doc.history`, `doc.revision`, `doc.restore-revision`) and the item-share verbs (`share.link-mint`, `share.link-ls`, `share.link-revoke`) are both in the capabilities manifest | demand |
| ADR-002 edge contract vs `node:crypto` | `webhook/` ported to Web Crypto via `@barkpark/core` (#498, now Edge-compatible); only `draft-mode/` still imports `node:crypto` (sync `signDraftModeToken`) — found 2026-06-11 when js CI first ran `check-no-node-imports.sh` (advisory step in js-tests.yml). Conform = Web Crypto port (breaks sync `signDraftModeToken`); relax = amendment ADR | owner decision: port or amend |
| Studio task claim/close buttons | DESIGN, not a gap: fenced claim/close belong to the API/agents; humans steer via the lifecycle dropdown (TASK-SYSTEM division of labour) | n/a |
| workspace/project delete **verb** | server-side cascade SHIPPED (`Tenancy.delete_workspace/1` — tenancy.md §Safe delete; no `delete_project/1`); the API verb SHIPPED — `DELETE /workspaces/:workspace_slug` → `WorkspaceController.delete/2` → `Tenancy.delete_workspace/1`; no CLI verb carries it in the capabilities manifest | demand — a `workspace.delete` CLI verb |

## Code anchors

- `internal/manifest/url.go` — scoped_prefix hint
- `api/lib/barkpark_web/router.ex` — `scope "/v1/paperflow"`
- `api/lib/barkpark/search/intelligence.ex` — `@retention_days`

<!-- fan-out diet 2 proof: OUT-OF-PATH probe commit. Reverted with the branch. -->
