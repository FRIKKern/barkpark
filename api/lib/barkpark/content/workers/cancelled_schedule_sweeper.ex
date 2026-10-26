defmodule Barkpark.Content.Workers.CancelledScheduleSweeper do
  @moduledoc """
  Daily purge of cancelled schedules past the retention window
  (task-44cfe871ea0edc30). The policy lives in
  `Barkpark.Content.CancelledScheduleRetention`.

  SHIPS DISABLED. While `config :barkpark, :cancelled_schedule_retention,
  enabled: false` (the default; runtime switch
  `BARKPARK_CANCELLED_SCHEDULE_RETENTION=on`) a tick deletes nothing: it logs
  how many rows a sweep would delete and returns
  `{:ok, %{skipped: :disabled, would_delete: n}}`, so the owner sees the number
  before switching it on.

  Scheduled at 04:45, after the 04:00 search prune, the 04:15 paper access-log
  sweep and the 04:30 deleted-payload sweep, so no two range scans share a
  tick. `args` may carry `"days"` to override the window (tests).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.Content.CancelledScheduleRetention, as: Retention

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts = override(args)

    if Retention.enabled?() do
      {:ok, result} = Retention.sweep(opts)

      if result.deleted > 0,
        do: Logger.info("cancelled_schedule_retention deleted #{result.deleted} schedule(s)")

      {:ok, result}
    else
      %{count: n, days: days} = Retention.census(opts)

      if n > 0,
        do:
          Logger.info(
            "cancelled_schedule_retention is disabled; a sweep would delete #{n} cancelled " <>
              "schedule(s) older than #{days} day(s)"
          )

      {:ok, %{skipped: :disabled, would_delete: n}}
    end
  end

  defp override(%{"days" => days}) when is_integer(days) and days >= 0, do: [days: days]
  defp override(_args), do: []
end
