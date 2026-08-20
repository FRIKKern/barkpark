<!-- doc-tier: cold | canonical-for: cch-w76-v6-w1-root-criteria-harden | budget: 900tok -->

# W1 epic-root criteria harden — re-derivation recipe (cch-w76 / V6)

Origin/main tip at derivation: `41b16d78db675abccde956954033e94c4a8de6b7`.

Purpose: give Decide file:line proof for the 4 W1 epic-root acceptance_criteria
(quota gate wired after ResolveWorkspace + before write, covering content AND
media; DELETE workspace route with audited teardown).

## Re-derive

    cd /Volumes/SATECHI/github/barkpark

    # 1. Quota plug exists, moduledoc states placement + dual coverage
    git show origin/main:api/lib/barkpark_web/plugs/require_within_quota.ex | sed -n '1,90p'

    # 2. Wiring ORDER in all 3 mutate pipelines (Resolve/Derive -> Quota -> WritePermission)
    git show origin/main:api/lib/barkpark_web/router.ex \
      | grep -n 'RequireWithinQuota\|ResolveWorkspace\|DeriveWorkspaceFromToken\|RequireWritePermission\|pipeline :scoped_mutate\|pipeline :scoped_media_mutate\|pipeline :media_mutate'
    # decisive lines:
    #   :scoped_mutate       262 ResolveWorkspace -> 273 RequireWithinQuota -> 274 RequireWritePermission
    #   :scoped_media_mutate 300 ResolveWorkspace -> 312 RequireWithinQuota(meter: :media) -> 317 RequireWritePermission
    #   :media_mutate        660 DeriveWorkspaceFromToken -> 661 AssignDefaultScope -> 667 RequireWithinQuota(meter: :media) -> 672 RequireWritePermission

    # 3. Media coverage commit (criterion 2 'content AND media')
    git log --oneline dfbcd9e755 -1
    #   dfbcd9e755 feat(cloud): Perfect Plan build W2 ... flat-media quota (#3027)
    # content side is #2886 (W1 :scoped_mutate quota seam)

    # 4. DELETE route + admin gate + teardown
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2585,2593p'   # delete .../:workspace_slug, pipe :api,:require_admin
    git show origin/main:api/lib/barkpark_web/controllers/workspace_controller.ex | sed -n '109,121p'  # delete/2
    git show origin/main:api/lib/barkpark/tenancy.ex | sed -n '1250,1310p'      # delete_workspace/1 transaction + do_delete_workspace/1

## Verdict

CONFIRMED: quota plug wired after workspace-resolve and before the write gate in
all three mutate pipelines; media covered via `meter: :media` on the two media
pipelines (#3027 dfbcd9e755); content via the :scoped_mutate seam (#2886).
DELETE /api/workspaces/:workspace_slug exists (router:2592), `:api,:require_admin`
gated, delegates to `Tenancy.delete_workspace/1` — a single rollback-on-failure
`Repo.transaction` cascade (zero orphans), deferred media-effect flush/drop.

NUANCE for Decide (criterion 4 'audited teardown'): teardown does NOT emit a
discrete `workspace.deleted` audit event. It is 'audited' in the RETENTION sense
— `audit_events` is RETAINED BY DESIGN (tenancy.ex:1219-1225), protected by the
`audit_events_no_update_delete` trigger that RAISES on delete; `audit_export_sinks`
is swept explicitly (tenancy.ex:1422-1425). If the criterion means the trail
survives teardown -> met. If it means an emitted deletion event -> NOT present.
