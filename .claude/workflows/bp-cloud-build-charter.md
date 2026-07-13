<!-- doc-tier: agent | canonical-for: perfect-plan-build-epic | budget: 6000tok -->
# Perfect Plan BUILD — Epic Charter

The epic that turns the research shelf into shipped Barkpark Cloud product code. Execution of
`/papers/perfect-plan-readiness-ledger` (ratified 2026-07-12). Research verdicts:
`/papers/one-shot-onboarding`, `/papers/barkpark-estate`, `/papers/shared-cells`,
`/papers/workspace-bundle-keystone`, `/papers/quota-suspend-seams`. Research epic:
`bp-cloud-research-epic`. This epic: `bp-cloud-build-epic`.

## Vision

A Cloud operator can export ANY workspace into one complete, self-describing bundle and re-import it
into a clean instance with ZERO silent loss — completeness PROVEN by an information_schema +
pg_constraint diff plus count-parity on a real seeded round-trip (export → import → diff), never
asserted by grep. That bundle is the shared foundation five consumers inherit (backup, eject,
rebalance, graduation, migration). On top of it: a per-workspace quota + telemetry gate at the one
router seam that covers both content and media writes, and the HTTP + teardown plumbing the
destructive consumers need. Steps 4-7 (playground safety, host-header tenancy, migration
orchestration, content edge cache) follow in later waves.

## Decisions

Each decision is a measured verdict from the verify fleet (proofs in the wave Paper), not a preference.

