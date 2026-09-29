defmodule BarkparkCloud.Repo.Migrations.AddGraceCountersToDeployments do
  @moduledoc """
  deploy-reliability W8 (dr-bl-w8-graced-deploys-are-uncounted): THE SAVES STOP
  BEING INVISIBLE.

  ## The counter that exists already is DESTROYED BY SUCCESS

  `Sites.Deploy` does count graced poll refusals — on `ctx`, a plain in-memory
  map (`record_graced_refusal/2`). And `forget_graced_refusals/1` `Map.drop`s
  both `:graced_refusals` and `:last_graced_refusal` on ANY poll that reached
  the box, because that is the correct rule for the CAPTION it feeds: an old
  blip must never colour a later, unrelated verdict.

  The consequence is that the count survives exactly one way — into the
  `failure_reason` of a deployment that FAILED ANYWAY ("after tolerating 3
  transient box 5xx"). Every grace that WORKED — the blip cleared, the build
  finished, the row went `live` — leaves no trace at all. The saves are
  precisely the population nobody can count, and they are the population the
  grace exists to produce.

  Start retries are worse off still: the `>= 500` arm of `start_on_box/6`
  retries and records nothing anywhere, in any outcome.

  ## Why that matters MORE than a missing metric

  Charter D114: a one-literal rename of the box's wire vocabulary drops
  `deploy_runner_unavailable` out of `transient_refusal?/1` and silently kills
  3 start retries and 45 poll-grace beats per deploy. With nothing counting the
  saves, that regression shows up ONLY as a higher failure rate with no line
  saying why — bounded below by "the start rows lose 3 retries each" and
  bounded above by nothing observable.

  These columns are the honest counterpart to the failure numerator: a save
  becomes a NUMBER, so killing grace becomes a number that goes to zero.

  ## The shape, and why it is a column and not only a log line

  The control plane's log lives in the container's docker `json-file` driver
  and `deploy/cp-deploy.sh` recreates that container — a log line is a copy a
  deploy can take with it, and it is greppable rather than queryable. So this
  follows `Notifications.account_fleet_digest/2`'s established three-part
  shape: a telemetry event, a ROW IN POSTGRES, and one key=value line a human
  tailing a deploy actually reads. This migration is the row half.

    * `graced_poll_refusals`  — how many transient box 5xx this deployment's
      poll loop swallowed IN TOTAL, across the whole run. Monotonic and
      independent of `ctx`, so a reaching poll cannot erase it.
    * `graced_start_retries`  — how many times the START trigger was retried
      across an untyped 5xx before the box took the job.
    * `last_graced_at`        — when the most recent of either happened.

  Counted on the deployment row rather than in a side table because that is
  where the rest of this run's truth already lives (`deferral_depth`,
  `coalesced_attempts`, `health_exit_code`), and a save is a property of the
  build it saved.

  ## Why this ALTER is safe on the live table

  Every column is NULLABLE, and the two with a default carry a CONSTANT
  default — since PostgreSQL 11 that is a catalog-only `ALTER`: no table
  rewrite, no per-row work, so the ACCESS EXCLUSIVE lock is held for a catalog
  update rather than a scan. Exactly the argument
  `20260807150000_add_deferral_structure_to_deployments` made for the same
  table. No index: `Registry.deploy_grace_census/3` scans the same pinned
  `inserted_at` window the deploy ledger already scans, and an index with no
  reader is write cost for nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:deployments) do
      # Default 0 so a FRESH row reads "nothing was graced" rather than
      # "unknown"; NULLABLE so every pre-W8 row stays honestly unknown. A
      # backfilled 0 would claim a measurement nobody took — and on this exact
      # column that lie is load-bearing, because "zero saves" is what a KILLED
      # grace looks like.
      add :graced_poll_refusals, :integer, default: 0
      add :graced_start_retries, :integer, default: 0
      add :last_graced_at, :utc_datetime_usec
    end
  end
end
