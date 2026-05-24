defmodule Barkpark.Workers.SearchAnalyticsPrune do
  @moduledoc """
  Daily prune of `media_search_events` rows older than the retention window.

  Scheduled via Oban.Plugins.Cron (04:00 UTC). Suggestions only look back 30
  days for aggregates; retention defaults to 90 days for raw event storage.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Barkpark.Media.SearchAnalytics

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = Map.get(args, "retention_days", SearchAnalytics.retention_days())
    deleted = SearchAnalytics.prune(retention_days: days)
    {:ok, %{deleted: deleted}}
  end
end
