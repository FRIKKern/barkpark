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
  requeues the rest, fails exhausted "pushing" rows (a permanently-unreachable
  box past its claim budget — terminal, not re-released forever), releases the
  still-retriable "pushing" agent claims, fails "queued" rows with no build
  source (no artifact + a site with no connected repo, which can never build),
  and fails a box-driven "queued" row whose driver spawn was REFUSED and has now
  been re-attempted for a full claim budget without ever being claimed —
  reusing the same `Registry.deployment_stale_after_seconds/0` threshold and
  `Registry.max_deploy_claims/0` budget throughout.

  ONE horizon is deliberately not that pair: a PREBUILT row minted by charter
  D86's mint-then-upload lane waits on the CLIENT'S off-box build, not on any
  worker of ours, so pass (0d) terminates it on
  `Registry.prebuilt_upload_grace_seconds/0` (60 minutes) with a reason that
  names the missing upload — never the refused-spawn reason, which would accuse
  a driver this lane never starts.

  Idempotent: a sweep that finds nothing returns
  `{:ok, %{failed: 0, requeued: 0, released: 0, pushing_failed: 0, no_source_failed: 0, spawn_failed: 0, upload_missing_failed: 0, resumed: 0}}`
  and never raises. The `unique`
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
    sweep = BarkparkCloud.Registry.reap_stale_deployments()

    # site-spawner D22: the sweep RECOVERS an orphaned row (requeues it), but for
    # a STATIC row that is only half a rescue — nothing in the fleet claims static
    # deployments (the off-box builder is kind-scoped to container), so a requeued
    # static row would sit `queued` forever: the eternal spinner this worker
    # exists to kill, wearing the reaper's own uniform. Re-drive them here, right
    # after the sweep that freed them. Best-effort and idempotent — a row someone
    # else already claimed simply fails its claim and is skipped.
    resumed = BarkparkCloud.Sites.Deploy.resume_orphaned()

    {:ok, Map.put(sweep, :resumed, resumed)}
  end
end
