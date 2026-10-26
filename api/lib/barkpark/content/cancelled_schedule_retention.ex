defmodule Barkpark.Content.CancelledScheduleRetention do
  @moduledoc """
  Retention for cancelled schedules (task-44cfe871ea0edc30; design:
  `/papers/cancelled-schedules-purge`).

  `DELETE /v1/data/schedules/:dataset/:id` marks a schedule `cancelled` and
  keeps the row, so a dataset whose tests schedule and cancel grows without
  bound. A `cancelled` row whose `completed_at` is older than `days/0`
  (default 30) is deleted. Nothing else is: the other terminal statuses
  (`published`, `refused`, `failed`, `missed`) are the history the Studio shows
  as archived, and `scheduled` / `paused` rows are live. Every workspace is
  swept alike.

  Ships DISABLED. `config :barkpark, :cancelled_schedule_retention, enabled:
  false, days: 30` (config.exs); the owner turns it on with
  `BARKPARK_CANCELLED_SCHEDULE_RETENTION=on` (window:
  `BARKPARK_CANCELLED_SCHEDULE_RETENTION_DAYS`) after reading `census/1`, which
  `mix barkpark.cancelled_schedules` prints and the disabled daily tick logs.
  """

  import Ecto.Query

  alias Barkpark.Repo

  @default_days 30
  @default_batch_size 1_000
  @default_max_passes 20

  @doc "True when the scheduled sweep is switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc "Retention window in days (default #{@default_days})."
  @spec days() :: pos_integer()
  def days do
    case Keyword.get(config(), :days, @default_days) do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_days
    end
  end

  @doc """
  The dry run: how many rows a sweep would delete, and the oldest and newest
  `completed_at` among them. Options: `:days`, `:now`.
  """
  @spec census(keyword()) :: %{
          days: non_neg_integer(),
          cutoff: DateTime.t(),
          count: non_neg_integer(),
          oldest: DateTime.t() | nil,
          newest: DateTime.t() | nil
        }
  def census(opts \\ []) do
    {days, cutoff} = window(opts)

    {count, oldest, newest} =
      from(s in expired(cutoff),
        select: {count(s.id), min(s.completed_at), max(s.completed_at)}
      )
      |> Repo.one()

    %{days: days, cutoff: cutoff, count: count, oldest: oldest, newest: newest}
  end

  @doc """
  Delete the expired cancelled rows, `:batch_size` per statement (default
  #{@default_batch_size}), at most `:max_passes` statements (default
  #{@default_max_passes}); a larger backlog finishes on the next run.
  Options: `:days`, `:now`, `:batch_size`, `:max_passes`.
  """
  @spec sweep(keyword()) :: {:ok, %{deleted: non_neg_integer(), passes: non_neg_integer()}}
  def sweep(opts \\ []) do
    {_days, cutoff} = window(opts)
    batch = Keyword.get(opts, :batch_size, @default_batch_size)
    max_passes = Keyword.get(opts, :max_passes, @default_max_passes)
    {:ok, sweep_loop(cutoff, batch, max_passes, %{deleted: 0, passes: 0})}
  end

  defp sweep_loop(_cutoff, _batch, max, %{passes: max} = acc), do: acc

  defp sweep_loop(cutoff, batch, max, acc) do
    ids = from(s in expired(cutoff), order_by: s.completed_at, limit: ^batch, select: s.id)
    {n, _} = Repo.delete_all(from(s in "scheduled_publishes", where: s.id in subquery(ids)))
    acc = %{deleted: acc.deleted + n, passes: if(n > 0, do: acc.passes + 1, else: acc.passes)}

    if n < batch, do: acc, else: sweep_loop(cutoff, batch, max, acc)
  end

  defp expired(cutoff) do
    from(s in "scheduled_publishes",
      where: s.status == "cancelled" and s.completed_at < ^cutoff
    )
  end

  defp window(opts) do
    days = Keyword.get(opts, :days, days())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    {days, DateTime.add(now, -days * 86_400, :second)}
  end

  defp config, do: Application.get_env(:barkpark, :cancelled_schedule_retention, [])
end
