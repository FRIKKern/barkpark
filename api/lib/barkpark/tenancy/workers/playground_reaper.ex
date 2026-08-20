defmodule Barkpark.Tenancy.Workers.PlaygroundReaper do
  @moduledoc """
  Two-stage TTL reaper for ephemeral **playground** workspaces
  (perfect-plan-build W2c, charter D28/D29).

  A playground workspace is minted with `tier = "playground"` and
  `expires_at = now + 48h` (charter D27, Slice 1 — the front door). This worker
  is the self-cleaning back door. It runs once a minute off api/'s STATIC
  `config.exs` crontab — Tenancy is core, NOT a plugin, so its cron entry and its
  `playground_ttl` queue live in the static Oban config, never the plugin
  `oban_crontab/0` path (a queue missing from the static list would leave every
  job `available` forever — config.exs:156-175).

  ## Why two stages, not one hard delete at expiry (D28)

  A playground workspace is NOT inert at the instant its TTL elapses:
  `webhook_deliveries` may be in flight and the per-minute `Audit.ExportWorker`
  is tailing its audit log. A hard delete at `expires_at` can truncate an
  in-flight external side effect. The industry bar is pause-then-purge (Supabase
  auto-pause → restore window; CodeSandbox hibernate), and one-shot-onboarding
  frames expiry as the `bp go-live` upsell moment — a suspend window makes that a
  prompt, not a silent 404. So:

    * **Stage 1 — suspend at `expires_at`.** `tier = "playground"` AND
      `expires_at < now()` AND NOT `suspended` → `Quota.suspend(ws,
      "playground_expired")`. This reuses the merged reversible primitive: the
      workspace goes write-blocked (402/403 at the mutate seam) but its data,
      webhooks, and audit tail survive the 24h grace. `bp go-live` can still
      `reinstate/1` it.
    * **Stage 2 — swept delete at `expires_at + 24h` grace.** `tier =
      "playground"` AND `suspended` AND `suspended_at < now() - 24h` →
      `Tenancy.delete_workspace(ws.id)`. The **id overload** re-fetches the row
      inside the delete (`get_workspace_by_id/1`), closing the TOCTOU gap between
      this SELECT and the delete — a workspace reinstated or already deleted
      between tick and sweep is a clean `{:error, :not_found}` no-op.
      `delete_workspace/1` runs the full swept teardown (E3/allowlist
      string-keyed sweep FIRST, then media, documents, audit sinks, cascade), so
      a reaped playground leaves zero orphans.

  ## The tier guard is load-bearing (D28)

  EVERY predicate in BOTH stages is anchored on `tier = "playground"`. A real
  customer workspace that ever carries an `expires_at` (a trial, a scheduled
  migration) must NEVER be suspended or deleted by this worker. The negative test
  proves a non-playground row with a past `expires_at` is untouched.

  `tier` and `expires_at` are columns owned by Slice 1's schema/migration
  (`bpb-step4-playground-safety`). This worker reads them through SQL fragments
  rather than `Workspace` struct fields so the reaper slice's file set stays
  disjoint from Slice 1's `workspace.ex` (charter D16 parallel-dispatch
  discipline); the fragments resolve unchanged against the real columns once the
  two slices integrate.

  ## Idempotency + self-healing

  `unique: [period: 60, ...]` across every incomplete state collapses a slow tick
  plus the next cron fire into one in-flight job instead of stacking.
  `max_attempts: 3` lets a spurious `StaleEntryError` (a workspace another path
  moved between SELECT and write) self-heal on the next attempt. A stage that
  finds nothing returns `{:ok, %{suspended: 0, deleted: 0}}` and never raises.
  """

  use Oban.Worker,
    queue: :playground_ttl,
    max_attempts: 3,
    # The unique window must span ALL incomplete states or Oban warns a job
    # parked in an omitted state would slip the guard and let a duplicate
    # enqueue (mirrors cloud/'s StaleProvisionJobReaper).
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  import Ecto.Query, warn: false
  require Logger

  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Quota
  alias Barkpark.Tenancy.Workspace

  # Grace window between suspend (Stage 1) and swept delete (Stage 2).
  @grace_hours 24

  @suspend_reason "playground_expired"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    suspended = run_suspend_stage(now)
    deleted = run_delete_stage(now)

    {:ok, %{suspended: suspended, deleted: deleted}}
  end

  @doc """
  Stage 1 — suspend every expired, not-yet-suspended playground workspace.

  Exposed for the reaper test to drive the stages independently of the Oban
  envelope. Returns the count suspended.
  """
  @spec run_suspend_stage(DateTime.t()) :: non_neg_integer()
  def run_suspend_stage(%DateTime{} = now) do
    now
    |> expired_playgrounds()
    |> Enum.reduce(0, fn ws, acc ->
      case Quota.suspend(ws, @suspend_reason) do
        {:ok, _} ->
          acc + 1

        {:error, reason} ->
          Logger.warning(
            "PlaygroundReaper: suspend failed for workspace #{ws.id}: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  @doc """
  Stage 2 — swept-delete every suspended playground workspace past its grace
  window. Returns the count deleted.
  """
  @spec run_delete_stage(DateTime.t()) :: non_neg_integer()
  def run_delete_stage(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@grace_hours, :hour)

    now
    |> swept_playground_ids(cutoff)
    |> Enum.reduce(0, fn id, acc ->
      case Tenancy.delete_workspace(id) do
        {:ok, _} ->
          acc + 1

        # A workspace reinstated or already gone between SELECT and sweep — the
        # id overload's fresh existence re-check makes this a clean no-op.
        {:error, :not_found} ->
          acc

        {:error, reason} ->
          Logger.warning(
            "PlaygroundReaper: delete failed for workspace #{id}: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  # tier = 'playground' AND expires_at < now() AND suspended = false.
  # `tier`/`expires_at` are read via fragment (Slice 1-owned columns, not on the
  # Workspace schema here); `suspended` is a real schema field. `select: w`
  # materializes real structs for Quota.suspend/2.
  defp expired_playgrounds(now) do
    Repo.all(
      from(w in Workspace,
        where: fragment("tier = 'playground'"),
        where: fragment("expires_at < ?", ^now),
        where: w.suspended == false,
        select: w
      )
    )
  end

  # tier = 'playground' AND suspended = true AND suspended_at < now() - 24h.
  # Only ids are needed — delete_workspace/1 re-fetches the row.
  defp swept_playground_ids(_now, cutoff) do
    Repo.all(
      from(w in Workspace,
        where: fragment("tier = 'playground'"),
        where: w.suspended == true,
        where: w.suspended_at < ^cutoff,
        select: w.id
      )
    )
  end
end
