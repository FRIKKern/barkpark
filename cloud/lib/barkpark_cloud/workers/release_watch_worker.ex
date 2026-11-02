defmodule BarkparkCloud.Workers.ReleaseWatchWorker do
  @moduledoc """
  Makes a newly published server release visible to the fleet within minutes.

  Before this worker a release reached a box's row through two hourly clocks.
  Each box's checker asks GitHub once an hour, counted from its boot, and
  `UpdateStatusWorker` reads every box at :17. On 2026-11-02 v0.2.34 was tagged
  at 10:19Z, gyl's row showed it at 11:17 and gyl ran it at about 11:55.

  Every 3 minutes this worker asks GitHub for the newest release
  (`GitHub.LatestRelease`, a conditional request) and, for 30 minutes after
  this node first sees a release, re-reads every checkable box whose row does
  not show it yet, with `refresh: true`. That makes the box start its own
  upstream check (`GET /v1/admin/self-update?refresh=1`). The box answers with
  its cached verdict at once, so the fresh `behind` lands on the next tick's
  read, about 3 minutes later. After the window the hourly sweep is the only
  reader again, so a box that never learns the release (a fork, or a box that
  predates `?refresh=1`) is not polled for ever.

  It only reads. It never triggers an update, and it never writes
  `autoupdate_paused`, `pinned_release` or any rollout field. The rollout
  worker picks up the `behind` verdict on its own 5-minute tick under its
  existing gates.

  `max_attempts: 1` like the other sweeps: a missed tick is repeated 3 minutes
  later.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias BarkparkCloud.GitHub.LatestRelease
  alias BarkparkCloud.Registry

  @window_seconds 30 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case LatestRelease.fetch() do
      {:ok, %{release: release, observed_at: observed_at}} ->
        if DateTime.diff(DateTime.utc_now(), observed_at, :second) <= @window_seconds,
          do: nudge(release)

      {:error, reason} ->
        Logger.warning("release watch: GitHub tags read failed: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Whether a box's row does not yet show `release`. A box that last answered
  with no release and no refusal is included, since it has no verdict to keep.
  A box whose last read failed (`update_unavailable_reason` set) or whose
  checker is disabled is left to the hourly sweep.
  """
  @spec unaware?(map(), String.t()) :: boolean()
  def unaware?(bp, release) do
    {:ok, latest} = LatestRelease.parse(release)

    case LatestRelease.parse(bp.update_latest_release) do
      {:ok, shown} -> shown < latest
      :error -> bp.update_unavailable_reason == nil and bp.update_state != "disabled"
    end
  end

  defp nudge(release) do
    boxes = Enum.filter(Registry.update_checkable_barkparks(), &unaware?(&1, release))

    if boxes != [] do
      Logger.info(
        "release watch: #{release} is newer than #{length(boxes)} box row(s); asking them to re-check"
      )
    end

    Enum.each(boxes, &refresh/1)
  end

  defp refresh(bp) do
    _ = Registry.refresh_update_status(bp, refresh: true)
    :ok
  rescue
    e ->
      Logger.error("release watch: refresh failed for #{inspect(bp.id)}: #{Exception.message(e)}")
      :ok
  end
end