- **D1 — Extend bp-export-v1's shape (tar + manifest.json + per-table dumps), scoped one grain finer to a workspace.** Why: the keystone paper names it; bp-bundle-v1 / archive_store.ex / backup.go are sibling formats three surveys flagged as the wrong target.
- **D2 — Byte carrier = per-table `COPY (SELECT <non-generated cols> WHERE workspace_id=$ws) TO`, re-imported under `SET session_replication_role = replica`.** Why: proven empirically — `pg_dump --format=custom` has NO per-row/per-workspace filter (dumps whole table); the CTAS/view workaround freezes generated columns and is strictly worse; column-list COPY round-trips byte-identical (md5-equal) and FK-valid.
- **D3 — Exclude generated columns from the COPY column list, derived LIVE from `information_schema.columns WHERE is_generated='ALWAYS'` (today only `documents.search_vector`).** Why: `COPY (SELECT *)` emits search_vector → import fails "extra data after last expected column"; under a column-list COPY Postgres re-generates it (5940/5940 non-null proven).
- **D4 — Three live-derived enumerations, never hardcoded. E1 = workspace_id column scan (19 today; `roles` is the 19th; `audit_events`+`audit_export_sinks` carry the column with ZERO FK). E2 = recursive pg_constraint FK-walk (6: content_edges, datasets, plugin_doc_state, role_permissions, task_edges, webhook_deliveries). E3 = `dataset`-column scan minus workspace_id (9) PLUS an explicit allowlist for the two `scope`-column dataset-scoped tables `data_keys` and `search_surface_config`.** Why: the E3 survey contradiction is SETTLED — the mechanical 9 is correct AND misses `data_keys` (holds the per-dataset DEKs; drop it → exported ciphertext is permanently undecryptable) and `search_surface_config`, both scoped by a column named `scope` not `dataset`.
- **D5 — The E3 slug→uuid resolver handles TWO key shapes: bare slug (E3 + search_surface_config) and `"dataset:"`-prefixed slug (data_keys). Explicit EXCLUDE list for residual backup tables and admin/host tables (chat_sessions/chat_messages, secrets, idempotency_keys, organizations).** Why: chat_sessions/messages are proven admin/host state with NO tenancy column and NO HTTP route ever; the *_backup tables and org rows roll above workspace grain.
- **D6 — E3 slug-map is a `WHERE EXISTS` semi-join / `SELECT DISTINCT (doc_id,dataset)`, NEVER a plain JOIN — in BOTH the exporter and the completeness gate.** Why: proven fan-out — `documents` unique key is (doc_id,type,dataset_id), so a workspace can hold 2+ docs sharing (doc_id,dataset); a naive JOIN counted 3 vs truth 2.
- **D7 — E3 import = `INSERT ... ON CONFLICT DO NOTHING`.** Why: proven — (doc_id,dataset) is NOT workspace-unique; the same authoring_exemptions row maps to two workspaces, so a second workspace's bundle would crash a plain INSERT.
- **D8 — Exporter requires a NON-NIL workspace_id and uses `Content.Scope.scope_to_workspace` (fail-CLOSED, `where(false)` on nil), NEVER `scope_to_workspace_or_global`.** Why: proven — `_or_global(nil)` routes to `scope_to_workspace_global(q) = q` (fully unscoped, ALL tenants) → cross-tenant LEAK into a single-workspace bundle. A leak-shaped negative test guards it.
- **D9 — `Envelope.render` is NOT in the byte path — the documents member carries RAW rows.** Why: proven — render synthesizes `_draft`/`_publishedId`, merges `title`, drops `status` + all tenancy columns, and `_id`=doc_id not the uuid PK; re-inserting its output corrupts the round-trip. Render is reserved for an optional redacted human companion only.
- **D10 — Completeness-diff acceptance gate (mechanical, not grep), run as an ExUnit round-trip: (a) information_schema + pg_constraint partition is EXACT and re-run as a catalog diff with a pinned total-base-table sentinel that RAISES on drift; (b) per-table count-parity `count(export) == count(WHERE workspace_id=$ws)` — direct for E1, parent-join for E2, semi-join for E3; (c) md5(non-generated-columns) parity src-vs-dst.** Why: proven buildable and runnable — an injected tenant table flipped E1 19→20 and the sentinel fired loudly. Row counts are NEVER hardcoded (authoring_exemptions drifts 5454 dev / ~1165 guerrilla).
- **D11 — Quota + per-workspace telemetry = a NEW `RequireWithinQuota` plug AFTER `ResolveWorkspace` in BOTH `:scoped_mutate` AND `:scoped_media_mutate` (no shared base — media bypasses the Content context).** Why: a Content-context hook is REFUTED because media writes go straight to `Barkpark.Media.upload/3` (raw Repo.insert), never through `Content.apply_mutations`; the two scoped pipelines are the one seam that sees both.
- **D12 — Meter = a workspace TAG on EXISTING telemetry, not a new system. Content: add workspace_id to the two live spans (`[:barkpark,:content,:mutate]`, `[:barkpark,:content,:lifecycle]`) + tag the Prometheus distributions. Media: a NEW `:telemetry.execute` at the plug seam (media path emits zero telemetry today).** Why: the value is already in `opts` via `scope_opts(conn)`; content-side is a one-key extension, media-side needs one new emission because it has no span.
- **D13 — Quota state lives in NEW `workspaces` columns (suspended/suspended_reason/suspended_at + quota) via a new migration, and quota context functions live in a NEW `Barkpark.Tenancy.Quota` module (not tenancy.ex).** Why: greenfield at the schema layer (workspaces has only id/slug/name/settings today); a separate module keeps tenancy.ex out of the quota slice's file set so it parallelizes with the delete/audit slices.
- **D14 — The flat standalone `:media_mutate` routes (legacy `/media/*`, `/v1/media/:dataset/*`) are a KNOWN, DOCUMENTED quota gap this wave, filed as backlog — NOT closed.** Why: proven — that pipeline has no `ResolveWorkspace`; it uses `AssignDefaultScope` (seeded Default Workspace), so a quota plug there would MISATTRIBUTE writes. Closing it means adding dataset→workspace derivation to a back-compat pipeline (SDK back-compat blast radius) — step-4 territory.
- **D15 — Adopt the backlog code fixes as slices: `bl-workspace-delete-route` (HTTP DELETE, pairs with keystone's destructive consumers) and `bl-audit-fk-orphans` (sweep the two FK-less audit tables inside delete_workspace) as SEPARATE, file-disjoint slices; `bl-tenancy-doc-corrections` as the docs slice. `bl-preview-tags-crash-fix` is VERIFY-ONLY (already shipped 790aeaf0/PR#2790, tests green) — no builder, lead re-verifies on guerrilla and closes.** Why: delete-route touches router+controller, audit-sweep touches tenancy.ex — disjoint file sets build in parallel; the preview crash is fixed at source (`Preview.paper_tags/1` dual-shape reader).
- **D16 — Every builder isolates in a worktree (COPY `_build/test`, symlink `deps`, `CC=clang`, `MIX_ENV=test mix ecto.migrate` before any harness that seeds a new table); NEVER symlink `_build`. Every .ex/.exs/.heex change WAITS for the Elixir Test gate before merge. builder_model = opus on every slice (Fable spend-blocked this wave). Distrust vacuous green — the completeness gate must include the drift sentinel and the leak-negative test, or a pass is meaningless.** Why: the borrow recipe is proven green under a migration+new-module diff ONLY with COPY (symlink trips the `:media_upload_dir` compile_env boot abort); tenancy is high blast radius through Content.Scope.

## Roadmap

Dependency-ordered against `/papers/perfect-plan-readiness-ledger`. Step 1 (front door / install-cli) SHIPPED (PR #2797).

| Step | Slice | Wave | Size | Model |
|---|---|---|---|---|
| 2 | KEYSTONE — per-workspace export/import bundle + completeness-diff harness | **W1** | large | opus |
| 3 | QUOTA + per-workspace telemetry gate (router plug, both scoped pipelines) | **W1** | medium | opus |
| 2+ | Workspace DELETE route (bl-workspace-delete-route) | **W1** | medium | opus |
| 4- | Audit FK-orphan sweep in delete_workspace (bl-audit-fk-orphans) | **W1** | small | opus |
| — | Tenancy doc corrections (bl-tenancy-doc-corrections) | **W1** | small | opus |
| — | Preview weighted-tags crash (bl-preview-tags-crash-fix) | **W1** | verify-only | lead |
| 4 | Playground safety — anon tier, rate limit, quota, TTL reaper, full FK-less audit teardown | W2+ | — | — |
| 3+ | Flat `:media_mutate` quota hole — dataset→workspace derivation on the back-compat pipeline | W2+ | — | — |
| 2+ | delete_workspace reuses keystone enumeration to sweep E3 string-keyed tables (authoring_exemptions et al) | W2+ | — | — |
| 2+ | Go CLI `bp cloud workspace export/import` wrapping the Elixir bundle engine | W2+ | — | — |
| 5 | Host-header tenancy — plug ahead of ResolveWorkspace, dynamic check_origin (replaces boot-time static list, runtime.exs:595-602) | W3+ | — | — |
| 6 | Migration orchestration — measured dump/restore cutover (~60s write-freeze budget; NO streaming replication) | W3+ | — | — |
| 7 | Content edge cache — private cache-control + ETag-after-query + sync_tags-keyed purge | W4+ | — | — |

## Wave log

<!-- Each wave appends its debrief here at Review. Empty until Wave 1 closes. -->
