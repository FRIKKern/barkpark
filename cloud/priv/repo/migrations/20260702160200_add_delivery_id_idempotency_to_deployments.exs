defmodule BarkparkCloud.Repo.Migrations.AddDeliveryIdIdempotencyToDeployments do
  use Ecto.Migration

  # dwb-18: DB backstop for GitHub push-to-deploy idempotency. The app-level
  # find_active_deployment dedup (PR #811) leaves a race window: two concurrent
  # redeliveries (GitHub retries on any 5xx/timeout) both pass the check and
  # both mint a Deployment. Two partial unique indexes close it at the DB:
  #
  #   * delivery_id — GitHub's X-GitHub-Delivery is unique per redelivery-chain,
  #     so the same delivery can only ever create one row (partial: nulls, from
  #     pushes with no header, don't collide).
  #   * (site_id, git_ref) WHERE status active — at most one queued/building/
  #     pushing build per commit, regardless of delivery id. The losing INSERT
  #     surfaces as a changeset error the router turns into a 200 duplicate.
  #
  # The active index must be created AFTER collapsing any pre-existing duplicate
  # active rows (prod may already hold them), or the CREATE would fail.
  def up do
    alter table(:deployments) do
      add :delivery_id, :text
    end

    # Collapse pre-existing active duplicates: per (site_id, git_ref) group with
    # more than one row in an active status, keep the newest by inserted_at and
    # cancel the rest so the partial unique index below can be built.
    execute """
    UPDATE deployments d
    SET status = 'cancelled',
        failure_reason = 'superseded duplicate (idempotency backfill)'
    WHERE d.status IN ('queued', 'building', 'pushing')
      AND EXISTS (
        SELECT 1 FROM deployments other
        WHERE other.site_id = d.site_id
          AND other.git_ref = d.git_ref
          AND other.status IN ('queued', 'building', 'pushing')
          AND (other.inserted_at, other.id) > (d.inserted_at, d.id)
      )
    """

    create unique_index(:deployments, [:delivery_id],
             where: "delivery_id IS NOT NULL",
             name: :deployments_delivery_id_index
           )

    create unique_index(:deployments, [:site_id, :git_ref],
             where: "status IN ('queued', 'building', 'pushing')",
             name: :deployments_active_site_ref_index
           )
  end

  def down do
    drop index(:deployments, [:site_id, :git_ref], name: :deployments_active_site_ref_index)
    drop index(:deployments, [:delivery_id], name: :deployments_delivery_id_index)

    alter table(:deployments) do
      remove :delivery_id
    end
  end
end
