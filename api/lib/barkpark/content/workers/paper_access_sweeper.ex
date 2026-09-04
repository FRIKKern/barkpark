defmodule Barkpark.Content.Workers.PaperAccessSweeper do
  @moduledoc """
  TTL sweep for the paper view/edit trail — edit-on-the-link slice 4
  (task-e99a8e946f80f52c).

  `paper_access_log` grows once per reader mount and once per accepted block
  op. On a paper that is genuinely shared that is an unbounded series, so the
  table needs a retention rule or it becomes the largest thing in the database
  for the least reason.

  This worker deletes every row older than
  `Barkpark.Content.PaperAccess.ttl_days/0` — `:paper_access_log_ttl_days`,
  default 90, overridable at runtime via `BARKPARK_PAPER_ACCESS_LOG_TTL_DAYS`.

  ## Why daily, not per-minute

  The trail answers "who has been on this paper", a question asked in days.
  Nothing degrades if a row lives an extra few hours past its ttl, so there is
  no reason to pay a per-minute poll for it. The cron entry (config.exs) sits
  at 04:15 — after the 04:00 search prune, so the two range deletes never open
  their scans in the same tick.

  ## Failure posture

  A raised sweep is an Oban failure and retries on the worker's own schedule;
  it cannot affect a reader, because nothing reads this table on the render
  path. `perform/1` on an empty table returns `{:ok, %{deleted: 0}}` — never
  raises on "nothing to do".

  `args` may carry `"days"` to override the window (used by tests to make the
  sweep deterministic without waiting 90 days).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.Content.PaperAccess

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = override_days(args)
    {:ok, deleted} = PaperAccess.prune(days)

    if deleted > 0 do
      Logger.info("paper_access_log sweep deleted #{deleted} row(s) older than #{window(days)}d")
    end

    {:ok, %{deleted: deleted}}
  end

  def perform(_job), do: {:ok, %{deleted: 0}}

  defp override_days(args) when is_map(args) do
    case Map.get(args, "days") do
      days when is_integer(days) and days >= 0 -> days
      _ -> nil
    end
  end

  defp override_days(_args), do: nil

  defp window(nil), do: PaperAccess.ttl_days()
  defp window(days), do: days
end
