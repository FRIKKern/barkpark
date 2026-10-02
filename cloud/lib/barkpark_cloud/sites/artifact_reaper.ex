defmodule BarkparkCloud.Sites.ArtifactReaper do
  @moduledoc """
  ssw9-bl-artifact-retention-quota (charter D91) — the sweep that reaps
  `site_artifacts` bytes on EVERY terminal path, not just the two the deploy
  driver walks.

  ## The gap this closes

  D86/D91 moved the uploaded tarball off the (never-mounted) host directory and
  into Postgres, and `Sites.Deploy` drops a deployment's bytes at exactly two
  points: `settled_live/1` and the driver's `fail/…` clause. Both of those run
  INSIDE the deploy driver. So the reap is conditioned on the driver reaching a
  terminal state, and the driver is precisely the thing that is missing whenever
  the leak matters:

    * a deployment MINTED and ABANDONED — the prebuilt lane mints a `queued` row
      and starts NO driver; the client uploads bytes and then never comes back.
      `Workers.StaleDeploymentReaper` settles that row `failed` with a bulk
      `Repo.update_all`, which no `drop_artifact/1` call can see.
    * a `cancelled` row — `Registry.cancel_*` and `Sites.AutoDeployWorker` both
      write `cancelled` outside the driver.
    * a `deferred` row whose fenced write landed but whose driver then exited on
      the deferral branch rather than through `fail/…`.
    * a driver whose BEAM died between `store_artifact/3` and settlement; the
      reaper terminates the row, the driver's `drop_artifact/1` never runs.

  ## Why a predicate and not a call site

  A per-call-site fix is an ENUMERATION of today's terminal writers, and it goes
  stale the first time someone adds a terminal status or a new writer. This sweep
  is a PREDICATE over stored state instead: an artifact is reapable iff the
  deployment it is bound to is TERMINAL, and "terminal" is DERIVED from
  `Registry.Deployment.transitions/0` — a status with no outgoing edges. Add a
  fifth terminal status to that graph and this reaper covers it with no edit
  here. `terminal_statuses/0` is public so a test can pin the derivation.

  The in-driver `drop_artifact/1` calls stay: they free the bytes in the same
  second the deploy settles instead of within a minute. This is the floor under
  them, not a replacement.

  ## The orphan arm

  `site_artifacts.deployment_id` is nullable — the RETIRED site-scoped upload
  route (W10) inserted rows with a `site_id` and no `deployment_id`, and both the
  only read (`Deploy.artifact_for/1`) and the only delete (`Deploy.drop_artifact/1`)
  key on `deployment_id`, so every such row is unreadable AND unreapable forever.
  Nothing mints them any more; this sweep is what makes the ones already on
  `cloud_pgdata` go away.

  Rides the `:maintenance` queue on the same per-minute cron as its sibling
  reapers.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias BarkparkCloud.Registry.{Deployment, Site, SiteArtifact}
  alias BarkparkCloud.Repo

  require Logger

  # DERIVED, never listed: a status is terminal iff the transition graph gives it
  # no outgoing edges. Compile-time so the query has no runtime cost, and pinned
  # by `artifact_reaper_test.exs` so a graph change that this file does not see
  # reds there instead of leaking silently.
  @terminal_statuses for({status, []} <- Deployment.transitions(), do: status) |> Enum.sort()

  # An artifact bound to NO deployment cannot be claimed by any in-flight upload
  # after this long. Generous on purpose — it is a legacy-row sweep, not a
  # deadline anyone races.
  @orphan_grace_seconds 24 * 60 * 60

  # One tick never deletes more than this many rows. Each row carries up to 32 MB,
  # so an unbounded `delete_all` after a backlog would pull gigabytes of `bytea`
  # through one transaction. The cron re-runs every minute; a backlog drains.
  @batch_limit 200

  @doc """
  The terminal statuses, derived from `Deployment.transitions/0`.

  Public so the derivation itself is testable: this is the whole safety argument
  for the sweep, and a `for` comprehension nobody asserts on is a claim, not a
  mechanism.
  """
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc """
  The bytes a team is currently holding in `site_artifacts`, and the row count.

  Team-scoped through `sites.team_id` (a Site carries the team key directly).
  """
  @spec usage(binary()) :: %{bytes: non_neg_integer(), rows: non_neg_integer()}
  def usage(team_id) when is_binary(team_id) do
    query =
      from(a in SiteArtifact,
        join: s in Site,
        on: s.id == a.site_id,
        where: s.team_id == ^team_id,
        select: {coalesce(sum(a.byte_size), 0), count(a.id)}
      )

    {bytes, rows} = Repo.one(query)
    %{bytes: bytes, rows: rows}
  end

  @doc """
  Reap every artifact whose deployment has settled, plus long-orphaned rows.

  Returns `{:ok, %{rows: n, bytes: b}}` — what this tick ACTUALLY deleted, read
  back from the rows it selected, never from a `delete_all` count alone (the
  count cannot say how many bytes went away).
  """
  @spec reap() :: {:ok, %{rows: non_neg_integer(), bytes: non_neg_integer()}}
  def reap(now \\ DateTime.utc_now()) do
    orphan_cutoff = DateTime.add(now, -@orphan_grace_seconds, :second)

    reapable =
      from(a in SiteArtifact,
        left_join: d in Deployment,
        on: d.id == a.deployment_id,
        where:
          d.status in ^@terminal_statuses or
            (is_nil(a.deployment_id) and a.inserted_at < ^orphan_cutoff),
        select: {a.id, a.byte_size},
        limit: @batch_limit
      )
      |> Repo.all()

    case reapable do
      [] ->
        {:ok, %{rows: 0, bytes: 0}}

      rows ->
        ids = Enum.map(rows, &elem(&1, 0))
        bytes = Enum.reduce(rows, 0, fn {_id, size}, acc -> acc + (size || 0) end)

        {deleted, _} = Repo.delete_all(from(a in SiteArtifact, where: a.id in ^ids))

        Logger.info(
          "site artifact reaper: deleted #{deleted} artifact row(s), freed #{bytes} bytes"
        )

        {:ok, %{rows: deleted, bytes: bytes}}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _summary} = reap()
    :ok
  end
end
