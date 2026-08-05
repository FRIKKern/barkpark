defmodule BarkparkCloud.Repo.Migrations.RekeyActiveDeploymentIndexOnEnvironment do
  use Ecto.Migration

  # deploy-truth W1 (charter D10): THE DEDUP INDEX STARTS WORKING FOR THE FIRST
  # TIME.
  #
  # `deployments_active_site_ref_index` is UNIQUE (site_id, git_ref) WHERE the
  # status is active. It was built for GitHub push idempotency, where `git_ref`
  # is a commit sha. But the fleet's real deploy traffic is content-auto: on
  # production `git_ref` is NULL on 26,395 of 26,423 deployment rows (and on
  # 8,830 of 8,830 rows that were refused by a busy box), and a btree unique
  # treats NULLs as DISTINCT — so the index has never once refused a duplicate
  # active content deploy. Two builds for the same site could always be in flight
  # at once; the box then answered the second one 409 `already_running` and the
  # publish was lost.
  #
  # The re-key moves the production key onto columns that are ALWAYS present:
  # UNIQUE (site_id, environment) WHERE status IN ('queued','building','pushing')
  # AND environment = 'production' — at most ONE active production build per
  # site, whatever triggered it. `Deploy.enqueue/6` turns the losing INSERT into
  # a coalesce onto the row already in flight, and `AutoDeployWorker` re-fires
  # the debounce so the newer content is still built afterwards.
  #
  # `deferred` is deliberately NOT in the active status literal. A deferred row
  # is settled — the rebuild it promises is a NEW row — so including it would
  # make the deferral block its own retry, which is the drop this wave refuses.
  #
  # PREVIEWS ARE UNTOUCHED, and the ref index is simply RETIRED rather than
  # re-scoped: gh-6 (20260702170000) already narrowed it to
  # `environment = 'production'` and gave previews their own
  # `deployments_active_preview_branch_index` on (site_id, branch). So on the
  # production rows it covered, "one active build per (site_id, git_ref)" is
  # strictly implied by the new "one active build per (site_id, environment)" —
  # there is nothing left for it to refuse. `deployments_delivery_id_index` still
  # backstops GitHub redeliveries by delivery id.

  @active "status IN ('queued', 'building', 'pushing')"

  def up do
    # Prod already holds duplicate active production rows (the index that was
    # supposed to prevent them never fired). Collapse them before the CREATE, or
    # the CREATE fails: per (site_id) production group, keep the newest and
    # cancel the rest with an honest reason.
    execute """
    UPDATE deployments d
    SET status = 'cancelled',
        failure_reason = 'superseded: a newer build for this site was already in flight (active-deployment re-key)',
        detail = 'superseded: a newer build for this site was already in flight (active-deployment re-key)'
    WHERE #{@active}
      AND d.environment = 'production'
      AND EXISTS (
        SELECT 1 FROM deployments other
        WHERE other.site_id = d.site_id
          AND other.environment = 'production'
          AND other.status IN ('queued', 'building', 'pushing')
          AND (other.inserted_at, other.id) > (d.inserted_at, d.id)
      )
    """

    drop_if_exists index(:deployments, [:site_id, :git_ref],
                     name: :deployments_active_site_ref_index
                   )

    create unique_index(:deployments, [:site_id, :environment],
             where: "#{@active} AND environment = 'production'",
             name: :deployments_active_site_env_index
           )
  end

  def down do
    drop_if_exists index(:deployments, [:site_id, :environment],
                     name: :deployments_active_site_env_index
                   )

    # gh-6's shape, verbatim: production-scoped.
    create unique_index(:deployments, [:site_id, :git_ref],
             where: "#{@active} AND environment = 'production'",
             name: :deployments_active_site_ref_index
           )
  end
end
