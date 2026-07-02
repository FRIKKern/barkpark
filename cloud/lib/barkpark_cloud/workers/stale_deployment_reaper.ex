defmodule BarkparkCloud.Workers.StaleDeploymentReaper do
  @moduledoc """
  oban-substrate — the deploy-queue twin of `StaleProvisionJobReaper`.

  Deployment claim recovery is otherwise NON-EXISTENT: `claim_next_deployment/1`
  only matches `status == "queued"`, so a builder that crashes after claiming
  leaves the row "building" forever; `claim_pending_deployment_for_barkpark/2`
  requires `is_nil(claim_worker)`, so a crashed on-box agent wedges a "pushing"
  row forever. Either way one crashed worker leaves that site's deploys stuck
  behind an eternal spinner permanently (cloud/lib/barkpark_cloud/registry.ex).

  This worker runs every minute (the config.exs Cron entry) on the `:maintenance`
  queue and PROACTIVELY sweeps stale claims to a re-claimable / terminal state via
  `Registry.reap_stale_deployments/0`, which fails exhausted "building" rows,
  requeues the rest, and releases stale "pushing" agent claims — reusing the same
  `Registry.deployment_stale_after_seconds/0` threshold and
  `Registry.max_deploy_claims/0` budget throughout.

  Idempotent: a sweep that finds nothing returns
  `{:ok, %{failed: 0, requeued: 0, released: 0}}` and never raises. The `unique`
  window (60s) collapses a slow sweep plus the next cron tick to one in-flight
  job instead of stacking, and each status-guarded pass no-ops on a row a
  concurrent claim already moved.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Collapse a slow sweep + the next cron tick to one in-flight job. The unique
    # window must span ALL incomplete states (`:available`, `:scheduled`,
    # `:executing`, `:retryable`, `:suspended`) or Oban warns that a job parked in
    # an omitted state would slip the guard and let a duplicate enqueue.
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, BarkparkCloud.Registry.reap_stale_deployments()}
  end
end
