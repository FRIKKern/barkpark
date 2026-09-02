defmodule BarkparkCloud.Workers.ArchiveRetentionWorker do
  @moduledoc """
  Daily purge of expired archive bundles (cch-w54-bl).

  ## The hole this closes

  A decommission `Repo.delete`s the barkpark row inside
  `Registry.succeed_deprovision_job/2`. The ARCHIVE BUNDLE it leaves behind —
  a `pg_dump` plus a media tar, a full copy of the customer's content, at
  `archives/<team_id>/<slug>/` — outlived that delete forever: there is no
  `archives` table (the manifest IS the index), so no row's delete could
  cascade, and `ArchiveStore` exported only reads. This worker plus
  `ArchiveStore.delete_bundle/2` are that missing route.

  ## The retention rule (ruled 2026-09-02)

  A bundle is kept **30 days** past its `created_at` — the manifest's own
  stamp, written when the instance was archived, i.e. at teardown. Past that
  the daily sweep purges it. Two guards bound the blast radius:

    * **A STILL-LIVE TEAM NEVER LOSES ITS MOST RECENT BUNDLE.** "Still live"
      means the team still has at least one row in `barkparks` — a decommission
      deletes that row, so a team whose instances are all gone is not live and
      its whole shelf ages out normally. While a team is live its newest bundle
      is immortal at any age: that is the copy a `resurrect` would restore
      from, and a customer who still runs Barkpark Cloud has not asked us to
      throw away their only rollback point. Its OLDER bundles still expire.
    * **A BUNDLE WITH NO READABLE `created_at` IS NEVER PURGED.** An age this
      worker cannot compute is not an age of zero and not an age of forever —
      it is a bundle we decline to destroy. A manifest that lost its stamp
      survives every sweep and shows up in the log line instead.

  ## Shape

  A sibling of `AgentRetentionWorker`: same `:maintenance` queue, same daily
  cadence, `max_attempts: 1` (a missed tick is harmless — the next day catches
  up, and the window is 30 days wide). It NEVER raises: an unconfigured bundle
  store, an unreachable store, or a failing delete is counted and logged, and
  the run still returns `{:ok, summary}`. A store outage must not park a job
  that will simply retry tomorrow.

  ## Why the decision is a pure function

  `purgeable/3` takes the bundles, whether the team is live, and `now`, and
  returns the bundles to erase. It touches no S3 and no clock of its own, so
  the 30-day boundary and the still-live guard are provable by value, in both
  directions, without a bucket.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  require Logger

  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.ArchiveStore
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Repo

  # Kept this long past the bundle's own `created_at` (teardown time), then
  # purged. Documented for customers in `docs/ops/backup-dr.md` and stated on
  # the console's Decommission sheet — change all three together or the copy
  # starts lying again, which is the exact defect this worker exists to end.
  @retention_days 30

  @doc """
  The bundles of ONE team that this sweep may erase.

    * `bundles` — `ArchiveStore.list_archives/1` rows (newest-first is NOT
      assumed; this re-sorts on `created_at`)
    * `team_live?` — does the team still have at least one barkpark row
    * `now` — the sweep's clock

  Purges a bundle only when its age is STRICTLY greater than the retention
  window: a bundle exactly 30 days old is kept, one 30 days and a second old
  is not. A live team's newest bundle is removed from the candidate set before
  the age test ever runs.
  """
  @spec purgeable([map()], boolean(), DateTime.t()) :: [map()]
  def purgeable(bundles, team_live?, %DateTime{} = now) when is_list(bundles) do
    cutoff = DateTime.add(now, -@retention_days * 24 * 3600, :second)

    bundles
    |> drop_protected_newest(team_live?)
    |> Enum.filter(fn bundle ->
      case created_at(bundle) do
        nil -> false
        dt -> DateTime.compare(dt, cutoff) == :lt
      end
    end)
  end

  @doc "The retention window, in days — the single source the copy quotes."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  # A live team's most recent bundle is untouchable. "Most recent" is decided
  # on the parseable stamps only: a bundle with no readable `created_at` can
  # neither BE the protected newest (it would shield a real expiry behind a
  # broken manifest) nor be purged (the filter above already refuses it).
  defp drop_protected_newest(bundles, false), do: bundles

  defp drop_protected_newest(bundles, true) do
    newest =
      bundles
      |> Enum.filter(&created_at/1)
      |> Enum.max_by(&DateTime.to_unix(created_at(&1)), fn -> nil end)

    case newest do
      nil -> bundles
      keep -> Enum.reject(bundles, &(&1 == keep))
    end
  end

  defp created_at(%{created_at: stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp created_at(_), do: nil

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    live = live_team_ids()

    summary =
      Repo.all(from(t in Team, select: t.id))
      |> Enum.reduce(%{purged: 0, kept: 0, failed: 0, teams: 0}, fn team_id, acc ->
        sweep_team(team_id, MapSet.member?(live, team_id), now, acc)
      end)

    if summary.purged > 0 or summary.failed > 0 do
      Logger.info(
        "archive_retention: purged #{summary.purged} bundle(s), kept #{summary.kept}, " <>
          "#{summary.failed} failure(s) across #{summary.teams} team(s)"
      )
    end

    {:ok, summary}
  end

  # Teams that still have at least one barkpark row. A decommission DELETES the
  # row, so this set is exactly "teams that have not been torn down".
  defp live_team_ids do
    from(b in Barkpark, select: b.team_id, distinct: true)
    |> Repo.all()
    |> MapSet.new()
  end

  defp sweep_team(team_id, team_live?, now, acc) do
    case ArchiveStore.list_archives(team_id) do
      {:ok, []} ->
        acc

      {:ok, bundles} ->
        doomed = purgeable(bundles, team_live?, now)

        acc = %{acc | teams: acc.teams + 1, kept: acc.kept + length(bundles) - length(doomed)}

        Enum.reduce(doomed, acc, fn bundle, acc ->
          case ArchiveStore.delete_bundle(team_id, bundle.bundle_ref) do
            {:ok, _objects} ->
              %{acc | purged: acc.purged + 1}

            {:error, reason} ->
              Logger.warning(
                "archive_retention: could not purge #{bundle.bundle_ref}: #{inspect(reason)}"
              )

              %{acc | failed: acc.failed + 1}
          end
        end)

      # An unconfigured store is the deployment's normal state until a bundle
      # bucket is wired; it is not a failure of this sweep and must not spam
      # one warning per team per day.
      {:error, :not_configured} ->
        acc

      {:error, reason} ->
        Logger.warning(
          "archive_retention: listing failed for team #{team_id}: #{inspect(reason)}"
        )

        %{acc | failed: acc.failed + 1}
    end
  end
end
