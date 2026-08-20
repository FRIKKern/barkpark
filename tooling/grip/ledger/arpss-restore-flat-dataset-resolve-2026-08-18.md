# Re-derivation: flat restore/revision READ dataset-resolution (arpss)

Verdict: BENIGN — the flat `GET /v1/data/revision/:dataset/:id` READ (and the READ
that feeds flat restore) resolves `dataset` to **Default's dataset_id only**, so it
cannot surface a foreign-workspace-B revision by id. Identical exposure to the
sibling flat revision GET; governed by the existing pdf-bl-anon Default-pool ruling,
NOT a new finding. No fail-closed dataset-resolution fix warranted.

## Re-derive on origin/main

    # 1. Flat route pipelines carry NO ResolveWorkspace → opts has no :workspace_id key
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1794p;1880p'
    #   1794: get("/revision/:dataset/:id", HistoryController, :show)   [:api,:require_token]
    #   1880: post("/revision/:dataset/:id/restore", ...)               [:api,:require_token,:require_write]

    # 2. scope_opts only puts :workspace_id when current_workspace assign is present
    git show origin/main:api/lib/barkpark_web/plugs/scope_helpers.ex | sed -n '68,87p'
    #   put_scope(opts, :workspace_id, nil) -> opts unchanged  => key ABSENT on flat route

    # 3. resolve_read_dataset_id: workspace_id key ABSENT => project_id falls to Default
    git show origin/main:api/lib/barkpark/content/write_scope.ex | sed -n '291,332p'
    #   cond: project_id opt? no. has_key(:workspace_id)? NO. true -> read_default_project_id
    #   get_dataset(default_proj, dataset) -> Default's dataset_id (or nil)

    # 4. get_dataset is project-scoped (cannot match another workspace's row)
    git show origin/main:api/lib/barkpark/tenancy.ex | sed -n '1037,1039p'
    #   Repo.get_by(Dataset, project_id: project_id, slug: slug)

    # 5. scope_to_dataset applies strict dataset_id == Default_ds_id (OR legacy nil)
    git show origin/main:api/lib/barkpark/content/revisions.ex | sed -n '118,127p'

## Mutation reasoning (load-bearing clamp, no DB run needed)

The Default-project resolution at write_scope.ex:308 (`true -> read_default_project_id`)
is load-bearing. Revert it to return a nil project_id and resolve_read_dataset_id
returns nil → scope_to_dataset drops to the bare `x.dataset == ^dataset` STRING filter,
which matches EVERY workspace's same-slug dataset rows; combined with
scope_to_workspace_or_global(nil) fail-open, a flat token would then read workspace-B
revisions sharing the slug. The Default-project resolution is exactly what clamps the
read to Default's own dataset_id. A workspace-B revision carries its own distinct
dataset_id (≠ Default's), so under the real (unreverted) code it is excluded.
