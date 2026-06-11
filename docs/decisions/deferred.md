<!-- doc-tier: agent | canonical-for: deferral-ledger | budget: 400tok -->
# Deferred ledger

| What | State today | Gate to activate |
|---|---|---|
| `@barkpark/groq` | 1.1 roadmap; `0.0.0-placeholder`; runtime import throws. 1.0 uses `@barkpark/core` filter-builder DSL | 1.1 |
| `@barkpark/nextjs-query` | 1.1 roadmap; placeholder. 1.0: `useOptimisticDocument()` from `@barkpark/nextjs/actions` | 1.1 |
| codegen | `schema-path` only **prints** the path — no schema fetch, no `barkpark.types.ts`, no `typedClient` (that lives in `@barkpark/core`) | demand |
| twoslash | `twoslash.yml` dormant — self-skips (no `apps/docs/`); `js/docs/` unwired | a docs app consumes the stubs |
| bp CLI `scoped_prefix` | inert in v1 — CLI must NOT prepend it until `Context.ScopedMirror` is true | scoped mirror endpoint ships |
| schema-v2 Phase 1+ | Oban+cloak_ecto wiring, error envelope v2 (`Accept-Version: 2`), Thema tree picker, Simplified/Advanced toggle, drag reorder | feature demand |
| search Phase 9 (scale) | not started | events > 5M/scope OR prune > 30s OR suggest p95 > 50ms at 100k events |
| search Phase 10 (retriever) | spike doc only; intelligence stays Postgres | >500k media assets OR fuzzy p95 > 100ms |
| `/v1/paperflow/*` alias | back-compat alias of `/v1/plugins/bulldocs/*`; `PAPERFLOW_INGEST_TOKEN` unchanged | drop only after paperflow `event-on-save.sh` repoints |
| TUI media browse + sharing UI | parity sprint closed gaps 1–7 (publish/create/delete/task c·x/ref picker//search/y dup, cli-v1.4.0); media + share management (incl. per-doc item-share links) stay Studio/`bp` | demand — terminal-niche |
| TUI long-tail vs Studio | history/revisions, bulk publish, diff view, content preview, secondary pane, array-row editing, workspace-create-in-selector — Studio is the rich desk; TUI covers the solo edit loop incl. the full draft lifecycle (publish/unpublish/discard, 2026-06-11 audit) | demand per item |
| CLI long-tail | no `doc.duplicate` (use a `create` mutation with the content), no history verb, no item-share verb | demand |
| Studio task claim/close buttons | DESIGN, not a gap: fenced claim/close belong to the API/agents; humans steer via the lifecycle dropdown (TASK-SYSTEM division of labour) | n/a |
| workspace/project delete | `workspace create / project-create` exist; no delete verb — spikes accumulate (server-side cascade: projects, datasets, docs, media, tokens) | demand — first user drowning in spikes |

## Code anchors

- `internal/manifest/url.go` — scoped_prefix hint
- `api/lib/barkpark_web/router.ex` — `scope "/v1/paperflow"`
- `api/lib/barkpark/search/intelligence.ex` — `@retention_days`
