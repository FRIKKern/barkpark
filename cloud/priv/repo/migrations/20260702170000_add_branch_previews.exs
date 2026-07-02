defmodule BarkparkCloud.Repo.Migrations.AddBranchPreviews do
  use Ecto.Migration

  # gh-6: Vercel-style branch previews. A push to a NON-production branch of a
  # connected repo deploys to its own preview URL/container without touching the
  # production slot (`sites.current_deployment_id` / `sites.port`).
  #
  # A Deployment gains an `environment` ("production" | "preview") + the branch
  # it was cut from + the preview subdomain slug and full host it answers on.
  # Production rows keep `environment = "production"` (the column default) and
  # leave the three preview columns null — so nothing about the existing
  # production deploy path changes.
  #
  # A Site gains `previews_enabled` (default ON for connected repos) — the
  # per-site kill switch the webhook consults before minting a preview.
  #
  # Index reconciliation with dwb-18 (20260702160200):
  #
  #   * dwb-18's `deployments_active_site_ref_index` — unique (site_id, git_ref)
  #     WHERE active — would forbid a preview and a production build being active
  #     at the same commit (a branch cut from the prod branch with no new
  #     commits), and two preview branches at the same sha. Re-scoped here to
  #     `environment = 'production'`: dwb-18's guarantee is preserved verbatim
  #     for the production path (every pre-gh-6 row IS production), previews are
  #     freed.
  #   * `deployments_active_preview_branch_index` — the preview twin: at most one
  #     ACTIVE preview build per (site_id, branch). The DB backstop for
  #     replace-per-branch under concurrent pushes (the create path cancels the
  #     branch's prior preview + inserts in one transaction; a lost race
  #     surfaces as a changeset error the router 200s as a duplicate).
  #   * dwb-18's `deployments_delivery_id_index` needs NO change — GitHub's
  #     X-GitHub-Delivery is globally unique, one row per delivery regardless of
  #     environment; the preview create path threads delivery_id through too.
  #
  # Other indexes:
  #   * (site_id, environment, branch) — the "latest preview for this branch"
  #     lookup the replace-per-branch + teardown paths run on every push.
  #   * preview_host — the on-demand-TLS `/v1/tls/ask` gate resolves an inbound
  #     hostname to "is this a live preview?" in O(1), the preview twin of the
  #     GIN index on `sites.domains`.
  def up do
    alter table(:deployments) do
      add :environment, :string, null: false, default: "production"
      add :branch, :string
      add :preview_slug, :string
      add :preview_host, :string
    end

    alter table(:sites) do
      add :previews_enabled, :boolean, null: false, default: true
    end

    create index(:deployments, [:site_id, :environment, :branch])
    create index(:deployments, [:preview_host])

    # Re-scope dwb-18's active-build uniqueness to the production environment.
    # Safe on existing data: every pre-gh-6 row has environment='production'
    # (the column default just backfilled), so the narrowed predicate covers
    # exactly the rows the old index covered.
    drop index(:deployments, [:site_id, :git_ref], name: :deployments_active_site_ref_index)

    create unique_index(:deployments, [:site_id, :git_ref],
             where: "status IN ('queued', 'building', 'pushing') AND environment = 'production'",
             name: :deployments_active_site_ref_index
           )

    create unique_index(:deployments, [:site_id, :branch],
             where: "status IN ('queued', 'building', 'pushing') AND environment = 'preview'",
             name: :deployments_active_preview_branch_index
           )
  end

  def down do
    drop index(:deployments, [:site_id, :branch],
           name: :deployments_active_preview_branch_index
         )

    drop index(:deployments, [:site_id, :git_ref], name: :deployments_active_site_ref_index)

    # Restoring dwb-18's UNSCOPED active index requires no two active rows per
    # (site_id, git_ref) across environments — cancel active previews first
    # (mirrors dwb-18's own collapse-then-index pattern). Previews cannot exist
    # once the environment column is gone, so cancelling them is the only honest
    # rollback.
    execute """
    UPDATE deployments
    SET status = 'cancelled',
        failure_reason = 'branch previews rolled back (gh-6 down migration)'
    WHERE environment = 'preview'
      AND status IN ('queued', 'building', 'pushing')
    """

    create unique_index(:deployments, [:site_id, :git_ref],
             where: "status IN ('queued', 'building', 'pushing')",
             name: :deployments_active_site_ref_index
           )

    drop index(:deployments, [:preview_host])
    drop index(:deployments, [:site_id, :environment, :branch])

    alter table(:sites) do
      remove :previews_enabled
    end

    alter table(:deployments) do
      remove :environment
      remove :branch
      remove :preview_slug
      remove :preview_host
    end
  end
end
