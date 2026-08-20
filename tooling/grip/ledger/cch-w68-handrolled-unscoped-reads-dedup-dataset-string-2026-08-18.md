<!-- doc-tier: cold | canonical-for: none | budget: 1200tok -->
# handrolled-unscoped-reads sweep — dedup_wall dataset-string candidate (w68)

Verifier corner [handrolled-unscoped-reads] for epic api-read-path-security-sweep,
wave api-read-path-security-sweep-objauthz-wave-2026-08-18. Read-only on origin/main.
No commits by this verifier.

## The one candidate finding: DedupWall scans by raw `dataset` STRING, ignoring the scope in `opts`

Site: `api/lib/barkpark/content/dedup_wall.ex:356` (`do_fetch_candidates` →
`from(d in Document ...) |> maybe_filter_dataset(dataset)` where
`maybe_filter_dataset` = `where: d.dataset == ^dataset`, dedup_wall.ex:440).

Class: CROSS-TENANT-REACHABLE (PLAUSIBLE) — a paper/task TITLE + published doc_id
existence leak via the 409 `{:duplicate_of, payload}` on publish, crossing whenever
two workspaces/projects share a `documents.dataset` STRING value.

Re-derive the whole chain from clean origin/main:

    # 1. The scan keys on the raw dataset STRING, no workspace/project/dataset_id:
    git show origin/main:api/lib/barkpark/content/dedup_wall.ex | sed -n '354,374p'
    git show origin/main:api/lib/barkpark/content/dedup_wall.ex | sed -n '438,442p'

    # 2. `opts` DOES carry the write scope but dedup uses it ONLY for :timeout —
    #    build_ctx(opts) + enforce(...,opts) prove workspace_id/project_id are present:
    git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '120,145p'
    git show origin/main:api/lib/barkpark/content/authoring_wall.ex | sed -n '102,113p'
    git grep -n 'Keyword.get(opts' origin/main -- api/lib/barkpark/content/dedup_wall.ex
    #   → only :timeout / :dedup_timeout_ms; NEVER :workspace_id/:project_id

    # 3. Every SIBLING read that shares this opts applies Scope.scope_to_workspace(_or_global):
    git show origin/main:api/lib/barkpark_web/controllers/query_controller.ex | sed -n '239,247p'
    git show origin/main:api/lib/barkpark/plugins/github/relations.ex     | sed -n '378,382p'
    git show origin/main:api/lib/barkpark/tasks/query.ex                  | sed -n '244,246p'

    # 4. documents uniqueness FLIPPED to dataset_id — the raw string is NOT
    #    globally unique, so two projects can both hold dataset "production":
    git show origin/main:api/lib/barkpark/content/document.ex | sed -n '100,104p'
    git grep -n 'flip_uniqueness_to_dataset_id' origin/main -- api/priv/repo/migrations

Reachability gate (all three required): (a) ≥2 distinct workspaces/projects, each
publishing a WALLED type (paper|task — AuthoringWall @walled_types); (b) both stamp
the SAME `documents.dataset` string (e.g. the default "production"); (c) trgm-similar
titles. Then workspace-A's publish 409s with workspace-B's paper title +
`DraftId.published_id(incumbent.id)` in the `:similar` / `:duplicate_of` payload.

Suggested fix (mirror the siblings, fail-closed to the read path): pipe the candidate
query through `Content.Scope.scope_to_workspace_or_global(Keyword.get(opts,:workspace_id),
Keyword.get(opts,:project_id))` before Repo.all — a flat publish still pools into Default
(matches its own reads; the accepted residual), a scoped publish no longer scans foreign
workspaces' same-named datasets. Mutation-prove: seed two projects sharing dataset
"production" with near-title papers, assert A's publish returns 409 pre-fix and :ok
post-fix. Whether cross-workspace dataset-string collision on walled content is an
intended config is the SAME Default-shared-semantics product question already filed as
`arpss-flat-doc-mutate-default-scope-write` — fold there if it needs an owner ruling.

Structural twin (NOT a tenant surface today): `api/lib/barkpark/tasks/board.ex:227`
`load_task_docs/1` uses the identical `where: d.type=="task" and d.dataset==^dataset`
with no scope — but its only callers are `Tasks.Board`/`board_live.ex` (Studio LiveView,
admin-gated single-operator console), so it is SAFE-internal today. Same pattern would
leak if the Studio board ever became multi-tenant.

## Everything else in the corner: SAFE-internal or TENANCY-ENFORCED

- content/event_log.ex:116 `document_present?/2` — SAFE by design. Moduledoc: deliberately
  scope-free tombstone discriminator. Only caller listen_controller.ex:413 reaches it AFTER
  `Content.get_document(...scope)` already returned non-ok AND type is owner_scoped; returns
  a bare bool; the more-restrictive outcome (:drop) is what a wrong `true` yields. No tenant
  data crosses.
- content/dedup_wall.ex:356 — the finding above.
- content/schema.ex:70 `list_datasets` — project-scoped (`where: d.project_id==^project_id`).
- content/writer.ex:1225, content/lifecycle.ex:742, content/sessions.ex:85/174 — fenced CAS
  (`where: d.id==^existing.id and d.rev==^expected`) on a row already loaded in scope. SAFE.
- tasks/query.ex:244/475 — base queries; both pipe Scope.scope_to_workspace (moduledoc:
  "nil workspace yields zero rows"). TENANCY-ENFORCED.
- tasks/edges.ex:116/141, plugins/tasks.ex:1383 — graph traversal from an already-resolved
  in-scope task_id / from_id set via the Edge join. SAFE (from authorized node).
- tasks/board.ex:227/228 — Studio admin console (see twin note). SAFE-internal.
- tasks/fleet.ex:143/157/372 — `type:"listener"` fleet-presence rows, not tenant content.
  Global by design (`bp fleet roster/beat`). SAFE-internal.
- tasks/claim/close/compactor/dedup/internal/move/prime/queue/rail/ttl_sweeper — all
  reference scope_to_workspace/workspace_id/scope_opts (grep count >0 each). Threaded scope.
- studio_chat.ex:1805/1819/1828 (held_task_parent_id/published_task_doc/epic_slice_counts) —
  Studio Claude chat (admin console). Fleet/epic bookkeeping global by design. SAFE-internal.
- controllers/query_controller.ex:239 — Scope.scope_to_workspace + scope_opts. ENFORCED.
- controllers/tasks_controller.ex:282/411/1421/1426/1747 + params.ex:526 — every one threads
  `Params.maybe_filter_workspace/maybe_filter_project` (or fetch_task_exact's scoped base).
  ENFORCED.
- plugins/github/relations.ex:369 — Scope.scope_to_workspace_or_global(opts), documents its
  own default-scope fail-open (same class as the filed crown residual). SAFE.
- cycle_fleet.ex (2328/3012/3085/3216/4178), edge_projector/backfill.ex:118, mix/tasks/* —
  internal orchestration / Oban / mix ops, never an HTTP request handler. Global by design.
- plugins/tasks/web/board_live.ex:570/776 — Studio LiveView (admin). SAFE-internal.

Finding count from this corner: 1 candidate (dedup_wall.ex:356), PLAUSIBLE (needs a live
2-workspace reachability probe to confirm; static trace + opts-carries-unused-scope proven).
