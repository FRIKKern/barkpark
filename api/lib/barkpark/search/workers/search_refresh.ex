defmodule Barkpark.Search.Workers.SearchRefresh do
  @moduledoc """
  Runs `Barkpark.Search.SearchRefresh.drain/1`: recomputes the search data of
  the large types whose schema changed, in batches, outside the schema write
  (task-9d83c3e0c3b8fabf). A schema write queues it; Oban cron runs it every
  minute too (`config/config.exs`), so a pending refresh is picked up after a
  restart or a write by another path. A run with nothing pending reads one
  row.

  At most one job waits at a time. A job that is already running finishes the
  rows a later write adds, and the next queued job finds them done.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  alias Barkpark.Search.SearchRefresh

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, SearchRefresh.drain()}
  end
end
